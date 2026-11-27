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
import importlib.util
import io
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path


def _load_wheel_verdict():
    """Import docker/wheel-verdict.py, which is not an importable name.

    It lives in docker/ because the Dockerfiles COPY it into the images
    as a standalone file, and it is hyphenated because it is installed
    as a command there. Neither makes it a package, and wheelpublish.sh
    runs this script with `python3 -I`, so sys.path holds .builders and
    nothing else. A spec loaded from an explicit path is the honest way
    to share the measurement rather than keeping a second copy of the
    ELF scan here -- a second copy being exactly how the two halves
    would come to disagree about what a wheel needs.
    """
    path = Path(__file__).resolve().parent.parent / "docker" / "wheel-verdict.py"
    spec = importlib.util.spec_from_file_location("wheel_verdict", path)
    if spec is None or spec.loader is None:
        sys.exit(f"error: cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


wheel_verdict = _load_wheel_verdict()

# PEP 427: {name}-{version}(-{build})?-{python}-{abi}-{platform}.whl
WHEEL_RE = re.compile(
    r"^(?P<name>[^-]+)-(?P<version>[^-]+)"
    r"(?:-(?P<build>\d[^-]*))?"
    r"-(?P<python>[^-]+)-(?P<abi>[^-]+)-(?P<platform>[^-]+)\.whl$"
)

METAPACKAGE = "rocm-torch"

# Wheels the index publishes but the metapackage's device-<arch> extra
# does NOT pull in.
#
# atom registers a vLLM V1 platform plugin through an entry point, so
# merely being installed changes how vLLM starts. At this repo's pins
# it does not merely change it, it stops it: vLLM 0.34.0 against ATOM
# v0.1.10 dies during platform detection with
#
#   atom/plugin/vllm/register.py:206
#   ImportError: cannot import name 'register_quantization_config'
#     ... (most likely due to a circular import)
#
# measured 2026-11-27 by installing rocm-torch[device-gfx1201] from the
# published index on snoc-thinkstation. docs/architecture/atom-vllm-skew.md
# has the version arithmetic and already warned that "pip installs any
# pairing happily"; this is what stops it doing so.
#
# No image in this repo ships that pairing either: the vllm image does
# not install atom at all, and atom-vllm sets ATOM_DISABLE_VLLM_PLUGIN=1
# so the plugin is off unless someone opts in. A wheel cannot set an
# environment variable, so keeping atom out of the extra is the only
# equivalent. The wheel is still in the index and still installable by
# name for anyone who wants it.
EXCLUDED_FROM_EXTRA = {"atom"}

# amdsmi is how vLLM identifies the device on ROCm, and without it
# `vllm serve` fails with "Failed to infer device type" -- measured,
# not inferred: an install from the published index could not start at
# all until this was in place.
#
# It cannot be a Requires-Dist. ROCm ships the bindings inside the
# install tree at /opt/rocm/share/amd_smi with no setup.py or
# pyproject.toml, so there is nothing for pip to install; the
# directory just has to be on sys.path. Dockerfile.vllm writes exactly
# this .pth for the image, and a wheel install had no equivalent.
#
# Harmless when wrong: Python silently ignores a .pth line naming a
# directory that does not exist, so a consumer whose ROCm lives
# elsewhere is no worse off than before.
AMDSMI_DIR = "/opt/rocm/share/amd_smi"
AMDSMI_PTH = "rocm-amdsmi.pth"


def normalize(name):
    """PEP 503 normalised project name."""
    return re.sub(r"[-_.]+", "-", name).lower()


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def core_metadata(whl):
    """The wheel's METADATA file, as bytes, or None if it has none.

    The same bytes PEP 658 serves at <wheel-url>.metadata. An installer
    that finds them resolves a wheel's dependencies from a few KB
    rather than by downloading the wheel, which for torch and triton is
    most of a gigabyte spent to read forty lines.
    """
    with zipfile.ZipFile(whl) as z:
        meta = [n for n in z.namelist()
                if n.count("/") == 1 and n.endswith(".dist-info/METADATA")]
        return z.read(meta[0]) if meta else None


def requires_python(whl):
    """The wheel's Requires-Python, or None if it declares none."""
    raw = core_metadata(whl)
    if raw is None:
        return None
    for line in raw.decode(errors="replace").splitlines():
        if line.startswith("Requires-Python:"):
            return line.split(":", 1)[1].strip()
        if not line.strip():
            break
    return None


def capped_below(spec, python):
    """True if spec's upper bound excludes `python` (e.g. "<3.14" vs 3.14).

    Only the "<" and "<=" clauses, which is the case that actually
    bites. This repo is cp314 throughout, because Ubuntu 26.04 — the
    only base AMD publishes ROCm 10.1 for — ships no other Python, so
    any upstream capping below 3.14 is uninstallable from our index.
    Naming it here is what keeps that from surfacing as an opaque pip
    resolution failure a long way from the cause.

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


def metapackage_wheel(arch, version, pins, out_dir, python):
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
        # From --python, not a constant. Hardcoding ">=3.14" here meant
        # the metapackage disagreed with the interpreter it was
        # generated for the moment anything ran on another one, and it
        # fails as an opaque "requires a different Python" a long way
        # from this line.
        f"Requires-Python: >={python}",
        f"Provides-Extra: {extra}",
    ]
    for name, ver in pins:
        if name == METAPACKAGE:
            continue
        if name in EXCLUDED_FROM_EXTRA:
            continue
        metadata.append(f'Requires-Dist: {name}=={ver}; extra == "{extra}"')
    metadata += [
        "",
        f"Pins the {arch} index's wheels at the exact versions built",
        "against this ROCm and this torch. Install the set with:",
        "",
        f"    pip install --index-url <index>/{arch}/ "
        f'"{METAPACKAGE}[{extra}]"',
        "",
        "The extra is named for the arch so that pointing at the wrong",
        "index fails rather than installing mismatched binaries.",
        "",
        "Not every wheel in the index is pinned here. "
        + (", ".join(sorted(EXCLUDED_FROM_EXTRA)) or "none")
        + " is published but left out, because installing it",
        "alongside vLLM changes how vLLM starts. Install it by name if",
        "you want it.",
        "",
    ]
    files = {
        AMDSMI_PTH: f"{AMDSMI_DIR}\n",
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
    # Clear any previously generated metapackage first. This directory is
    # generated output, so anything already in it is from an older run --
    # and since the version now carries a digest of the pin set, a rebuild
    # writes a NEW filename rather than overwriting the old one. They
    # accumulate, and wheelpublish.sh globs this directory to decide what
    # to upload: a dry run after three local rebuilds offered to publish
    # four metapackages, three of which no index references. They also
    # defeat the release-asset prune, which spares anything in the
    # upload set.
    for stale in out.parent.glob("*.whl"):
        if stale != out:
            stale.unlink()
    # A fixed timestamp, so the same pins give the same bytes. writestr
    # with a bare name stamps the wall clock into every member, which
    # made each regeneration a different file under an identical name:
    # resuming a publish that died after its upload would then write an
    # index whose sha256 does not match the asset already public.
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, body in files.items():
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, body)
    return out


# PEP 629. Declares which revision of the simple API these pages speak,
# so an installer can tell a page it understands from one it does not.
REPOSITORY_VERSION = '<meta name="pypi:repository-version" content="1.0">'


def file_entry(url, filename, sha256=None, requires_python=None,
               metadata_sha256=None):
    """One file on a project page, as write_project wants it."""
    return dict(url=url, filename=filename, sha256=sha256,
                requires_python=requires_python,
                metadata_sha256=metadata_sha256)


def write_project(index_root, project, entries):
    """One PEP 503 project page: <a> per file, hash in the fragment.

    data-requires-python (PEP 503) lets an installer skip a file its
    interpreter cannot use instead of downloading it to find out.
    data-core-metadata (PEP 658, renamed by PEP 714) says the wheel's
    METADATA is also served at <url>.metadata, with that hash; the
    older data-dist-info-metadata spelling is emitted beside it because
    pip before 23.2 reads only that one. Both are left off a file whose
    sidecar was never published -- claiming one that 404s fails the
    install, where saying nothing merely costs a download.
    """
    page = Path(index_root) / project
    page.mkdir(parents=True, exist_ok=True)
    lines = ["<!DOCTYPE html><html><head>", REPOSITORY_VERSION,
             "</head><body>",
             f"<h1>Links for {html.escape(project)}</h1>"]
    for e in entries:
        href = e["url"]
        if e.get("sha256"):
            href += f"#sha256={e['sha256']}"
        attrs = ""
        if e.get("requires_python"):
            attrs += (' data-requires-python="'
                      f'{html.escape(e["requires_python"])}"')
        if e.get("metadata_sha256"):
            digest = f'sha256={e["metadata_sha256"]}'
            attrs += (f' data-core-metadata="{digest}"'
                      f' data-dist-info-metadata="{digest}"')
        lines.append(f'<a href="{html.escape(href)}"{attrs}>'
                     f'{html.escape(e["filename"])}</a><br/>')
    lines.append("</body></html>")
    (page / "index.html").write_text("\n".join(lines) + "\n")


def verdict_why(v):
    """One line saying why this wheel carries the tag it carries."""
    pol = v.get("newest_policy")
    if v["kind"] == "pure":
        return "no compiled code at all"
    if v["kind"] == "no-cpu-code":
        return ("GPU code objects only — no x86-64 code for a platform "
                "tag to describe")
    if v["kind"] == "manylinux":
        return f"granted by auditwheel; symbols need glibc {v['needs_glibc']}"
    if v.get("best") is False:
        return (f"ELIGIBLE for {pol} — symbols need only glibc "
                f"{v['needs_glibc']}, so this tag is narrower than it "
                "needs to be")
    if pol:
        return (f"symbols need glibc {v['needs_glibc']}, newer than "
                f"{pol}, the newest policy auditwheel knows")
    return f"symbols need glibc {v['needs_glibc']}"


def render_verdicts(verdicts):
    """The platform-tag table appended to the per-arch index page.

    Appended to the PEP 503 root, which is safe because pip never
    fetches it: with --index-url URL, pip requests URL/<project>/ and
    nothing else. The root has always been a human landing page that
    happens to live at an index URL. No <a> is emitted here all the
    same, so the page cannot start advertising a distribution by
    accident if that ever changes.
    """
    rows = []
    for v in sorted(verdicts, key=lambda x: x["project"]):
        flag = ' style="background:#fff4f4"' if v.get("best") is False else ""
        rows.append(
            f"<tr{flag}><td><code>{html.escape(v['project'])}</code></td>"
            f"<td><code>{html.escape(v['tag'])}</code></td>"
            f"<td><code>{html.escape(v['needs_glibc'] or '—')}</code></td>"
            f"<td>{html.escape(verdict_why(v))}</td></tr>"
        )
    return (
        "<h2>Platform tags</h2>"
        "<p>Measured from each wheel's own ELF symbols at publish time, "
        "not asserted. A <code>manylinux</code> tag is granted only "
        "where the compiled code's glibc requirement allows one; a "
        "wheel needing a glibc newer than every defined policy stays "
        "<code>linux_x86_64</code>, which is a statement about this "
        "build, not a defect.</p>"
        "<table>"
        "<tr><th>project</th><th>tag</th><th>needs glibc</th>"
        "<th>why</th></tr>" + "".join(rows) + "</table>"
    )


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
    ap.add_argument("--build", default=None,
                    help="build number for a published set, YYYYMMDD or "
                         "YYYYMMDD.N; becomes the fourth component of "
                         "the metapackage version")
    ap.add_argument("--release-dir", default=None,
                    help="write the extra release assets here: one "
                         "<wheel>.metadata per wheel (PEP 658) and the "
                         "build's manifest.json")
    args = ap.parse_args()
    if args.build and not re.fullmatch(r"\d{8}(\.\d+)?", args.build):
        sys.exit(f"error: --build {args.build!r} is not YYYYMMDD[.N]")

    recorded = check_arch(args.wheel_dir, args.arch)

    found = scan(args.wheel_dir)

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

    # The sidecars and the manifest are release assets, not index
    # pages: their names carry the wheel's "+", which GitHub Pages
    # cannot serve (see the metapackage note below). Emptied first, so
    # what is uploaded is this run's set and not an accumulation.
    release = Path(args.release_dir) if args.release_dir else None
    if release:
        release.mkdir(parents=True, exist_ok=True)
        for old in release.iterdir():
            if old.is_file():
                old.unlink()

    def sidecar(path):
        """Write <wheel>.metadata for release; return its sha256."""
        raw = core_metadata(path)
        if release is None or raw is None:
            return None
        (release / f"{path.name}.metadata").write_bytes(raw)
        return hashlib.sha256(raw).hexdigest()

    projects = {}
    pins = []
    capped = []
    verdicts = []
    manifest_files = []

    def add(project, version, path, url):
        spec = requires_python(path)
        entry = file_entry(url, path.name, sha256_of(path), spec,
                           sidecar(path))
        projects.setdefault(project, []).append(entry)
        manifest_files.append(dict(
            project=project, version=version, filename=path.name,
            sha256=entry["sha256"], size=path.stat().st_size,
            requires_python=spec,
            metadata_sha256=entry["metadata_sha256"]))
        return spec

    for project, version, path in found:
        spec = add(project, version, path, f"{prefix}{path.name}")
        pins.append((project, version))
        if capped_below(spec, args.python):
            capped.append((project, spec))
        # Measured here rather than taken from the Dockerfiles, because
        # only four of them say anything about their tag and twelve
        # wheels get published. See docker/wheel-verdict.py.
        v = wheel_verdict.measure(path)
        v["project"] = project
        verdicts.append(v)

    # The metapackage version carries the arch as a PEP 440 local
    # segment, so two indexes hold genuinely different versions of
    # rocm-torch rather than the same one with different contents.
    #
    # The arch alone is not enough, and the pin digest is why. Both
    # other inputs -- the ROCm version and the arch -- are stable across
    # rebuilds, while the pins inside the metapackage are not: a torch
    # rebuilt at a new commit, or every wheel renamed at once, rewrites
    # every Requires-Dist while leaving the filename, the version and
    # the download URL byte-identical. A client with a warm pip cache is
    # then entitled to reuse the body it already has, and resolve pins
    # that are no longer anywhere in the index -- surfacing as a hash
    # mismatch or an unsatisfiable requirement, neither of which names
    # the cause.
    #
    # So the pin set is part of the version. Any change to what this
    # metapackage requires produces a new version, which is the property
    # a cache is allowed to rely on.
    pin_digest = hashlib.sha256(
        "\n".join(f"{n}=={v}" for n, v in sorted(pins)).encode()
    ).hexdigest()[:8]
    # The arch goes in the local version segment, and a wheel filename
    # is split on "-" into name-version-python-abi-platform. An arch
    # carrying a hyphen therefore produces a filename with one field
    # too many, which pip cannot parse -- it drops the file without
    # comment and reports "from versions: none" for an index that
    # looks perfectly correct in a browser. No gfx name has a hyphen,
    # so this only bites the emulator indexes (emu-gfx1151); PEP 440
    # normalises "-", "_" and "." in a local segment to "." anyway, so
    # writing the "." directly changes no version that already exists.
    arch_in_version = args.arch.replace("-", ".").replace("_", ".")
    # The build number, when this is a published set. The digest says
    # WHETHER two metapackages differ and nothing about which is newer:
    # a local segment orders lexically, so with every build kept in the
    # index "the latest rocm-torch" would be whichever digest happened
    # to sort last. A date in the public version is what makes an
    # unpinned install take the newest build, and
    # `rocm-torch==10.2.0.20261127` name one exactly.
    #
    # Absent for a local `make wheel-index`, which has one build and
    # nothing to order it against.
    public = args.version.split("-")[0]
    if args.build:
        public += f".{args.build}"
    meta_version = f"{public}+{arch_in_version}.{pin_digest}"

    meta_whl = metapackage_wheel(args.arch, meta_version, pins,
                                out / METAPACKAGE, args.python)
    # The metapackage href follows --wheel-url when one is given, which
    # means the generated wheel has to be published alongside the rest
    # rather than served from the index directory. wheelpublish.sh does
    # that; see the note there.
    #
    # Not a tidiness choice. Its filename carries a PEP 440 local
    # segment -- rocm_torch-10.1.0+gfx950.13b9737a-py3-none-any.whl --
    # GitHub Pages fails the whole site build on a file whose name
    # contains "+", with no error beyond "Page build failed". Measured
    # 2026-11-05: the first published index errored the build, and
    # removing only that file made the next one succeed. Every other
    # file in the index is .html.
    #
    # Without --wheel-url the href stays relative, which is what the
    # local `make wheel-index` + http.server path wants.
    meta_href = (f"{prefix}{meta_whl.name}" if args.wheel_url
                 else meta_whl.name)
    add(METAPACKAGE, meta_version, meta_whl, meta_href)
    # Measured like the rest, not assumed pure. It is generated three
    # lines above and is obviously py3-none-any today, but a table that
    # silently omits one of the twelve projects invites the reader to
    # wonder which others it omits.
    meta_v = wheel_verdict.measure(meta_whl)
    meta_v["project"] = METAPACKAGE
    verdicts.append(meta_v)

    # Drop project directories left by an earlier run. Regenerating an
    # index over a smaller wheel set rewrote index.html but left the
    # vanished projects' pages on disk, still serving their wheels to
    # anyone who requested them by name -- which is exactly how an
    # emulator index would go on offering a second profile pack after
    # `make emu-index` dropped it.
    for stale in sorted(p for p in Path(out).iterdir()
                        if p.is_dir() and p.name not in projects):
        print(f"  removing stale project {stale.name}/")
        shutil.rmtree(stale)

    for project, entries in projects.items():
        write_project(out, project, entries)

    root = ["<!DOCTYPE html><html><head>", REPOSITORY_VERSION,
            "</head><body>", f"<h1>{html.escape(args.arch)}</h1>"]
    for project in sorted(projects):
        root.append(f'<a href="{project}/">{html.escape(project)}</a><br/>')
    root.append(render_verdicts(verdicts))
    root.append("</body></html>")
    (out / "index.html").write_text("\n".join(root) + "\n")

    # The same facts as data, so the weekly probe can check the live
    # site without downloading a 400MB wheel to re-derive them, and so
    # the landing page can summarise every arch without parsing HTML.
    (out / "verdicts.json").write_text(
        json.dumps({"arch": args.arch, "rocm": args.version,
                    "wheels": sorted(verdicts, key=lambda v: v["project"])},
                   indent=1, sort_keys=True) + "\n")

    # Everything a published index page is made from, in one file.
    # wheelsite.py builds the public tree out of these and nothing
    # else, one per build, so an index listing every build ever
    # published can be regenerated without a single wheel on disk --
    # and, because a copy rides along as a release asset, without
    # gh-pages either. That matters: docs.yml replaces that branch with
    # an orphan commit on every deploy, so its history is not a backup.
    if release:
        (release / "manifest.json").write_text(json.dumps(dict(
            schema=1, arch=args.arch, rocm=args.version,
            build=args.build, python=args.python,
            metapackage=meta_version,
            base_url=prefix if args.wheel_url else None,
            files=sorted(manifest_files, key=lambda f: f["filename"]),
            verdicts=sorted(verdicts, key=lambda v: v["project"]),
        ), indent=1, sort_keys=True) + "\n")

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
        print("    Check whether the cap is a support statement or a"
              "\n    real ABI bound before reaching for that flag — the"
              "\n    extensions here are built against this interpreter,"
              "\n    but that is an argument to make per wheel.")

    # A note rather than a failure. Shipping a narrower tag than the
    # symbols require installs correctly everywhere it would have
    # installed before — it is a missed opportunity, not a broken
    # wheel, and refusing to publish an arch over one would be a worse
    # trade. The hard gates are upstream, in the Dockerfiles that
    # assert their own verdict, and downstream in wheels-probe.yml.
    narrow = [v for v in verdicts if v.get("best") is False]
    if narrow:
        print("\n  note: a wheel is tagged more narrowly than its symbols"
              "\n  require, so pip will refuse it on hosts that could run it:")
        for v in narrow:
            print(f"    {v['project']:<14} {v['tag']} but needs only glibc "
                  f"{v['needs_glibc']} ({v['newest_policy']} exists)")
        print("    Add an auditwheel-rocm step to that wheel's Dockerfile;"
              "\n    docker/auditwheel-rocm.sh carries the exclude rules.")
    if any(v.get("best") is None for v in verdicts):
        print("\n  note: auditwheel is not installed here, so the tags above"
              "\n  are described but not judged. `pip install auditwheel`"
              "\n  to have this say whether each one is the best available.")


if __name__ == "__main__":
    main()
