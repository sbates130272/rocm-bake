#!/usr/bin/env python3
"""Re-measure a frozen manylinux verdict, and fail when its premise dies.

WHY THIS EXISTS. Two Dockerfiles here deliberately skip auditwheel and
write down why: Dockerfile.pytorch, because torch's own code references
a glibc newer than any manylinux policy auditwheel knows, and
Dockerfile.aiter, because at PREBUILD_KERNELS=0 that wheel contains no
x86_64 code for a platform tag to describe. Both were measured by hand
on 2026-11-06.

A measurement in a comment is a fact about one day. Bump the ROCm base
image to one built on an older glibc, or let auditwheel learn a policy
for a newer one, and torch becomes manylinux-eligible -- while the
build keeps shipping it as linux_x86_64, the narrowest tag there is,
for a reason that quietly stopped being true. Nothing in the build
would say so. That is what this fixes: each comment now has a check
that fails when the thing it asserts is no longer the case.

This is deliberately NOT `auditwheel show`. show unpacks the whole
wheel, and the wheel in question is the multi-gigabyte torch one, on a
builder that is already holding a full PyTorch build tree. The two
questions being asked are narrow enough to answer by streaming the
wheel's ELF members straight out of the zip.

Usage:  wheel-verdict.py TARGET {no-manylinux|no-cpu-code|report}

  TARGET is a wheel, a directory holding exactly one wheel, or a glob
  matching exactly one -- Dockerfile.triton builds triton_kernels into
  the same directory, so "the only wheel in /wheels" is not always a
  thing that exists. Exactly one, never "the first match": a glob that
  quietly picks one of two wheels is how the wrong artifact gets
  blessed.

  no-manylinux  Assert the wheel's compiled code needs a glibc newer
                than every manylinux policy auditwheel knows, so
                linux_x86_64 really is the only honest tag.

  no-cpu-code   Assert the wheel contains no x86_64 ELF at all, so
                there is nothing for a platform tag to describe.

  report        Assert nothing; print the measurement as JSON. This is
                what makes the verdict publishable rather than merely
                enforced -- .builders/wheelindex.py imports measure()
                and puts the result on the per-arch index page, for
                every wheel rather than only the ones a Dockerfile
                comment covers.
"""

from __future__ import annotations

import glob
import os
import re
import sys
import zipfile
from pathlib import Path

ELF_MAGIC = b"\x7fELF"
ELFDATA2LSB = 1
EM_X86_64 = 62

# The version strings live in .dynstr and are referenced from
# .gnu.version_r. Finding them by scanning rather than by parsing
# sections is the whole reason this stays cheap -- see the note on
# direction of error in max_glibc_ref() below.
GLIBC_RE = re.compile(rb"GLIBC_(\d+)\.(\d+)")

CHUNK = 8 << 20
# Longest possible match, so a version string split across two chunk
# boundaries is still seen exactly once.
OVERLAP = 32


def die(msg: str) -> None:
    # The lines already printed are the evidence for this message, and
    # they are on stdout. Without the flush they arrive after it.
    sys.stdout.flush()
    print(f"wheel-verdict: {msg}", file=sys.stderr)
    raise SystemExit(1)


def newest_policy(required: bool = True) -> tuple[tuple[int, int], str] | None:
    """The newest glibc any manylinux policy covers.

    NOT WheelPolicies.highest, which is the highest-*priority* policy --
    manylinux_2_5, the one compatible with the most hosts. The question
    here is the opposite one: the newest glibc that any policy is
    willing to describe. Nothing in the API answers it, so the names do.

    required=False for the callers that only want to describe a wheel
    rather than judge it. wheelindex.py runs on a build node and on a
    bare CI runner, neither of which has auditwheel for any other
    reason; "needs glibc 2.43" is still worth publishing there without
    it. Inside the images the check is the point, so it stays required
    -- a missing auditwheel must not quietly downgrade a gate to a
    description.
    """
    try:
        from auditwheel.architecture import Architecture
        from auditwheel.libc import Libc
        from auditwheel.policy import WheelPolicies
    except ImportError:
        if required:
            die("auditwheel is not installed, so the policy list is unknown")
        return None

    best: tuple[tuple[int, int], str] | None = None
    for policy in WheelPolicies(libc=Libc.GLIBC, arch=Architecture.x86_64):
        m = re.match(r"manylinux_(\d+)_(\d+)", policy.name)
        if not m:
            continue
        ver = (int(m.group(1)), int(m.group(2)))
        if best is None or ver > best[0]:
            best = (ver, policy.name)
    if best is None:
        die("auditwheel knows no manylinux policy at all -- it is broken")
    return best


def host_glibc() -> tuple[int, int] | None:
    raw = os.confstr("CS_GNU_LIBC_VERSION")  # e.g. "glibc 2.43"
    if not raw:
        return None
    m = re.search(r"(\d+)\.(\d+)", raw)
    return (int(m.group(1)), int(m.group(2))) if m else None


def is_x86_64_elf(head: bytes) -> bool:
    return (
        len(head) >= 20
        and head[:4] == ELF_MAGIC
        and head[5] == ELFDATA2LSB
        and int.from_bytes(head[18:20], "little") == EM_X86_64
    )


def elf_members(zf: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    """Every x86_64 ELF in the wheel, by content rather than by name.

    By content because the names are not reliable: torch ships
    libtorch_hip.so, a bare `atomesh`, and .so files under names with no
    extension at all, and a name-based filter is how one of them gets
    missed. The first 20 bytes of each member settle it.
    """
    out = []
    for info in zf.infolist():
        if info.is_dir() or info.file_size < 20:
            continue
        with zf.open(info) as f:
            if is_x86_64_elf(f.read(20)):
                out.append(info)
    return out


def max_glibc_ref(
    zf: zipfile.ZipFile, members: list[zipfile.ZipInfo]
) -> tuple[tuple[int, int], str] | None:
    """The newest GLIBC_x.y referenced anywhere in the wheel's binaries.

    DIRECTION OF ERROR. Scanning the whole member, not just .dynstr,
    can only ever report a version that is too NEW -- a GLIBC_2.99
    literal sitting in some unrelated rodata would be counted. It can
    never miss a real one, because a real symbol version is a literal
    string in the file. Too-new is the direction that would make this
    check pass when it should fail, so the caller also prints the host
    glibc as an independent upper bound; the two disagreeing is itself
    worth seeing in a build log.
    """
    best: tuple[tuple[int, int], str] | None = None
    for info in members:
        with zf.open(info) as f:
            tail = b""
            while chunk := f.read(CHUNK):
                buf = tail + chunk
                for m in GLIBC_RE.finditer(buf):
                    ver = (int(m.group(1)), int(m.group(2)))
                    if best is None or ver > best[0]:
                        best = (ver, info.filename)
                tail = buf[-OVERLAP:]
    return best


def sole_wheel(target: str) -> Path:
    path = Path(target)
    if path.is_file():
        return path
    if path.is_dir():
        found = sorted(path.glob("*.whl"))
        what = f"in {path}"
    else:
        # A glob. Resolved here rather than by the shell so the "exactly
        # one" rule still applies when the caller quoted it, and so the
        # error says what matched instead of the shell passing the
        # unexpanded pattern through as a filename.
        found = sorted(Path(p) for p in glob.glob(target))
        what = f"matching {target}"
    if len(found) != 1:
        names = ", ".join(p.name for p in found) or "none"
        die(f"expected exactly one wheel {what}, found {len(found)}: {names}")
    return found[0]


def measure(whl: Path) -> dict:
    """Describe one wheel's platform tag and the evidence behind it.

    The importable entry point. wheelindex.py calls this for every wheel
    it indexes -- including the ones no Dockerfile comment covers --
    so the published pages carry a measured reason for every tag rather
    than a reason for the four someone happened to write a note about.
    That omission is not hypothetical: vLLM shipped linux_x86_64 for
    months with nothing anywhere saying why.

    Keys:
      tag          the platform tag in the filename, as published
      kind         pure | no-cpu-code | constrained | manylinux
      needs_glibc  "2.43", or None when there is no CPU code to need one
      newest_policy the newest manylinux auditwheel knows, or None when
                   auditwheel is not installed (see newest_policy())
      best         True if `tag` is the best tag the symbols allow,
                   False if a better one is available and unused,
                   None if auditwheel was absent and we cannot say
    """
    m = re.match(
        r"^[^-]+-[^-]+(?:-\d[^-]*)?-[^-]+-[^-]+-(?P<platform>[^-]+)\.whl$",
        whl.name,
    )
    tag = m.group("platform") if m else "unknown"

    with zipfile.ZipFile(whl) as zf:
        members = elf_members(zf)
        found = max_glibc_ref(zf, members) if members else None

    pol = newest_policy(required=False)
    out = {
        "wheel": whl.name,
        "tag": tag,
        "elf_members": len(members),
        "needs_glibc": None,
        "newest_policy": pol[1] if pol else None,
        "best": None,
    }

    if not members:
        # py3-none-any is a different statement from "x86_64 with no CPU
        # code in it". The first says the wheel is portable; the second
        # says it is not, for a reason no platform tag can express. AITER
        # is the second and is tagged linux_x86_64 deliberately.
        out["kind"] = "pure" if tag.endswith("any") else "no-cpu-code"
        out["best"] = True
        return out

    if found is not None:
        out["needs_glibc"] = f"{found[0][0]}.{found[0][1]}"
        out["needs_glibc_from"] = found[1]

    if pol is None or found is None:
        out["kind"] = "manylinux" if tag.startswith("manylinux") else "constrained"
        return out

    eligible = found[0] <= pol[0]
    out["kind"] = "manylinux" if tag.startswith("manylinux") else "constrained"
    # "best" compares what the tag claims against what the symbols
    # allow. A manylinux tag is taken at its word -- auditwheel granted
    # it, having also weighed external libraries, which this does not.
    # The case worth catching is the other one: linux_x86_64 on a wheel
    # whose symbols would have permitted better.
    out["best"] = True if tag.startswith("manylinux") else not eligible
    return out


def check_report(whl: Path) -> int:
    import json

    print(json.dumps(measure(whl), indent=2, sort_keys=True))
    return 0


def check_no_manylinux(whl: Path) -> int:
    (pol_ver, pol_name) = newest_policy()
    host = host_glibc()
    print(f"wheel:           {whl.name}")
    print(f"newest policy:   {pol_name} (glibc {pol_ver[0]}.{pol_ver[1]})")
    print(f"host glibc:      {'.'.join(map(str, host)) if host else 'unknown'}")

    with zipfile.ZipFile(whl) as zf:
        members = elf_members(zf)
        if not members:
            die(
                f"{whl.name} contains no x86_64 ELF, so 'the symbols constrain "
                "the tag' is the wrong verdict for it entirely -- see "
                "no-cpu-code mode and the comment this check belongs to"
            )
        found = max_glibc_ref(zf, members)

    print(f"elf members:     {len(members)}")

    if found is None:
        # No versioned glibc reference at all. Fall back to the host
        # glibc, which is a true upper bound on anything the wheel could
        # reference: if even that is covered by a policy, the wheel is
        # eligible and the verdict is stale.
        if host is None:
            die("no GLIBC_x.y reference found and the host glibc is unknown")
        print("glibc refs:      none found; falling back to the host glibc")
        needed, where = host, "(host glibc, no reference found in the wheel)"
    else:
        needed, where = found[0], found[1]
        print(f"needs glibc:     {needed[0]}.{needed[1]}  (from {where})")

    if needed > pol_ver:
        print(
            f"verdict ok: glibc {needed[0]}.{needed[1]} is newer than "
            f"{pol_name}; linux_x86_64 is the only honest tag"
        )
        return 0

    die(
        f"THE FROZEN VERDICT IS STALE.\n"
        f"  {whl.name} needs at most glibc {needed[0]}.{needed[1]} ({where}),\n"
        f"  and auditwheel now has {pol_name} for glibc "
        f"{pol_ver[0]}.{pol_ver[1]}.\n"
        f"  This wheel is manylinux-eligible and is shipping as "
        f"linux_x86_64.\n"
        f"  Add an `auditwheel-rocm` step to this Dockerfile the way\n"
        f"  Dockerfile.cupy and Dockerfile.atom do, then delete this "
        f"check\n"
        f"  and the comment above it."
    )
    return 1  # unreachable; die() raises


def check_no_cpu_code(whl: Path) -> int:
    print(f"wheel:           {whl.name}")
    with zipfile.ZipFile(whl) as zf:
        members = elf_members(zf)

    if not members:
        print(
            "verdict ok: no x86_64 ELF in the wheel, so no platform tag "
            "can describe it; linux_x86_64 stays"
        )
        return 0

    listed = "\n".join(f"    {m.filename}" for m in members[:20])
    more = f"\n    ... and {len(members) - 20} more" if len(members) > 20 else ""
    die(
        f"THE FROZEN VERDICT IS STALE.\n"
        f"  {whl.name} now contains {len(members)} x86_64 ELF file(s):\n"
        f"{listed}{more}\n"
        f"  A platform tag has something to describe again, so the "
        f"'no CPU\n"
        f"  code' reason for skipping auditwheel no longer holds. Add an\n"
        f"  `auditwheel-rocm` step, or re-measure and rewrite the comment\n"
        f"  above this check."
    )
    return 1  # unreachable; die() raises


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    mode = argv[2]
    whl = sole_wheel(argv[1])
    if mode == "no-manylinux":
        return check_no_manylinux(whl)
    if mode == "no-cpu-code":
        return check_no_cpu_code(whl)
    if mode == "report":
        return check_report(whl)
    die(f"unknown mode {mode!r}; expected no-manylinux, no-cpu-code or report")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
