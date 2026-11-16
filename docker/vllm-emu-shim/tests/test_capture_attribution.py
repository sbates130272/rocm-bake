"""Does the capture wiring charge each step to the right batch?

That is the one claim _capture.py makes which cannot be read off the
code, and it is the claim upstream's own tracer gets wrong on vLLM
0.33: with a batch queue two deep, the batch most recently SCHEDULED
is not the one whose result the engine just waited for, so latency
lands under the wrong shape and the queue-filling call is recorded as
a near-zero step.

So this drives a stand-in engine shaped like v0.33.0's
step_with_batch_queue -- batch n+1 submitted before batch n is
awaited, capture_iteration_details bracketing the wait on the POPPED
batch -- whose "device" is a single worker thread sleeping a known
time per batch. The right answer is therefore known in advance, which
no test against real vLLM could give us.

No vLLM, no torch, no GPU, no network: stand-ins all the way down, so
it runs in CI beside ruff. Run it directly:

    python3 -I docker/vllm-emu-shim/tests/test_capture_attribution.py
"""

import json
import os
import sys
import tempfile
import time
import types
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

# The package under test, found relative to this file rather than from
# an install, so the test runs against the working tree.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from vllm_emu_shim import _capture  # noqa: E402

# Generous: the point is to tell "this batch" from "the previous one",
# and the batches below differ by 10 ms or more. A thread wake-up on a
# loaded CI runner is well inside this.
TOLERANCE_MS = 8.0


@dataclass
class NewReq:
    req_id: str


@dataclass
class CachedReqs:
    req_ids: list = field(default_factory=list)
    num_computed_tokens: list = field(default_factory=list)


@dataclass
class SchedOut:
    """The fields _capture.batch_shape() reads, and a device duration."""

    scheduled_new_reqs: list
    scheduled_cached_reqs: CachedReqs
    num_scheduled_tokens: dict
    total_num_scheduled_tokens: int
    device_s: float = 0.0


class Device:
    """One worker, so batches serialise the way a GPU does."""

    def __init__(self):
        self.pool = ThreadPoolExecutor(max_workers=1)

    def execute_model(self, sched_out, non_block=False):
        return self.pool.submit(self._run, sched_out)

    @staticmethod
    def _run(sched_out):
        time.sleep(sched_out.device_s)
        return "model-output"


class FakeEngineCore:
    """The shape of v0.33.0's two step paths, and nothing else."""

    def __init__(self, plan, queue_size):
        self.vllm_config = types.SimpleNamespace()
        self.model_executor = Device()
        self.plan = deque(plan)
        self.batch_queue = deque() if queue_size > 1 else None
        self.batch_queue_size = queue_size
        self.step_fn = (
            self.step if self.batch_queue is None else self.step_with_batch_queue
        )

    @contextmanager
    def capture_iteration_details(self, scheduler_output):
        yield None

    def step(self):
        if not self.plan:
            return {}, False
        sched_out = self.plan.popleft()
        future = self.model_executor.execute_model(sched_out, non_block=True)
        with self.capture_iteration_details(sched_out):
            future.result()
        return {}, sched_out.total_num_scheduled_tokens > 0

    def step_with_batch_queue(self):
        queue = self.batch_queue
        if self.plan:
            sched_out = self.plan.popleft()
            future = self.model_executor.execute_model(sched_out, non_block=True)
            queue.appendleft((future, sched_out))
            if len(queue) < self.batch_queue_size and self.plan:
                # Fill-up call: returns without waiting for anything.
                return None, True
        elif not queue:
            return None, False
        future, sched_out = queue.pop()
        with self.capture_iteration_details(sched_out):
            future.result()
        return {}, True

    def shutdown(self):
        pass


def batch(n_new, n_cached, device_ms, kv=0):
    new = [NewReq(f"n{i}") for i in range(n_new)]
    cached = CachedReqs([f"c{i}" for i in range(n_cached)], [kv] * n_cached)
    tokens = {r.req_id: 10 for r in new}
    tokens.update({rid: 1 for rid in cached.req_ids})
    return SchedOut(new, cached, tokens, sum(tokens.values()), device_ms / 1000.0)


def make_plan():
    """Distinct durations and shapes.

    A one-batch mis-attribution, or a pipelined sample counting the
    previous batch twice, cannot pass by coincidence.
    """
    return [
        batch(2, 0, 40),
        batch(0, 2, 20, kv=30),
        batch(1, 2, 60, kv=31),
        batch(0, 3, 25, kv=40),
        batch(0, 3, 35, kv=41),
        batch(0, 1, 15, kv=50),
    ]


def patched_core(name, plan, queue_size, trace_path):
    """A freshly patched EngineCore class writing to trace_path."""
    os.environ["VLLM_EMULATOR_TRACE_STEP_CYCLE"] = "1"
    os.environ["VLLM_EMULATOR_STEP_TRACE_OUTPUT"] = trace_path
    module = types.ModuleType(name)
    module.EngineCore = type(name, (FakeEngineCore,), {})
    _capture._patch_engine_core(module)
    return module.EngineCore(plan, queue_size)


def drain(core):
    while core.plan or (core.batch_queue and len(core.batch_queue)):
        core.step_fn()
    core.shutdown()


def records_of(path):
    lines = [json.loads(line) for line in open(path)]
    assert lines and lines[0].get("_header"), "no header line"
    assert "completion(n)" in lines[0]["capture"]["latency_definition"]
    return [r for r in lines if "total_tokens" in r]


def run(label, queue_size, plan):
    trace = tempfile.mktemp(suffix=".jsonl")
    drain(patched_core(label.replace(" ", "_"), list(plan), queue_size, trace))
    return records_of(trace)


def check(label, recs, plan):
    real = [b for b in plan if b.total_num_scheduled_tokens > 0]
    assert len(recs) == len(real), (
        f"{label}: {len(recs)} records for {len(real)} executed batches"
    )
    for rec, want in zip(recs, real):
        want_shape = (
            want.total_num_scheduled_tokens,
            len(want.scheduled_new_reqs),
            len(want.scheduled_cached_reqs.req_ids),
            sum(want.scheduled_cached_reqs.num_computed_tokens),
        )
        got_shape = (
            rec["total_tokens"],
            rec["num_new_reqs"],
            rec["num_decode_seqs"],
            rec["sum_kv"],
        )
        assert got_shape == want_shape, (
            f"{label}: recorded shape {got_shape}, expected {want_shape} "
            f"-- the sample is filed under the wrong batch"
        )
        want_ms = want.device_s * 1000
        got_ms = rec["step_cycle_us"] / 1000
        assert abs(got_ms - want_ms) <= TOLERANCE_MS, (
            f"{label}: batch {want_shape} spent {want_ms:.0f} ms on the "
            f"device, recorded {got_ms:.1f} ms"
        )
    print(
        f"ok  {label}: {len(recs)} steps, each within {TOLERANCE_MS:.0f} ms "
        f"of its own device time, shapes attributed correctly"
    )


def test_batch_queue_depth_2():
    plan = make_plan()
    check("batch queue depth 2 (v0.33 default)", run("q2", 2, plan), plan)


def test_no_batch_queue():
    plan = make_plan()
    check("no batch queue (plain step)", run("q1", 1, plan), plan)


def test_zero_token_batch_skipped():
    """An empty schedule did no device work and must not be a sample.

    The pack builder accepts any record carrying total_tokens and would
    file this as a decode step at concurrency 1.
    """
    plan = make_plan()
    plan.insert(3, SchedOut([], CachedReqs(), {}, 0, 0.0))
    check("zero-token batch skipped", run("zero", 2, plan), plan)


def test_idle_gap_not_charged():
    """Time with no work queued belongs to nobody.

    Charging it to the next batch is what submit-to-completion timing
    would do, and it would turn a quiet server into one with enormous
    apparent step latencies.
    """
    trace = tempfile.mktemp(suffix=".jsonl")
    first, second = batch(1, 0, 30), batch(0, 1, 30, kv=10)
    core = patched_core("idle", [first], 2, trace)
    drain(core)
    time.sleep(0.25)
    core.plan.append(second)
    drain(core)

    recs = records_of(trace)
    assert len(recs) == 2, f"expected 2 records, got {len(recs)}"
    got_ms = recs[1]["step_cycle_us"] / 1000
    assert got_ms < 60, (
        f"second step recorded {got_ms:.0f} ms after a 250 ms idle gap; "
        f"the gap was charged to the batch"
    )
    print(
        f"ok  idle gap not charged: second step recorded {got_ms:.0f} ms "
        f"after a 250 ms idle"
    )


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("all capture checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
