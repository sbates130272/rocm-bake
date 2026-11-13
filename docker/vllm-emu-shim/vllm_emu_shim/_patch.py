"""The emulator wiring, applied to vLLM's classes rather than its source.

WHY THIS EXISTS. LLM-Emu ships the same wiring as a unified diff in
vllm_patches/llm-emu-vllm-0.18.1.patch, to be applied to a vLLM
checkout or dropped over an installed one as three whole pre-patched
files. Neither works here. The diff is cut against upstream commit
a26e8dc7f0 (~v0.18.1) and this repo pins v0.33.0; measured against that
tag, five of seven hunks in vllm/v1/engine/core.py and one of four in
vllm/v1/executor/uniproc_executor.py fail, and the file-override path
would replace v0.33.0 files with v0.18.1 ones outright. Upstream says as
much in vllm_patches/README.md: "upgrading vLLM to a newer release
likely requires regenerating the patch".

Regenerating it per bump is the thing this file avoids. The wiring is
small and it attaches to named methods, so it can be applied to the
classes at import time and carried across vLLM releases by signature
rather than by line number.

WHAT IS ACTUALLY NEEDED. The patch adds ~170 lines; emulation needs
about 25 of them. The rest is StepCycleTracer instrumentation in
core.py, used to CAPTURE a profile pack on a real GPU — not to replay
one. We consume upstream's packs, so none of it is reproduced here.
What is left:

  * UniProcExecutor.__init__       attach the executor hook
  * UniProcExecutor.execute_model  hand the step to the oracle
  * UniProcExecutor.sample_tokens  return the oracle's pending Future
  * UniProcExecutor.shutdown       release it
  * EngineCore.step_with_batch_queue   survive an empty batch

The third one is not optional and not cosmetic: the async engine
requires a PENDING Future while the next batch is scheduled, so the
hook's timer Future has to reach the engine rather than a resolved
stand-in. See ExecutorEmulatorHook._handle_async in llm-emu.

WHY THE EXECUTOR HOOK AT ALL, given cuda_mock. llm-emu's cuda_mock
stubs GPUModelRunner.load_model, profile_run and dummy_run, so no
weights are ever materialised — but it supplies no forward pass and no
latency. Its own comment says "hook+oracle drive latency". Without this
wiring the first scheduled step calls a model runner that has no model.

SCOPE. Every patch below is inert unless VLLM_EMULATOR_ENABLE_ORACLE is
set; with it unset, vLLM's own code runs unchanged, which is the same
property upstream's patch claims for itself.
"""

from __future__ import annotations

import functools
import os
import sys
from concurrent.futures import Future

# Set on each class we touch, so a second install() — and vLLM calls
# load_general_plugins() in process0, the engine core process and every
# worker — does not wrap a wrapper.
_MARK = "_rocm_bake_emu_patched"

_TRUE = ("1", "true", "yes")


def armed() -> bool:
    """True when the emulator should be wired in.

    VLLM_EMULATOR_EXECUTOR_HOOK is the knob upstream's patch gates on.
    Here it only has to say NO: upstream defaults the executor hook off
    because it also ships a worker-level path, and we do not install
    that path, so for this build "oracle enabled" means "wire the
    executor hook". Setting it to 0 still turns the wiring off.
    """
    if os.environ.get("VLLM_EMULATOR_ENABLE_ORACLE", "").lower() not in _TRUE:
        return False
    hook_env = os.environ.get("VLLM_EMULATOR_EXECUTOR_HOOK")
    if hook_env is not None and hook_env.lower() not in _TRUE:
        return False
    return True


def _module_patcher(target, patch_fn, label):
    """Run patch_fn over `target` whether or not it is imported yet.

    Reuses llm-emu's own meta-path hook when it is importable, so there
    is one implementation of this in the process rather than two
    competing ones — cuda_mock arms the same mechanism for
    GPUModelRunner and gpu_worker. The local fallback exists only so
    this package has no hard import of llm-emu.
    """
    mod = sys.modules.get(target)
    if mod is not None:
        # Already imported. Patching the class in place is enough:
        # nothing has constructed an executor or an engine core this
        # early, and both are looked up as attributes at call time.
        patch_fn(mod)
        return

    try:
        from vllm_emulator.cuda_mock import _install_module_patcher
    except Exception:
        _install_module_patcher = None

    # That import can itself pull the target in — vllm_emulator.platform
    # is one import away from cuda_mock — and a hook armed after the
    # module has finished loading never fires, because find_spec is not
    # called again. Re-check before arming anything.
    mod = sys.modules.get(target)
    if mod is not None:
        patch_fn(mod)
        return

    if _install_module_patcher is not None:
        _install_module_patcher(target, patch_fn, label)
        return

    import importlib.abc
    import importlib.util

    class _Patcher(importlib.abc.MetaPathFinder):
        def find_spec(self, fullname, path, _target=None):
            if fullname != target:
                return None
            sys.meta_path.remove(self)
            try:
                spec = importlib.util.find_spec(fullname)
            finally:
                if self not in sys.meta_path:
                    sys.meta_path.insert(0, self)
            if spec is None or spec.loader is None:
                return None
            real_loader = spec.loader
            outer = self

            class _WrappedLoader(importlib.abc.Loader):
                def create_module(self, _spec):
                    return real_loader.create_module(_spec)

                def exec_module(self, module):
                    real_loader.exec_module(module)
                    patch_fn(module)
                    if outer in sys.meta_path:
                        sys.meta_path.remove(outer)

            spec.loader = _WrappedLoader()
            return spec

    sys.meta_path.insert(0, _Patcher())


def _none_result(non_block):
    """What the executor returns for a step the oracle did not run.

    The async engine distinguishes "no output" from "not finished" by
    whether it got a Future, so the shape has to match what the caller
    asked for: a resolved Future when non_block, a bare None otherwise.
    """
    if not non_block:
        return None
    fut = Future()
    fut.set_result(None)
    return fut


def _patch_uniproc_executor(module) -> None:
    cls = getattr(module, "UniProcExecutor", None)
    if cls is None or getattr(cls, _MARK, False):
        return

    orig_init = cls.__init__
    orig_execute_model = cls.execute_model
    orig_sample_tokens = cls.sample_tokens
    orig_shutdown = cls.shutdown

    def _hook_of(self):
        return getattr(self, "_emulator_executor_hook", None)

    @functools.wraps(orig_init)
    def __init__(self, *args, **kwargs):
        orig_init(self, *args, **kwargs)
        hook = None
        try:
            from vllm_emulator.hooks.executor_hook import get_executor_hook

            hook = get_executor_hook()
        except Exception as exc:  # noqa: BLE001
            # Loud, not silent. A missing or broken llm-emu here means
            # the server comes up and serves real-looking latency from
            # a model runner with no weights, which fails later and
            # further away.
            print(f"[vllm-emu-shim] executor hook unavailable: {exc}")
        self._emulator_executor_hook = hook
        if hook is not None:
            print("[vllm-emu-shim] executor hook attached to UniProcExecutor")
            return

        # Armed, but no hook. get_executor_hook() returns None without
        # raising when VLLM_EMULATOR_PROFILE_PACK is unset or the pack
        # fails to load — there is no exception to report, and until
        # now nothing said anything.
        #
        # Refusing to start is the right response rather than an
        # abundance of caution. With no hook every step delegates to a
        # real worker, and no weights were loaded, so the first request
        # dies somewhere inside the model runner with a traceback that
        # names an attribute rather than the missing file. That is a
        # long way from the cause, and it is reachable the moment
        # someone installs these wheels from the index: the pack ships
        # in the image, not in any wheel.
        raise RuntimeError(
            "vllm-emu-shim: the emulator is enabled "
            "(VLLM_EMULATOR_ENABLE_ORACLE) but no executor hook could be "
            "built. Set VLLM_EMULATOR_PROFILE_PACK to a readable profile "
            "pack — currently "
            f"{os.environ.get('VLLM_EMULATOR_PROFILE_PACK') or '<unset>'!r}. "
            "Without one there is nothing to draw step latencies from, "
            "and serving would fall through to a worker that has no model."
        )

    @functools.wraps(orig_execute_model)
    def execute_model(self, scheduler_output, *args, **kwargs):
        hook = _hook_of(self)
        non_block = kwargs.get("non_block", args[0] if args else False)
        if hook is None or not hook.is_enabled:
            return orig_execute_model(self, scheduler_output, *args, **kwargs)
        if hook.should_use_oracle(scheduler_output):
            return hook.create_delayed_future(
                scheduler_output, non_block=non_block
            )
        # The emulator is armed but the oracle declined this batch —
        # should_use_oracle is False only when total_num_scheduled_tokens
        # is 0. Upstream's patch falls through to the real worker here.
        # That cannot work on this build: there is no model, and on
        # v0.33.0 the call lands in the V2 model runner, which dies with
        #
        #   AttributeError: 'GPUModelRunner' object has no attribute
        #   'block_tables'
        #
        # at vllm/v1/worker/gpu/model_runner.py:1786 — the first real
        # request produced exactly that, after ten emulated steps had
        # already gone through the oracle. cuda_mock's runner stubs are
        # armed on vllm.v1.worker.gpu_model_runner, the V1 module, so
        # the V2 runner is unstubbed; but forcing V1 would only move the
        # crash, because neither runner can execute a model that was
        # never loaded.
        #
        # So the rule is stronger than upstream's: while the emulator is
        # armed, model execution NEVER reaches a worker. An empty batch
        # returns the same None the real path would have produced for
        # one, and _patch_engine_core turns that into ({}, False) —
        # which is what upstream's own core.py patch does for this case.
        return _none_result(non_block)

    @functools.wraps(orig_sample_tokens)
    def sample_tokens(self, grammar_output, *args, **kwargs):
        hook = _hook_of(self)
        non_block = kwargs.get("non_block", args[0] if args else False)
        if hook is not None and hook.is_enabled:
            if hook.has_pending_future():
                fut = hook.get_sample_future()
                return fut if non_block else fut.result()
            # No pending future means execute_model took the empty-batch
            # path above. Same reasoning: delegating would ask a worker
            # with no model to sample.
            return _none_result(non_block)
        return orig_sample_tokens(self, grammar_output, *args, **kwargs)

    @functools.wraps(orig_shutdown)
    def shutdown(self, *args, **kwargs):
        hook = _hook_of(self)
        if hook is not None:
            hook.shutdown()
        return orig_shutdown(self, *args, **kwargs)

    # functools.wraps on all four, and not only for the __name__ in a
    # traceback. Each wrapper takes (*args, **kwargs) so it survives a
    # signature change upstream — but that also erases the evidence of
    # what the signature WAS, and vllm-emu-selftest's job is to check
    # exactly that `execute_model` and `sample_tokens` still take
    # non_block. Measured on the first real build: the check read the
    # wrappers and reported "(self, scheduler_output, *args, **kwargs)"
    # — it was inspecting itself. wraps sets __wrapped__, which
    # inspect.signature follows by default, so the premise check sees
    # vLLM's signature rather than ours.
    cls.__init__ = __init__
    cls.execute_model = execute_model
    cls.sample_tokens = sample_tokens
    cls.shutdown = shutdown
    setattr(cls, _MARK, True)


def _patch_engine_core(module) -> None:
    """The one guard outside the executor.

    In mock mode a step can be scheduled with zero tokens; the worker
    path returns None for it, and upstream reads a None model_output as
    "the execute_model call failed", re-raises from exec_model_fut and
    then raises RuntimeError("unexpected error"). The patch adds an
    early return for exactly that case:

        if model_output is None:
            if scheduler_output.total_num_scheduled_tokens == 0:
                return {}, False

    That sits mid-method, so it cannot be inserted from outside. This
    converts the resulting exception back instead, which reaches the
    same state. It is narrow on purpose — the emulator must be armed,
    the exception must be RuntimeError, and its message must be the
    exact literal upstream raises. Anything else propagates untouched,
    including an exception from exec_model_fut.result(), which is a real
    failure and not this case.

    If a future vLLM changes that message, this stops matching and the
    empty-batch step raises again rather than failing quietly. That is
    the right way round, and vllm-emu-selftest asserts the literal is
    still present in the installed source.
    """
    cls = getattr(module, "EngineCore", None)
    if cls is None or getattr(cls, _MARK, False):
        return

    orig_step = getattr(cls, "step_with_batch_queue", None)
    if orig_step is None:
        return

    @functools.wraps(orig_step)
    def step_with_batch_queue(self, *args, **kwargs):
        try:
            return orig_step(self, *args, **kwargs)
        except RuntimeError as exc:
            if str(exc) != "unexpected error" or not armed():
                raise
            return {}, False

    cls.step_with_batch_queue = step_with_batch_queue
    setattr(cls, _MARK, True)


def _patch_emulator_platform(module) -> None:
    """Fill the one Platform method LLM-Emu's platform plugin is missing.

    EmulatorPlatform was written against vLLM 0.18.1's Platform
    interface. v0.33.0's has moved, and `manual_seed_all` is the gap
    that matters: vllm/utils/torch_utils.py's set_random_seed() calls
    it through current_platform unconditionally, and the base class
    raises NotImplementedError. gpu_worker.Worker.init_device() calls
    set_random_seed() at line 517, so on this vLLM init_device raised
    on EVERY startup — and because cuda_mock wraps the original
    init_device in a try/except, the failure was swallowed and the run
    fell through to cuda_mock's last-resort path, which hand-builds a
    GPUModelRunner or, failing that, installs a stub that returns None
    for every call. The engine core then died during handshake with
    "Engine core initialization failed. See root cause above" and no
    root cause above it at all, because the real one had been caught
    hundreds of lines earlier.

    A no-op is the whole fix and is not a shortcut. The method exists
    to seed a device RNG; there is no device, and set_random_seed has
    already called random.seed, np.random.seed and torch.manual_seed
    on the lines above it. Nothing is left unseeded.

    Scope: this is the ONLY Platform gap filled here. Several other
    base methods also raise NotImplementedError — get_punica_wrapper,
    stateless_init_device_torch_dist_pg,
    check_runner_kv_caches_multi_layer — and they are deliberately left
    raising, because each guards a feature that genuinely does not work
    here (LoRA, multi-process DP, encoder-decoder KV sharing) and a
    silent no-op would turn "unsupported" into "wrong". vllm-emu-selftest
    lists them, so the gap is visible without being papered over.
    """
    cls = getattr(module, "EmulatorPlatform", None)
    if cls is None or getattr(cls, _MARK, False):
        return

    if "manual_seed_all" not in cls.__dict__:
        def manual_seed_all(_cls, seed) -> None:  # noqa: ARG001
            return None

        cls.manual_seed_all = classmethod(manual_seed_all)
        print("[vllm-emu-shim] EmulatorPlatform.manual_seed_all supplied")

    _wrap_check_and_update_config(cls)
    setattr(cls, _MARK, True)


def _patch_gpu_worker(module) -> None:
    """Return the type v0.33.0's executor destructures, not a bare float.

    cuda_mock stubs the worker's compile_or_warm_up_model to `return 0.0`
    (cuda_mock.py:318-320), which was that method's return type once.
    v0.33.0 returns a NamedTuple — CompilationTimes(language_model,
    encoder) at vllm/v1/worker/worker_base.py:39-41 — and the executor
    destructures it across every worker:

        compilation_times = self.collective_rpc("compile_or_warm_up_model")
        if compilation_times:
            ... = max(t.language_model for t in compilation_times)

    vllm/v1/executor/abstract.py:135-147, which is how a stubbed 0.0
    becomes

        AttributeError: 'float' object has no attribute 'language_model'

    Note what this is NOT fixed by: that max() is guarded only by
    `if compilation_times:` and never by the compilation mode, so
    setting CompilationMode.NONE above does not avoid this path. The two
    are separate bugs that happen to meet in the same method.

    Both fields are supplied because there are two consecutive max()
    calls — language_model at :143 and encoder at :146 — and a one-field
    stand-in just moves the crash three lines down. 0.0/0.0 is the
    honest value: nothing was compiled, and engine/core.py:393 only logs
    the encoder time when it is greater than zero, so zeros stay quiet.

    Ordering against cuda_mock's own patcher is deterministic and in our
    favour, which is why no identity guard is needed here: each
    _install_module_patcher inserts its finder at sys.meta_path[0] and
    re-delegates, so the LAST finder armed is the outermost wrapper and
    runs its patch last. apply() imports cuda_mock — arming its
    gpu_worker finder — before arming this one. If the module is already
    imported, _module_patcher patches in place, which is also after.

    Deliberately not done by unstubbing and calling the real method:
    gpu_worker.py:937 reaches self.model_runner.eplb.suppress() there,
    and there is no model.
    """
    cls = getattr(module, "Worker", None)
    if cls is None or getattr(cls, _MARK, False):
        return

    try:
        from vllm.v1.worker.worker_base import CompilationTimes
    except ImportError as exc:  # noqa: BLE001
        print(f"[vllm-emu-shim] CompilationTimes unavailable: {exc}")
        return

    def compile_or_warm_up_model(self, *args, **kwargs):  # noqa: ARG001
        return CompilationTimes(language_model=0.0, encoder=0.0)

    cls.compile_or_warm_up_model = compile_or_warm_up_model
    setattr(cls, _MARK, True)
    print("[vllm-emu-shim] Worker.compile_or_warm_up_model returns "
          "CompilationTimes(0.0, 0.0)")


def _patch_accelerator_memory_info() -> None:
    """Make torch.accelerator.get_memory_info answer with a 2-tuple.

    v0.33.0 reads device memory through the accelerator API:

        self.free_memory, self.total_memory = \\
            torch.accelerator.get_memory_info(device)

    vllm/utils/mem_utils.py:143, reached from gpu_worker.py:541 when
    Worker.init_device builds its MemorySnapshot. cuda_mock stubs
    torch.accelerator by sweeping dir() and classifying names
    (cuda_mock.py:657-679); its classifier matches `mem_get_info` and
    `meminfo` but not `get_memory_info`, so that one falls through to
    the generic no-op and returns None. Unpacking None is the

        cannot unpack non-iterable NoneType object

    that has been failing init_device on every startup — caught by
    cuda_mock's try/except, which then hand-builds a GPUModelRunner. The
    lane has been running through that exception handler, with a dummy
    snapshot whose fields are named free_gpu_mem/total_gpu_mem rather
    than the free_memory/total_memory the real code reads.

    free == total, which is a requirement and not a shortcut:
    vllm/v1/worker/utils.py:761 raises ValueError when free_memory is
    below total * gpu_memory_utilization, so reporting a partly-used
    emulated device would fail the very check it is feeding.

    The size comes from the platform, so the profile pack stays the one
    source of truth for how big the emulated card is — the same value
    EmulatorPlatform.get_device_total_memory() reports to everything
    else, rather than a second constant that could disagree with it.

    Installed only if the real function does not already answer
    correctly, so a torch that behaves is left alone.
    """
    try:
        import torch
    except ImportError:
        return

    acc = getattr(torch, "accelerator", None)
    if acc is None or not hasattr(acc, "get_memory_info"):
        return

    try:
        probe = acc.get_memory_info(torch.device("cuda", 0))
        if isinstance(probe, tuple) and len(probe) == 2:
            return
    except Exception:  # noqa: BLE001
        pass

    def get_memory_info(device=None):  # noqa: ARG001
        from vllm.platforms import current_platform

        total = int(current_platform.get_device_total_memory())
        return (total, total)

    acc.get_memory_info = get_memory_info
    print("[vllm-emu-shim] torch.accelerator.get_memory_info supplied")


def _wrap_check_and_update_config(cls) -> None:
    """Turn torch.compile off in the way v0.33.0 understands.

    EmulatorPlatform's check_and_update_config does:

        vllm_config.compilation_config.enable = False

    and v0.33.0's CompilationConfig has no `enable` field at all. The
    assignment silently creates an attribute nothing reads, and
    compilation stays at its default — the engine's own config dump
    says so: `'mode': <CompilationMode.VLLM_COMPILE: 3>`.

    That is fatal here rather than merely slow. With load_model stubbed
    there is no model to trace, so _initialize_kv_caches reaches
    model_executor.compile_or_warm_up_model() and asks Inductor to
    compile a module that was never built.

    `mode = CompilationMode.NONE` is the v0.33.0 spelling of what
    upstream meant, applied after their own method runs so everything
    else it decides — device, worker_cls — is untouched.

    Deliberately not done by setting enforce_eager: that is a
    user-facing knob resolved earlier into this same field, and writing
    the field is both narrower and the thing actually read.
    """
    orig = cls.__dict__.get("check_and_update_config")
    if orig is None:
        return
    orig_func = getattr(orig, "__func__", orig)

    def check_and_update_config(_cls, vllm_config) -> None:
        orig_func(_cls, vllm_config)
        cc = getattr(vllm_config, "compilation_config", None)
        if cc is None or not hasattr(cc, "mode"):
            return
        try:
            from vllm.config import CompilationMode
        except ImportError:
            return
        if cc.mode != CompilationMode.NONE:
            print(f"[vllm-emu-shim] compilation {cc.mode!r} -> NONE "
                  f"(no model is loaded to compile)")
            cc.mode = CompilationMode.NONE

    cls.check_and_update_config = classmethod(check_and_update_config)


def _step(label, fn, *args) -> None:
    """Run one wiring step, and never let it take the others with it.

    vLLM's plugin loader wraps the whole entry point in a try/except
    that logs and moves on (vllm/plugins/__init__.py), so an exception
    raised from here does not stop the server — it produces a server
    with PART of the wiring installed and one log line to say so. That
    is the worst outcome available: a half-armed emulator looks like a
    working one until a specific call path is reached.

    Each step is independent, so a failure in one is reported loudly
    and the rest still arm. The selftest is what turns these prints
    into a verdict.
    """
    try:
        fn(*args)
    except Exception as exc:  # noqa: BLE001
        print(f"[vllm-emu-shim] {label} FAILED: {type(exc).__name__}: {exc}")


def apply() -> bool:
    """Arm the wiring. Returns True when it was armed, False when inert."""
    if not armed():
        return False
    # First: the platform plugin is resolved before anything else here
    # runs, so if it is already imported this patches it in place.
    _step("platform", _module_patcher, "vllm_emulator.platform",
          _patch_emulator_platform, "emulator_platform")
    # Then torch.accelerator, which cuda_mock has already swept by now —
    # this runs after its sweep, so the assignment sticks.
    _step("accelerator memory", _patch_accelerator_memory_info)
    _step("gpu_worker", _module_patcher, "vllm.v1.worker.gpu_worker",
          _patch_gpu_worker, "gpu_worker")
    _step("executor", _module_patcher, "vllm.v1.executor.uniproc_executor",
          _patch_uniproc_executor, "uniproc_executor")
    _step("engine core", _module_patcher, "vllm.v1.engine.core",
          _patch_engine_core, "engine_core")
    return True
