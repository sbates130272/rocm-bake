"""rocm-bake's wiring between vLLM and LLM-Emu.

The whole package is one idea: everything LLM-Emu needs inside vLLM is
applied to vLLM's classes at plugin-load time, so no vLLM source is
patched and a VLLM_REF bump cannot leave a stale diff behind. See
_patch.py for what is applied and why each piece is needed.

Entry point: `vllm.general_plugins` -> install.
"""

import os

from ._patch import apply, armed

__all__ = ["apply", "armed", "install", "default_profile_pack"]

__version__ = "0.1.0"

_installed = False

PACK_ENTRY_POINT_GROUP = "vllm_emu_shim.profile_packs"


def default_profile_pack() -> str | None:
    """Point VLLM_EMULATOR_PROFILE_PACK at an installed pack, if there is one.

    Packs ship as their own wheels — vllm-emu-pack-<device> — because a
    pack describes one device while this package describes none. Each
    registers a `vllm_emu_shim.profile_packs` entry point, so a pack is
    found by being installed rather than by this code knowing a path.

    Called at import, before anything reads the variable. That timing
    matters: llm-emu's EmulatorPlatform loads the pack to answer
    get_device_name and get_device_total_memory, and vLLM sizes its KV
    cache from the latter — so a default arriving late would silently
    emulate a differently-sized device.

    Exactly one installed pack is used. Several is ambiguous and the
    choice belongs to whoever installed them, so it says what it found
    and leaves the variable alone. An explicit setting always wins:
    this is setdefault, never an override.
    """
    if os.environ.get("VLLM_EMULATOR_PROFILE_PACK"):
        return os.environ["VLLM_EMULATOR_PROFILE_PACK"]

    from importlib.metadata import entry_points

    found = {}
    for ep in entry_points(group=PACK_ENTRY_POINT_GROUP):
        try:
            found[ep.name] = ep.load()()
        except Exception as exc:  # noqa: BLE001
            print(f"[vllm-emu-shim] profile pack {ep.name!r} failed to "
                  f"resolve: {exc}")

    if not found:
        return None
    if len(found) > 1:
        print(f"[vllm-emu-shim] {len(found)} profile packs installed "
              f"({', '.join(sorted(found))}) — set "
              f"VLLM_EMULATOR_PROFILE_PACK to choose one")
        return None

    name, path = next(iter(found.items()))
    os.environ["VLLM_EMULATOR_PROFILE_PACK"] = path
    print(f"[vllm-emu-shim] profile pack {name!r} -> {path}")
    return path


default_profile_pack()


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
    if apply():
        print("[vllm-emu-shim] emulator wiring armed")
