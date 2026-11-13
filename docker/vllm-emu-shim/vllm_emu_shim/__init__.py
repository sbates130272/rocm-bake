"""rocm-bake's wiring between vLLM and LLM-Emu.

The whole package is one idea: everything LLM-Emu needs inside vLLM is
applied to vLLM's classes at plugin-load time, so no vLLM source is
patched and a VLLM_REF bump cannot leave a stale diff behind. See
_patch.py for what is applied and why each piece is needed.

Entry point: `vllm.general_plugins` -> install.
"""

import os

import _vllm_emu_pack_env as _pack_env

from ._patch import apply, armed

__all__ = ["apply", "armed", "install", "default_profile_pack"]

__version__ = "0.1.0"

_installed = False

PACK_ENTRY_POINT_GROUP = _pack_env.GROUP


def default_profile_pack() -> str | None:
    """Point VLLM_EMULATOR_PROFILE_PACK at an installed pack, if there is one.

    Packs ship as their own wheels — vllm-emu-pack-<device> — because a
    pack describes one device while this package describes none. Each
    registers a `vllm_emu_shim.profile_packs` entry point, so a pack is
    found by being installed rather than by this code knowing a path.

    The resolution itself lives in _vllm_emu_pack_env and normally has
    already happened by the time this runs: vllm_emu_shim_pack.pth
    calls it at interpreter startup, because llm-emu reads the variable
    when vLLM loads platform plugins, which is before this package is
    imported. See that module for the run that showed it.

    install() calls this again. It is a no-op once the variable is set,
    and it covers the cases where startup found nothing: an editable
    install, which does not get the .pth, or a pack whose directory
    joined sys.path after the .pth line ran. A pack found only here is
    too late for a process that has already imported llm-emu, which is
    why install() says so rather than staying quiet.
    """
    return _pack_env.resolve()


def install() -> None:
    """vLLM general-plugin entry point.

    load_general_plugins() warns that a plugin "can be loaded for
    multiple times in different processes" and must tolerate it. This
    one does twice over: the flag below short-circuits a repeat inside
    one process, and every patch in _patch.py is itself marked and
    idempotent for the case where a fresh interpreter re-imports a
    module that was already patched in the parent before a fork.
    """
    global _installed
    if _installed:
        return
    _installed = True
    had_pack = bool(os.environ.get("VLLM_EMULATOR_PROFILE_PACK"))
    default_profile_pack()
    if apply():
        print("[vllm-emu-shim] emulator wiring armed")
        # Reported here rather than where it is resolved: resolution
        # runs from a .pth at interpreter startup and must stay silent.
        pack = os.environ.get("VLLM_EMULATOR_PROFILE_PACK")
        if pack and not had_pack:
            print("[vllm-emu-shim] profile pack was not resolved at "
                  "interpreter startup (no .pth — an editable install?); "
                  "this process may already be on llm-emu's fallback device")
        usable = sorted(k for k, v in _pack_env.found.items() if v)
        if len(usable) > 1:
            print(f"[vllm-emu-shim] {len(usable)} profile packs installed "
                  f"({', '.join(usable)}) — set VLLM_EMULATOR_PROFILE_PACK "
                  f"to choose one")
        elif pack:
            print(f"[vllm-emu-shim] profile pack: {pack}")
