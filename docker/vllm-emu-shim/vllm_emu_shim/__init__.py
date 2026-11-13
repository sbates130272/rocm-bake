"""rocm-bake's wiring between vLLM and LLM-Emu.

The whole package is one idea: everything LLM-Emu needs inside vLLM is
applied to vLLM's classes at plugin-load time, so no vLLM source is
patched and a VLLM_REF bump cannot leave a stale diff behind. See
_patch.py for what is applied and why each piece is needed.

Entry point: `vllm.general_plugins` -> install.
"""

from ._patch import apply, armed

__all__ = ["apply", "armed", "install"]

__version__ = "0.1.0"

_installed = False


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
