"""Prove the wiring is live, and that its premises still hold.

WHY A SELFTEST AND NOT JUST A SMOKE TEST. The failure this guards
against is the quiet one. Every patch in _patch.py is gated on an env
var and wrapped in a try, so a shim that attaches nothing produces a
server that starts, answers /health, lists /v1/models and returns a
completion — right up until a scheduled step reaches a model runner
with no weights. Worse, if cuda_mock is loaded but the executor hook is
not, the symptoms look like a slow GPU rather than a broken install.
"it serves" is not evidence here, so this asks the four questions that
are.

It also re-measures what the wiring ASSUMES about vLLM, in the same
spirit as docker/wheel-verdict.py: a comment asserting that
`step_with_batch_queue` raises RuntimeError("unexpected error") is a
fact about one release. When a VLLM_REF bump changes it, this fails
with the reason rather than the serving path failing later with none.

Usage:  vllm-emu-selftest [--require-platform]
        vllm-emu-selftest --capture

  --require-platform  also resolve vllm.platforms.current_platform and
                      require LLM-Emu's EmulatorPlatform. Needs a
                      readable VLLM_EMULATOR_PROFILE_PACK, so it is
                      opt-in: the wheel-build check has no pack.

  --capture           check the CAPTURE wiring instead, on a real GPU
                      build of vLLM. None of the emulator checks apply
                      there — that vLLM has a device backend and no
                      llm-emu — so this runs only the premises
                      _capture.py depends on.
"""

from __future__ import annotations

import inspect
import os
import sys

_FAILURES: list[str] = []


def _check(label: str, ok: bool, detail: str = "") -> bool:
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}{f' — {detail}' if detail else ''}")
    if not ok:
        _FAILURES.append(label)
    return ok


def _check_entry_points() -> None:
    from importlib.metadata import entry_points

    general = {e.name for e in entry_points(group="vllm.general_plugins")}
    platform = {e.name for e in entry_points(group="vllm.platform_plugins")}
    _check("shim registered in vllm.general_plugins", "rocm_bake_emu" in general,
           ", ".join(sorted(general)) or "none")
    # llm-emu's own entry point. Without it vLLM resolves a real
    # platform, cuda_mock never arms, and the run is not an emulation.
    _check("llm-emu registered in vllm.platform_plugins", "emulator" in platform,
           ", ".join(sorted(platform)) or "none")


def _check_vllm_build() -> None:
    import importlib.util
    from importlib.metadata import version as dist_version

    import vllm

    # The DISTRIBUTION version, not vllm.__version__.
    #
    # They disagree here, by upstream's construction rather than by
    # accident: setup.py calls get_version(write_to="vllm/_version.py")
    # first and appends the `+empty` local segment to the result
    # afterwards, so the module constant baked into the package is the
    # bare 0.33.0 while the wheel, its filename and its METADATA all
    # carry 0.33.0+empty. Measured on the first real build, where this
    # check read vllm.__version__ and failed against an image that was
    # entirely correct.
    #
    # The arch-free build is the point of this lane, so the suffix is
    # worth asserting — a device build has no business in this image.
    dist = dist_version("vllm")
    _check("vLLM is an arch-free (+empty) build", "empty" in dist,
           f"dist {dist}, module {getattr(vllm, '__version__', '?')}")

    _check("no compiled vllm._C in this build",
           importlib.util.find_spec("vllm._C") is None)


def _check_patches() -> None:
    from vllm_emu_shim._patch import _MARK, apply, armed

    if not _check("emulator armed by environment", armed(),
                  "set VLLM_EMULATOR_ENABLE_ORACLE=1"):
        return

    apply()

    import vllm.v1.engine.core as core_mod
    import vllm.v1.executor.uniproc_executor as uni_mod

    _check("UniProcExecutor patched", getattr(uni_mod.UniProcExecutor, _MARK, False))
    _check("EngineCore patched", getattr(core_mod.EngineCore, _MARK, False))

    # Premise 1: the methods we wrap still take non_block, which is what
    # carries the oracle's pending Future to the async engine.
    for name in ("execute_model", "sample_tokens"):
        sig = inspect.signature(getattr(uni_mod.UniProcExecutor, name))
        _check(f"UniProcExecutor.{name} still takes non_block",
               "non_block" in sig.parameters, str(sig))

    # Premise 2: the empty-batch guard in _patch.py keys off this exact
    # literal, because the condition it replaces sits mid-method.
    src = inspect.getsource(core_mod)
    _check('EngineCore still raises RuntimeError("unexpected error")',
           'RuntimeError("unexpected error")' in src)


def _check_pack_resolves_at_startup() -> None:
    """A fresh interpreter must have the pack before anything is imported.

    llm-emu reads VLLM_EMULATOR_PROFILE_PACK when vLLM loads platform
    plugins, which is before this package is imported, so resolving it
    from here is too late for the first process — the API server came
    up as llm-emu's fallback "Emulator Device, 12GB" while the engine
    core came up as the device the pack describes. The .pth fixes that,
    and a .pth is easy to lose: a build that stops copying it, or an
    install path that drops it, changes nothing this process can see,
    because by now the variable is set either way. So ask a child that
    starts without it.

    Only meaningful when a pack wheel is installed. With the variable
    set by hand and no pack wheel there is nothing for the .pth to do.
    """
    import subprocess
    from importlib.metadata import entry_points

    # Exactly one. With none there is nothing to resolve, and with
    # several the resolver deliberately leaves the choice to whoever
    # installed them — a child started without the variable is then
    # SUPPOSED to come back without it.
    if len(list(entry_points(group="vllm_emu_shim.profile_packs"))) != 1:
        return

    env = {k: v for k, v in os.environ.items()
           if k != "VLLM_EMULATOR_PROFILE_PACK"}
    env["VLLM_EMULATOR_ENABLE_ORACLE"] = "1"
    probe = ("import os, sys; "
             "sys.stdout.write(os.environ.get('VLLM_EMULATOR_PROFILE_PACK', ''))")
    try:
        got = subprocess.run([sys.executable, "-c", probe], env=env,
                             capture_output=True, text=True, timeout=60)
        out, err = got.stdout.strip(), got.stderr.strip()
    except Exception as exc:  # noqa: BLE001
        out, err = "", repr(exc)
    _check("pack resolved at interpreter startup, before any import",
           bool(out) and os.path.exists(out),
           out or f"unset in a fresh interpreter — is the .pth installed? {err}")
    # A .pth that writes to stdout corrupts every tool that parses a
    # subprocess's output, so silence is part of the contract.
    try:
        quiet = subprocess.run([sys.executable, "-c", "pass"], env=env,
                               capture_output=True, text=True, timeout=60)
        noise = (quiet.stdout + quiet.stderr).strip()
    except Exception as exc:  # noqa: BLE001
        noise = repr(exc)
    _check("interpreter startup stays silent", not noise, noise[:120])


def _check_platform() -> None:
    pack = os.environ.get("VLLM_EMULATOR_PROFILE_PACK", "")
    if not _check("profile pack readable", bool(pack) and os.path.exists(pack),
                  pack or "VLLM_EMULATOR_PROFILE_PACK unset"):
        return
    _check_pack_resolves_at_startup()

    from vllm.platforms import current_platform

    name = type(current_platform).__name__
    _check("current_platform is LLM-Emu's EmulatorPlatform",
           name == "EmulatorPlatform", name)

    from vllm_emu_shim._patch import _MARK

    _check("EmulatorPlatform patched by the shim",
           getattr(type(current_platform), _MARK, False))

    # The one gap the shim fills, asserted rather than assumed: without
    # it gpu_worker.init_device() raises on every startup, cuda_mock
    # swallows it, and the engine core dies later with no root cause.
    # See _patch.py's _patch_emulator_platform.
    try:
        current_platform.manual_seed_all(0)
        _check("Platform.manual_seed_all is answerable", True)
    except NotImplementedError:
        _check("Platform.manual_seed_all is answerable", False,
               "the shim did not patch EmulatorPlatform")

    # The accelerator memory API, which init_device unpacks into two
    # names. A None here is the "cannot unpack non-iterable NoneType"
    # that ran the lane through an exception handler for three builds.
    import torch

    acc = getattr(torch, "accelerator", None)
    if acc is not None and hasattr(acc, "get_memory_info"):
        try:
            info = acc.get_memory_info(torch.device("cuda", 0))
            ok = isinstance(info, tuple) and len(info) == 2
        except Exception as exc:  # noqa: BLE001
            info, ok = exc, False
        _check("torch.accelerator.get_memory_info returns (free, total)",
               ok, repr(info))

    # The other half of the same memory probe, and the one that broke
    # on v0.33.0 -> v0.34.0. vLLM made CacheConfig.gpu_memory_utilization
    # Optional[float] defaulting to None, resolved through a property;
    # llm-emu's cuda_mock reads the raw field and float(None) raises
    # inside _initialize_kv_caches. Measured as a contract on vLLM's own
    # class, so a vLLM that changes it again fails here rather than at
    # the first served request.
    try:
        from vllm.config import CacheConfig

        field = getattr(CacheConfig, "__dataclass_fields__", {}).get(
            "gpu_memory_utilization")
        default = getattr(field, "default", object())
        # pydantic wraps it: the dataclass default is a FieldInfo whose
        # own .default carries the None.
        optional = default is None or getattr(default, "default", object()) is None
        resolver = hasattr(CacheConfig, "resolved_gpu_memory_utilization")
        _check("CacheConfig.gpu_memory_utilization is settleable",
               (not optional) or resolver,
               "defaults to None and vLLM ships no "
               "resolved_gpu_memory_utilization to copy")
    except ImportError as exc:  # noqa: BLE001
        _check("CacheConfig.gpu_memory_utilization is settleable",
               False, f"could not import: {exc}")

    # The return type the executor destructures across every worker.
    try:
        from vllm.v1.worker.gpu_worker import Worker
        from vllm.v1.worker.worker_base import CompilationTimes

        got = Worker.compile_or_warm_up_model(None)
        _check("Worker.compile_or_warm_up_model returns CompilationTimes",
               isinstance(got, CompilationTimes), repr(got))
    except ImportError as exc:  # noqa: BLE001
        _check("Worker.compile_or_warm_up_model returns CompilationTimes",
               False, f"could not import: {exc}")

    _report_platform_gaps(current_platform)


def _report_platform_gaps(current_platform) -> None:
    """List every Platform method EmulatorPlatform leaves unimplemented.

    Informational, deliberately not a failure. LLM-Emu's platform was
    written against vLLM 0.18.1 and the interface has moved fifteen
    releases since; the gaps that remain guard features that genuinely
    do not work here (LoRA, multi-process DP, encoder-decoder KV
    sharing), so they SHOULD keep raising rather than be stubbed into
    silently wrong behaviour.

    What this buys is seeing them all at once. manual_seed_all was
    found the expensive way — a full build, a failed serve, and a
    traceback that named nothing — and the next one would have cost the
    same again. A list printed on every build turns that into a glance.
    """
    import inspect

    from vllm.platforms.interface import Platform

    cls = type(current_platform)
    gaps = []
    for attr in sorted(dir(Platform)):
        if attr.startswith("__"):
            continue
        base = inspect.getattr_static(Platform, attr, None)
        impl = inspect.getattr_static(cls, attr, None)
        if base is None or base is not impl:
            continue  # overridden by EmulatorPlatform or the shim
        func = getattr(base, "__func__", base)
        if not callable(func):
            continue
        try:
            src = inspect.getsource(func)
        except (OSError, TypeError):
            continue
        if "raise NotImplementedError" in src:
            gaps.append(attr)

    if gaps:
        print(f"  note  {len(gaps)} Platform method(s) still unimplemented, "
              f"each raising if reached:")
        for attr in gaps:
            print(f"          {attr}")


def _check_capture() -> None:
    """The premises vllm_emu_shim/_capture.py rests on, re-measured.

    The capture wiring attributes each step's device time to a batch by
    wrapping EngineCore.capture_iteration_details, on the strength of
    one fact about vLLM: both step paths call it with the batch whose
    result they are about to wait for. If a release moves that wait,
    or stops passing the scheduler output, tracing would keep writing
    plausible numbers filed under the wrong batch — the failure that
    made upstream's own wiring unusable on v0.33. So the facts are
    checked rather than trusted.
    """
    import dataclasses

    import vllm.v1.engine.core as core_mod
    from vllm.v1.core.sched.output import CachedRequestData, SchedulerOutput

    from vllm_emu_shim import _capture

    cls = core_mod.EngineCore
    cid = getattr(cls, "capture_iteration_details", None)
    if not _check("EngineCore.capture_iteration_details exists", cid is not None):
        return
    sig = inspect.signature(cid)
    _check("capture_iteration_details takes scheduler_output",
           "scheduler_output" in sig.parameters, str(sig))

    for name in ("step", "step_with_batch_queue"):
        fn = getattr(cls, name, None)
        if not _check(f"EngineCore.{name} exists", fn is not None):
            continue
        src = inspect.getsource(inspect.unwrap(fn))
        _check(f"{name} waits inside capture_iteration_details(scheduler_output)",
               "self.capture_iteration_details(scheduler_output)" in src)
        _check(f"{name} submits with model_executor.execute_model",
               "self.model_executor.execute_model(" in src)

    so_fields = {f.name for f in dataclasses.fields(SchedulerOutput)}
    need = {"scheduled_new_reqs", "scheduled_cached_reqs",
            "num_scheduled_tokens", "total_num_scheduled_tokens"}
    _check("SchedulerOutput still has the fields a batch is described by",
           need <= so_fields, ", ".join(sorted(need - so_fields)) or "all present")
    cached_fields = {f.name for f in dataclasses.fields(CachedRequestData)}
    _check("CachedRequestData still has req_ids and num_computed_tokens",
           {"req_ids", "num_computed_tokens"} <= cached_fields)

    # And that the patch takes on this vLLM.
    _capture._patch_engine_core(core_mod)
    _check("EngineCore patched for capture",
           getattr(cls, _capture._MARK, False))


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    require_platform = "--require-platform" in argv

    if "--capture" in argv:
        print("vllm-emu-selftest --capture")
        _check_capture()
        if _FAILURES:
            print(f"\n{len(_FAILURES)} check(s) failed: {', '.join(_FAILURES)}")
            return 1
        print("\nall checks passed")
        return 0

    print("vllm-emu-selftest")
    _check_entry_points()
    _check_vllm_build()
    _check_patches()
    if require_platform:
        _check_platform()

    if _FAILURES:
        print(f"\n{len(_FAILURES)} check(s) failed: {', '.join(_FAILURES)}")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
