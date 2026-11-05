#!/usr/bin/env python3
"""Let ATOM's samplers run on RDNA, where AITER's topk_select refuses.

ATOM calls `aiter.topk_select` in two modules and `aiter/ops/topk_select.py`
gates the op to

    _SUPPORTED_GFX = ("gfx942", "gfx950", "gfx1250")

so on any RDNA part the first forward dies with "topk_select is not supported
on gfx1151". gfx1201 is absent from that tuple too, which makes this every
RDNA card including the one ATOM's README advertises as Experimental.

torch.topk is the same operation. ATOM's own comments say so — sampler.py
calls its k=1 use "the pick `torch.argmax` made", and rejection_sampler.py
says `tie="low"` "is the whole reason its answer is the same pick
`torch.argmax`/`torch.topk` made".

Rather than rewrite call sites, this rebinds the imported name: the aiter
symbol is aliased to `_aiter_topk_select` and a wrapper takes its place.
Every existing call works unchanged, including the k>1 one in
rejection_sampler.py that has no argmax equivalent.

The dispatch is at RUNTIME, probed once and cached in a module global. Two
reasons it is not a build-time architecture switch. The atom wheel is
architecture-independent and measured to be so — 1204 of 1206 files are
byte-identical across gfx950 and gfx1151 — and baking an arch decision in
would make that false for no gain. And on CDNA the fused AITER kernel is
still the faster path, so it stays selected there.

One behavioural caveat, deliberately accepted. `tie="low"` asks AITER for
lowest-index tie-breaking; torch.topk does not document its tie rule. It is
deterministic for a given input and build, so the rank-consistency
rejection_sampler.py needs still holds — every TP rank runs the same kernel
over the same row and gets the same answer. What is not guaranteed is that a
tie resolves the same way as AITER would resolve it. rejection_sampler.py's
own comment records measuring this: on 64-256 rows of three vocabularies,
slot 0 moved on 2 rows of 256 and in both the tied ids held equal
probability.

Run from the root of an ATOM checkout. Idempotent, and a no-op once the
import has been rewritten, so re-running or a future upstream fix leaves it
alone. Exits non-zero if either file is shaped unexpectedly, because a third
shape means this patch no longer understands what it is editing.
"""

from __future__ import annotations

import re
import sys

TARGETS = [
    "atom/model_ops/sampler.py",
    "atom/model_ops/rejection_sampler.py",
]

WATCHDOG = "atom/distributed/nccl_watchdog.py"

# torch 2.15 creates an `nccl2` ProcessGroup by default. ATOM predates it:
# drain_nccl_works() calls group._wait_for_pending_works() for any backend
# named "nccl", and torch raises
#
#   RuntimeError: Only ProcessGrouppNCCL supports waitForPendingWorks,
#                 but got nccl2 backend.
#
# which kills engine startup before the server ever listens.
#
# Skipping is correct rather than a bypass. The drain exists solely to retire
# works tracked by ProcessGroupNCCL's *watchdog*, whose poll can land inside a
# graph capture and invalidate it with hipErrorCapturedEvent. nccl2 keeps no
# such watchdog list -- which is exactly why torch refuses the call -- so
# there is nothing pending for it to retire and nothing to invalidate a
# capture. ATOM's own comment already handles one backend that refuses the
# call ("gloo refuses the call"); this is a third case it could not know
# about.
#
# The conservative alternative, if a capture ever does misbehave here, is to
# put the engine back on the implementation ATOM was written against:
# TORCH_DIST_USE_NCCL2=0 in the environment selects the legacy
# ProcessGroupNCCL (torch/distributed/distributed_c10d.py gates on exactly
# that variable). This patch means it is not required.
WATCHDOG_OLD = """        if backend == "nccl":
            group._wait_for_pending_works()"""

WATCHDOG_NEW = '''        if backend == "nccl":
            try:
                group._wait_for_pending_works()
            except RuntimeError:
                # torch 2.15's nccl2 ProcessGroup raises instead of
                # no-op'ing; it keeps no watchdog list, so there is
                # nothing to drain. See docker/atom-topk-fallback.py.
                pass'''

SHIM = [
    "",
    "",
    "# Injected by docker/atom-topk-fallback.py -- see that file for why.",
    "# AITER's topk_select is gated to CDNA + gfx1250; torch.topk is the",
    "# same operation everywhere else. Probed once, cached, so CDNA keeps",
    "# the fused kernel and this wheel stays architecture-independent.",
    "_ATOM_TOPK_OK = None",
    "",
    "",
    "def topk_select(input, topk, sorted=False, return_value=False,",
    "                indices_type=torch.int32, **kwargs):",
    "    global _ATOM_TOPK_OK",
    "    if _ATOM_TOPK_OK is None:",
    "        try:",
    "            from aiter import get_gfx",
    "            from aiter.ops.topk_select import _SUPPORTED_GFX",
    "            _ATOM_TOPK_OK = get_gfx() in _SUPPORTED_GFX",
    "        except Exception:",
    "            _ATOM_TOPK_OK = False",
    "    if _ATOM_TOPK_OK:",
    "        return _aiter_topk_select(",
    "            input, topk, sorted=sorted, return_value=return_value,",
    "            indices_type=indices_type, **kwargs",
    "        )",
    "    values, idx = torch.topk(input, topk, dim=-1, sorted=True)",
    "    return (values if return_value else None), idx.to(indices_type)",
]

# aiter's topk_select always returns a 2-tuple, with the first element None
# unless return_value=True -- its docstring is explicit that return_value
# "sets the first element to None rather than changing the arity". The shim
# above matches that, which is what lets all three call shapes in ATOM work
# untouched:
#
#   topk_select(probs, 1, tie="low")[1].view(-1)                  sampler.py
#   _, argmax = topk_select(target_probs, 1, tie="low")           rejection
#   vals, ids = topk_select(p, N, sorted=True, tie="low",         rejection
#                           return_value=True)

IMPORT_RE = re.compile(r"^from aiter import (.*)topk_select(.*)$", re.MULTILINE)


def patch(path: str) -> bool:
    try:
        with open(path) as fh:
            src = fh.read()
    except FileNotFoundError:
        sys.exit(f"atom topk: {path} is missing; re-check this patch")

    if "_aiter_topk_select" in src:
        print(f"atom topk: {path} already patched, nothing to do")
        return False

    match = IMPORT_RE.search(src)
    if not match:
        sys.exit(
            f"atom topk: no 'from aiter import ... topk_select' in {path}; "
            "re-check this patch"
        )

    # The shim calls torch.topk and annotates with torch.int32, so the module
    # has to already import torch. Every current target does; assert rather
    # than add an import, because a file that does not is not one this patch
    # understands.
    if not re.search(r"^import torch$", src, re.MULTILINE):
        sys.exit(f"atom topk: {path} has no module-level 'import torch'")

    old = match.group(0)
    new = old.replace("topk_select", "topk_select as _aiter_topk_select", 1)
    with open(path, "w") as fh:
        fh.write(src.replace(old, new + "\n".join(SHIM), 1))
    print(f"atom topk: {path} now dispatches at runtime")
    return True


def patch_watchdog() -> bool:
    try:
        with open(WATCHDOG) as fh:
            src = fh.read()
    except FileNotFoundError:
        sys.exit(f"atom nccl2: {WATCHDOG} is missing; re-check this patch")

    if "nccl2 ProcessGroup raises instead" in src:
        print(f"atom nccl2: {WATCHDOG} already patched, nothing to do")
        return False

    if src.count(WATCHDOG_OLD) != 1:
        sys.exit(
            f"atom nccl2: {WATCHDOG} does not contain the expected "
            "_wait_for_pending_works call; re-check this patch"
        )

    with open(WATCHDOG, "w") as fh:
        fh.write(src.replace(WATCHDOG_OLD, WATCHDOG_NEW, 1))
    print(f"atom nccl2: {WATCHDOG} now tolerates torch 2.15's nccl2 backend")
    return True


def main() -> None:
    done = sum(patch(p) for p in TARGETS) + patch_watchdog()
    if done == 0:
        print("atom patches: nothing needed patching")


if __name__ == "__main__":
    main()
