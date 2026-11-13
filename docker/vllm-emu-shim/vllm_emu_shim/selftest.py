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

  --require-platform  also resolve vllm.platforms.current_platform and
                      require LLM-Emu's EmulatorPlatform. Needs a
                      readable VLLM_EMULATOR_PROFILE_PACK, so it is
                      opt-in: the wheel-build check has no pack.
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


def _check_platform() -> None:
    pack = os.environ.get("VLLM_EMULATOR_PROFILE_PACK", "")
    if not _check("profile pack readable", bool(pack) and os.path.exists(pack),
                  pack or "VLLM_EMULATOR_PROFILE_PACK unset"):
        return
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


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    require_platform = "--require-platform" in argv

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
