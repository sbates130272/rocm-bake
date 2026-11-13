"""Resolve the installed profile pack into VLLM_EMULATOR_PROFILE_PACK.

Runs at interpreter startup, from vllm_emu_shim_pack.pth, and that
timing is the whole reason this module exists.

LLM-Emu reads VLLM_EMULATOR_PROFILE_PACK the moment `vllm_emulator` is
imported: its __init__ pulls in cuda_mock, which installs itself at
import and takes the device name, memory and compute-unit count from
the pack right then. vLLM imports it when it loads platform plugins —
which happens BEFORE it loads general plugins, the group this shim is
registered in. So a default set from the shim's own import arrived too
late for the first process. Measured on the first CI run with a pack
wheel: the API server came up as

    Fake GPU: Emulator Device, 12GB, SM=108, CC=8.0

llm-emu's built-in fallback, while the engine core — a child process
that inherited the variable once the shim had set it — came up as the
MI455X the pack describes. KV sizing happens in the engine, so the
smoke test passed; the two processes simply disagreed about what
device they were on.

A .pth file is the one hook that runs before any of that, in every
process, whatever imports what. So this has to be safe to run in every
interpreter that starts in the environment — pip, build helpers,
anything:

  * standard library only, and nothing imported until it is needed;
  * silent. A .pth that prints corrupts the stdout of every tool that
    parses a subprocess's output. What was resolved is reported later,
    by install(), when vLLM loads the plugin;
  * inert unless the emulator is switched on, so an ordinary process
    pays for two environment lookups and nothing else;
  * never raises.

It is a top-level module, outside the vllm_emu_shim package, for the
same reason. A .pth that imported `vllm_emu_shim._pack_env` would
execute the package's __init__ first, and with it the patching module
and everything that imports — in every interpreter, emulator or not,
and with any future import error there surfacing as a site traceback
on every Python start.
"""

import os

GROUP = "vllm_emu_shim.profile_packs"
_TRUE = ("1", "true", "yes")

# What the last resolution found, for install() to report: the pack
# names discovered, whether or not one was chosen.
found: dict = {}


def _emulator_on() -> bool:
    return (os.environ.get("VLLM_EMULATOR_ENABLE_ORACLE", "").lower() in _TRUE
            or os.environ.get("VLLM_EMULATOR_MOCK_CUDA", "").lower() in _TRUE)


def resolve():
    """Set VLLM_EMULATOR_PROFILE_PACK from the one installed pack.

    Returns the path in effect, or None. An explicit setting always
    wins. Exactly one installed pack is used; several is ambiguous and
    the choice belongs to whoever installed them, so the variable is
    left alone and install() says which were found.
    """
    current = os.environ.get("VLLM_EMULATOR_PROFILE_PACK")
    if current:
        return current
    if not _emulator_on():
        return None

    try:
        from importlib.metadata import entry_points

        packs = {}
        for ep in entry_points(group=GROUP):
            try:
                packs[ep.name] = ep.load()()
            except Exception:  # noqa: BLE001
                packs[ep.name] = None
    except Exception:  # noqa: BLE001
        return None

    found.clear()
    found.update(packs)
    usable = {k: v for k, v in packs.items() if v}
    if len(usable) != 1:
        return None

    path = next(iter(usable.values()))
    os.environ["VLLM_EMULATOR_PROFILE_PACK"] = path
    return path
