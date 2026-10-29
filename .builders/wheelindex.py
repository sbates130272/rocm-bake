#!/usr/bin/env python3
"""Turn a per-arch directory of wheels into an installable pip index.

Every wheel this repo builds has an arch-independent filename. torch is
`torch-2.14.1a0+git5c48869-cp314-cp314-linux_x86_64.whl` whether it was
compiled for gfx950 or gfx1201, and so is amd_aiter-0.1.27 — which is
131 MB for one arch and 481 MB for the other. Dropped into one
directory they overwrite each other and `pip --find-links` serves
whichever landed last, with nothing in the name to say which that was.
The image tags have always carried the arch; the wheels inside never
have.

So the arch has to live in the path, not the filename: one PEP 503
index per arch, selected by index URL. That is the same shape as
download.pytorch.org/whl/rocm6.4 and it needs no plugin, no draft PEP
and no forked installer:

    pip install --index-url http://host:8081/index/gfx950/ torch

On top of that each index carries a generated `rocm-torch`
metapackage whose only job is to offer a `device-<arch>` extra, which
pins every wheel in that index at once:

    pip install --index-url http://host:8081/index/gfx950/ \
        "rocm-torch[device-gfx950]"

That mirrors how TheRock ships ROCm — `pip install "rocm[device-gfx1153]"`
— rather than the WheelNext variant mechanism. Variants (PEP 817/825)
are the better long-term answer and AMD ships an `amd-variant-provider`
plugin for them, but both PEPs are Draft, the installer support is
prototype-only forks of pip and uv, and the published provider matches
PyTorch 2.9 on ROCm 6.3/6.4 against a gfx list that does not include
gfx950. None of that resolves this stack today. The extra is spelled
`device-<arch>` deliberately: when variants do land, the arch is
already a first-class coordinate here and only the selection mechanism
has to change.

Naming the extra after the arch also catches the one mistake this
layout invites. Each index only declares its own arch's extra, so
asking gfx950's index for `[device-gfx1201]` fails loudly instead of
installing the wrong binaries.
"""
import argparse
import base64
import csv
import hashlib
import html
import io
import re
import sys
import zipfile
from pathlib import Path

# PEP 427: {name}-{version}(-{build})?-{python}-{abi}-{platform}.whl
WHEEL_RE = re.compile(
    r"^(?P<name>[^-]+)-(?P<version>[^-]+)"
    r"(?:-(?P<build>\d[^-]*))?"
    r"-(?P<python>[^-]+)-(?P<abi>[^-]+)-(?P<platform>[^-]+)\.whl$"
)

METAPACKAGE = "rocm-torch"


def normalize(name):
    """PEP 503 normalised project name."""
    return re.sub(r"[-_.]+", "-", name).lower()


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def requires_python(whl):
    """The wheel's Requires-Python, or None if it declares none."""
    with zipfile.ZipFile(whl) as z:
        meta = [n for n in z.namelist() if n.endswith(".dist-info/METADATA")]
        if not meta:
            return None
        for line in z.read(meta[0]).decode(errors="replace").splitlines():
            if line.startswith("Requires-Python:"):
                return line.split(":", 1)[1].strip()
            if not line.strip():
                break
    return None


def capped_below(spec, python):
    """True if spec's upper bound excludes `python` (e.g. "<3.14" vs 3.14).

    Only the "<" and "<=" clauses, which is the case that actually
    bites: LMCache v0.5.6 declares ">=3.10,<3.14" while this repo is
    cp314 throughout, because Ubuntu 26.04 — the only base AMD
    publishes ROCm 10.1 for — ships no other Python. Both Dockerfiles
    already install it with --ignore-requires-python and say why; this
    is the same fact reaching the index, where it would otherwise
    surface as an opaque pip resolution failure a long way from the
    cause.

    A deliberately partial reading of PEP 440, not a specifier engine:
    a wrong answer here only mislabels a warning.
    """
    if not spec:
        return False
    want = tuple(int(p) for p in python.split(".")[:2])
    for clause in spec.split(","):
        clause = clause.strip()
        m = re.match(r"^(<=?)\s*(\d+)\.(\d+)", clause)
        if not m:
            continue
        bound = (int(m.group(2)), int(m.group(3)))
        if m.group(1) == "<" and want >= bound:
            return True
        if m.group(1) == "<=" and want > bound:
            return True
    return False


def scan(wheel_dir):
    """Every wheel in a directory as (project, version, path).

    A filename that does not parse is a hard error rather than a skip:
    the whole point of this script is that the index is complete, and a
    silently dropped wheel reappears as an unresolvable dependency at
    install time, a long way from here.
    """
    found = []
    for path in sorted(Path(wheel_dir).glob("*.whl")):
        m = WHEEL_RE.match(path.name)
        if not m:
            sys.exit(f"error: cannot parse wheel filename: {path.name}")
        found.append((normalize(m.group("name")), m.group("version"), path))
    if not found:
        sys.exit(f"error: no wheels in {wheel_dir}")
    return found


def check_arch(wheel_dir, arch):
    """Cross-check against the arch the build itself recorded.

    The Dockerfiles write /wheels-arch.txt by reading the gfx bundles
    back out of the compiled objects, so it says what is actually in
    the binaries rather than what was requested. That is the one
    available check that the directory being indexed as gfx950 really
    is gfx950 — mislabelling it here would otherwise produce an index
    that installs cleanly and then fails on the GPU.

    Absent for the arch-independent wheels (triton), so missing is not
    an error; a present file that disagrees is.
    """
    marker = Path(wheel_dir).parent / "wheels-arch.txt"
    if not marker.exists():
        marker = Path(wheel_dir) / "wheels-arch.txt"
    if not marker.exists():
        return None
    archs = [ln.strip() for ln in marker.read_text().splitlines() if ln.strip()]
    if archs and arch not in archs:
        sys.exit(f"error: {marker} records {archs}, but indexing as {arch}")
    return archs


def metapackage_wheel(arch, version, pins, out_dir):
    """Build the rocm-torch metapackage: pure metadata, no modules.

    Hand-assembled rather than built with setuptools because that would
    put a build backend and a temp tree in the path of something that
    is three text files in a zip. The format is stable and small enough
    to be obvious.
    """
    extra = f"device-{arch}"
    dist = f"rocm_torch-{version}"
    dist_info = f"{dist}.dist-info"

    metadata = [
        "Metadata-Version: 2.1",
        f"Name: {METAPACKAGE}",
        f"Version: {version}",
        f"Summary: ROCm PyTorch stack for {arch}, built by rocm-pytorch-build",
        "Requires-Python: >=3.14",
        f"Provides-Extra: {extra}",
    ]
    for name, ver in pins:
        if name == METAPACKAGE:
            continue
        metadata.append(f'Requires-Dist: {name}=={ver}; extra == "{extra}"')
    metadata += [
        "",
        f"Pins every wheel in the {arch} index at the exact version built",
        "against this ROCm and this torch. Install the set with:",
        "",
        f"    pip install --index-url <index>/{arch}/ "
        f'"{METAPACKAGE}[{extra}]"',
        "",
        "The extra is named for the arch so that pointing at the wrong",
        "index fails rather than installing mismatched binaries.",
        "",
    ]
    files = {
        f"{dist_info}/METADATA": "\n".join(metadata),
        f"{dist_info}/WHEEL": (
            "Wheel-Version: 1.0\n"
            "Generator: wheelindex.py\n"
            "Root-Is-Purelib: true\n"
            "Tag: py3-none-any\n"
        ),
    }

    # RECORD lists every other file with its hash and size, then itself
    # with neither — pip checks this, so it cannot just be omitted.
    rows = []
    for name, body in files.items():
        raw = body.encode()
        digest = base64.urlsafe_b64encode(
            hashlib.sha256(raw).digest()).rstrip(b"=").decode()
        rows.append((name, f"sha256={digest}", str(len(raw))))
    rows.append((f"{dist_info}/RECORD", "", ""))
    buf = io.StringIO()
    csv.writer(buf, lineterminator="\n").writerows(rows)
    files[f"{dist_info}/RECORD"] = buf.getvalue()

    out = Path(out_dir) / f"{dist}-py3-none-any.whl"
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, body in files.items():
            z.writestr(name, body)
    return out


def write_project(index_root, project, entries):
    """One PEP 503 project page: <a> per file, hash in the fragment."""
    page = Path(index_root) / project
    page.mkdir(parents=True, exist_ok=True)
    lines = ["<!DOCTYPE html><html><body>",
             f"<h1>Links for {html.escape(project)}</h1>"]
    for href, text in entries:
        lines.append(f'<a href="{html.escape(href)}">{html.escape(text)}</a><br/>')
    lines.append("</body></html>")
    (page / "index.html").write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("wheel_dir", help="directory of .whl files for one arch")
    ap.add_argument("--arch", required=True, help="gfx target, e.g. gfx950")
    ap.add_argument("--out", required=True, help="index root to write")
    ap.add_argument("--version", required=True,
                    help="ROCm version the stack was built against")
    ap.add_argument("--python", default="3.14",
                    help="Python these wheels target, for the "
                         "Requires-Python report (default 3.14)")
    ap.add_argument("--wheel-url", default=None,
                    help="URL prefix the wheels are served under "
                         "(default: a relative path back to wheel_dir)")
    args = ap.parse_args()

    recorded = check_arch(args.wheel_dir, args.arch)

    found = scan(args.wheel_dir)
    # The metapackage version carries the arch as a PEP 440 local
    # segment. Two indexes then hold genuinely different versions of
    # rocm-torch rather than the same one with different contents,
    # which is what makes a stale pip cache harmless here.
    meta_version = f"{args.version.split('-')[0]}+{args.arch}"

    out = Path(args.out)
    prefix = args.wheel_url
    if prefix is None:
        # Relative: ../../ climbs out of <out>/<project>/ back to the
        # index root, then across to the wheels. Keeps the tree movable
        # — no host or port baked into the generated HTML.
        import os
        rel = os.path.relpath(Path(args.wheel_dir).resolve(), out.resolve())
        prefix = f"../{rel}"
    prefix = prefix.rstrip("/") + "/"

    projects = {}
    pins = []
    capped = []
    for project, version, path in found:
        projects.setdefault(project, []).append(
            (f"{prefix}{path.name}#sha256={sha256_of(path)}", path.name))
        pins.append((project, version))
        spec = requires_python(path)
        if capped_below(spec, args.python):
            capped.append((project, spec))

    meta_whl = metapackage_wheel(args.arch, meta_version, pins, out / METAPACKAGE)
    projects[METAPACKAGE] = [
        (f"{meta_whl.name}#sha256={sha256_of(meta_whl)}", meta_whl.name)]

    for project, entries in projects.items():
        write_project(out, project, entries)

    root = ["<!DOCTYPE html><html><body>", f"<h1>{html.escape(args.arch)}</h1>"]
    for project in sorted(projects):
        root.append(f'<a href="{project}/">{html.escape(project)}</a><br/>')
    root.append("</body></html>")
    (out / "index.html").write_text("\n".join(root) + "\n")

    print(f"index: {out}  arch={args.arch}  projects={len(projects)}")
    if recorded:
        print(f"  verified against wheels-arch.txt: {','.join(recorded)}")
    for project, version in sorted(pins):
        print(f"  {project:<16} {version}")
    print(f"  {METAPACKAGE:<16} {meta_version}  "
          f"(extra: device-{args.arch})")
    if capped:
        print(f"\n  note: installing into python {args.python} needs "
              f"--ignore-requires-python")
        for project, spec in capped:
            print(f"    {project:<14} declares Requires-Python: {spec}")
        print("    The cap is a support statement, not an ABI one — the"
              "\n    extension was built against this interpreter here."
              "\n    docker/Dockerfile.lmcache and .vllm already install"
              "\n    it the same way, for the same reason.")


if __name__ == "__main__":
    main()
