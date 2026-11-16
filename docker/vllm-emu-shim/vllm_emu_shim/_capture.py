"""Capture a profile pack's raw material from a REAL vLLM run.

The other half of this package replays step latencies; this half
records them. It runs inside an ordinary GPU build of vLLM — no
emulator, no llm-emu — and writes one JSON line per engine step in the
trace format llm-emu's builder
(vllm_emulator/profile/build_serving_profile_filtered.py) reads.

Enabled by VLLM_EMULATOR_TRACE_STEP_CYCLE=1, the variable upstream
uses; output goes to VLLM_EMULATOR_STEP_TRACE_OUTPUT.

WHY THIS IS NOT UPSTREAM'S TRACER. Upstream wires its StepCycleTracer
into vLLM 0.18.1 with ~135 patched lines in engine/core.py, which do
not apply to v0.33.0, and what they measure is wrong for it. They time
EngineCoreProc._process_engine_step and describe the batch with the
scheduler output most recently SCHEDULED. v0.33.0 runs a batch queue
of depth 2 by default: step_with_batch_queue submits batch n+1 and
then blocks on batch n, so "the last scheduled output" is not the one
whose result the step waited for, and the first call of a burst — which
only fills the queue and returns — would be recorded as a near-zero
step. Every sample would be filed under the wrong batch shape.

WHAT IS MEASURED INSTEAD, and it is chosen to be the exact inverse of
how the emulator replays. The emulator keeps one virtual device
timeline (llm-emu executor_hook.py, _handle_async):

    start = max(now, gpu_free_time);  end = start + latency

so the latency it wants for a batch is the time the device spent on
that batch alone. With pipelining, batch n+1 is submitted while n is
still running, so submit-to-completion would count n's remaining time
twice. The device was free for n at whichever came later, its own
submission or the previous batch's completion:

    latency(n) = completion(n) - max(submit(n), completion(n-1))

Submission is stamped at model_executor.execute_model; completion is
observed when the engine returns from waiting on that batch's result.
vLLM brackets exactly that wait with capture_iteration_details(
scheduler_output), called with the batch that was popped, in both
step() and step_with_batch_queue() — which is why that one method is
the wrap point, and why the selftest asserts both callers still use it.

So a sample is completion-to-completion device time, not upstream's
whole-step wall time. Packs captured here are not measured the same
way as upstream's, and the trace header says so.

WHAT IT CANNOT SEPARATE. When the engine thread, not the device, sets
the pace, that CPU time is recorded as device latency. Completion is
seen when the engine thread wakes, slightly after the device finished.
And anything else using the GPU during a capture lands in the samples.
"""

from __future__ import annotations

import atexit
import functools
import json
import os
import threading
import time
from contextlib import contextmanager

_TRUE = ("1", "true", "yes")
_MARK = "_rocm_bake_emu_capture_patched"

TRACE_ENV = "VLLM_EMULATOR_TRACE_STEP_CYCLE"
OUTPUT_ENV = "VLLM_EMULATOR_STEP_TRACE_OUTPUT"
DEFAULT_OUTPUT = "/tmp/emulator_step_trace.jsonl"

LATENCY_DEFINITION = "completion(n) - max(submit(n), completion(n-1))"


def trace_armed() -> bool:
    return os.environ.get(TRACE_ENV, "").lower() in _TRUE


class StepTracer:
    """Buffered JSONL writer in llm-emu's trace format.

    Field names are upstream's, because upstream's builder is what
    reads the file: a `_header` line, then one record per step carrying
    step_cycle_us, total_tokens, num_new_reqs, num_decode_seqs and
    sum_kv. The builder requires the first four and ignores any line it
    does not recognise.
    """

    def __init__(self, path: str, flush_every: int = 200):
        self.path = path
        self._buf: list[str] = []
        self._lock = threading.Lock()
        self._flush_every = flush_every
        self.steps = 0
        self.header_written = False
        self._last_flush = time.monotonic()

    def write_header(self, vllm_config) -> None:
        if self.header_written:
            return
        header: dict = {"_header": True}

        try:
            import torch

            props = torch.cuda.get_device_properties(0)
            header["gpu_name"] = props.name
            header["gpu_memory_bytes"] = props.total_memory
            header["gpu_sm_count"] = props.multi_processor_count
            header["gpu_compute_capability"] = list(
                torch.cuda.get_device_capability(0))
            header["gpu_count"] = torch.cuda.device_count()
            header["gpu_arch"] = getattr(props, "gcnArchName", None)
            header["torch_version"] = torch.__version__
        except Exception as exc:  # noqa: BLE001
            print(f"[vllm-emu-capture] device metadata unavailable: {exc}")

        try:
            mc = vllm_config.model_config
            header["model_name"] = mc.model
            header["max_model_len"] = mc.max_model_len
            hf = mc.hf_text_config
            for attr in ("num_hidden_layers", "hidden_size",
                         "num_attention_heads", "num_key_value_heads",
                         "vocab_size", "intermediate_size"):
                val = getattr(hf, attr, None)
                if val is not None:
                    header[attr] = val
            head_dim = getattr(hf, "head_dim", None)
            if head_dim is None and getattr(hf, "num_attention_heads", None):
                head_dim = hf.hidden_size // hf.num_attention_heads
            if head_dim is not None:
                header["head_dim"] = head_dim
            # Upstream's tracer never records this, and without it the
            # emulator falls back to stop-token {2} and can end a
            # request the moment its filler token happens to match.
            eos = _eos_token_ids(mc)
            if eos:
                header["eos_token_id"] = eos
        except Exception as exc:  # noqa: BLE001
            print(f"[vllm-emu-capture] model metadata unavailable: {exc}")

        try:
            header["block_size"] = vllm_config.cache_config.block_size
            sc = vllm_config.scheduler_config
            header["enable_chunked_prefill"] = sc.enable_chunked_prefill
            header["max_num_seqs"] = sc.max_num_seqs
            header["max_num_batched_tokens"] = sc.max_num_batched_tokens
            header["gpu_memory_utilization"] = (
                vllm_config.cache_config.gpu_memory_utilization)
        except Exception:  # noqa: BLE001
            pass

        # How this trace was measured, in the file itself: the samples
        # are only meaningful to a reader who knows the definition, and
        # it differs from upstream's.
        header["capture"] = {
            "tool": "vllm_emu_shim._capture",
            "latency_definition": LATENCY_DEFINITION,
            "vllm_version": _dist_version("vllm"),
            "started_unix": round(time.time(), 3),
        }

        self._append(json.dumps(header))
        self.flush()
        self.header_written = True
        print(f"[vllm-emu-capture] tracing to {self.path} — "
              f"{header.get('gpu_name', '?')}, {header.get('model_name', '?')}")

    def record(self, latency_us: float, total_tokens: int, num_new_reqs: int,
               num_decode_seqs: int, sum_kv: int) -> None:
        self._append(json.dumps({
            "step_cycle_us": round(latency_us, 1),
            "total_tokens": total_tokens,
            "num_new_reqs": num_new_reqs,
            "num_decode_seqs": num_decode_seqs,
            "sum_kv": sum_kv,
        }))
        self.steps += 1
        # By count or by time, whichever comes first: a quiet server
        # would otherwise hold its last steps in memory indefinitely,
        # and a capture that is killed rather than shut down loses
        # whatever is still buffered.
        now = time.monotonic()
        if len(self._buf) >= self._flush_every or now - self._last_flush > 2.0:
            self.flush()

    def _append(self, line: str) -> None:
        with self._lock:
            self._buf.append(line)

    def flush(self) -> None:
        with self._lock:
            lines, self._buf = self._buf, []
        self._last_flush = time.monotonic()
        if not lines:
            return
        parent = os.path.dirname(self.path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")


def _dist_version(name: str) -> str | None:
    try:
        from importlib.metadata import version

        return version(name)
    except Exception:  # noqa: BLE001
        return None


def _eos_token_ids(model_config) -> list[int]:
    ids: list[int] = []

    def add(value) -> None:
        if isinstance(value, int):
            value = [value]
        if isinstance(value, (list, tuple)):
            for v in value:
                if isinstance(v, int) and v not in ids:
                    ids.append(v)

    try:
        add(model_config.try_get_generation_config().get("eos_token_id"))
    except Exception:  # noqa: BLE001
        pass
    add(getattr(model_config.hf_text_config, "eos_token_id", None))
    return ids


def batch_shape(scheduler_output) -> tuple[int, int, int, int]:
    """(total_tokens, num_new_reqs, num_decode_seqs, sum_kv) for a batch.

    The same arithmetic the emulator's executor hook applies when it
    looks a batch up (llm-emu executor_hook.py, create_delayed_future),
    so a sample is filed under the key it will later be drawn by.
    """
    new_ids = {r.req_id for r in scheduler_output.scheduled_new_reqs}
    num_decode = sum(1 for rid in scheduler_output.num_scheduled_tokens
                     if rid not in new_ids)
    cached = scheduler_output.scheduled_cached_reqs
    sum_kv = sum(cached.num_computed_tokens) if cached.req_ids else 0
    return (scheduler_output.total_num_scheduled_tokens, len(new_ids),
            num_decode, sum_kv)


class _State:
    """Per-EngineCore capture state."""

    def __init__(self, tracer: StepTracer):
        self.tracer = tracer
        # id(scheduler_output) -> submit time. SchedulerOutput is an
        # unhashable dataclass, and the object is alive from submission
        # until its result is collected, so its id is stable for
        # exactly as long as the entry is needed.
        self.submitted: dict[int, float] = {}
        self.last_completion = 0.0


def _state_of(core) -> _State | None:
    """Build the tracer on first use.

    Not in __init__: vLLM loads plugins from inside EngineCore.__init__
    before it has assigned vllm_config or built the executor, so there
    is nothing to describe yet when this package is loaded.
    """
    state = getattr(core, "_rocm_bake_emu_capture", None)
    if state is not None:
        return state
    try:
        tracer = StepTracer(os.environ.get(OUTPUT_ENV) or DEFAULT_OUTPUT)
        tracer.write_header(core.vllm_config)
        state = _State(tracer)
        _wrap_executor(core.model_executor, state)
        atexit.register(tracer.flush)
    except Exception as exc:  # noqa: BLE001
        print(f"[vllm-emu-capture] could not start tracing: "
              f"{type(exc).__name__}: {exc}")
        state = False
    core._rocm_bake_emu_capture = state
    return state


def _wrap_executor(executor, state: _State) -> None:
    orig = executor.execute_model

    @functools.wraps(orig)
    def execute_model(scheduler_output, *args, **kwargs):
        state.submitted[id(scheduler_output)] = time.perf_counter()
        # Bounded: an entry is removed when its batch completes, so
        # more than a handful means steps are raising before they get
        # there. Drop the stale ones rather than grow or mis-attribute.
        if len(state.submitted) > 64:
            newest = max(state.submitted.values())
            for key in [k for k, v in state.submitted.items()
                        if newest - v > 60.0]:
                del state.submitted[key]
        return orig(scheduler_output, *args, **kwargs)

    executor.execute_model = execute_model


def _patch_engine_core(module) -> None:
    cls = getattr(module, "EngineCore", None)
    if cls is None or getattr(cls, _MARK, False):
        return
    orig_cid = getattr(cls, "capture_iteration_details", None)
    if orig_cid is None:
        print("[vllm-emu-capture] EngineCore.capture_iteration_details is "
              "gone — cannot trace this vLLM")
        return

    def _ensure(orig):
        @functools.wraps(orig)
        def wrapper(self, *args, **kwargs):
            _state_of(self)
            return orig(self, *args, **kwargs)
        return wrapper

    # The tracer has to exist, and the executor has to be wrapped,
    # before the first batch is submitted — which is inside these.
    for name in ("step", "step_with_batch_queue"):
        if hasattr(cls, name):
            setattr(cls, name, _ensure(getattr(cls, name)))

    @contextmanager
    @functools.wraps(orig_cid)
    def capture_iteration_details(self, scheduler_output, *args, **kwargs):
        with orig_cid(self, scheduler_output, *args, **kwargs) as details:
            yield details
        # Reached only when the wait on this batch returned cleanly; a
        # step that raised is not a measurement.
        state = _state_of(self)
        if not state or scheduler_output is None:
            return
        done = time.perf_counter()
        submit = state.submitted.pop(id(scheduler_output), None)
        try:
            # Zero-token outputs pass through here too — empty
            # schedules and DP dummy iterations. They did no device
            # work, and the builder would file one as a decode step at
            # concurrency 1.
            if (submit is None
                    or scheduler_output.total_num_scheduled_tokens <= 0):
                return
            start = max(submit, state.last_completion)
            state.tracer.record((done - start) * 1e6,
                                *batch_shape(scheduler_output))
        except Exception as exc:  # noqa: BLE001
            print(f"[vllm-emu-capture] step not recorded: {exc}")
        finally:
            if submit is not None:
                state.last_completion = done

    cls.capture_iteration_details = capture_iteration_details

    orig_shutdown = getattr(cls, "shutdown", None)
    if orig_shutdown is not None:
        @functools.wraps(orig_shutdown)
        def shutdown(self, *args, **kwargs):
            state = getattr(self, "_rocm_bake_emu_capture", None)
            if state:
                state.tracer.flush()
                print(f"[vllm-emu-capture] {state.tracer.steps} steps "
                      f"written to {state.tracer.path}")
            return orig_shutdown(self, *args, **kwargs)

        cls.shutdown = shutdown

    setattr(cls, _MARK, True)
    print("[vllm-emu-capture] step tracing armed")


def apply() -> bool:
    """Arm tracing. Returns True when armed."""
    if not trace_armed():
        return False
    from ._patch import _module_patcher

    _module_patcher("vllm.v1.engine.core", _patch_engine_core,
                    "engine_core_capture")
    return True
