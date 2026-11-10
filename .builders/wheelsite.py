#!/usr/bin/env python3
"""Write the landing page that lists every published architecture.

WHY THIS EXISTS. data/wheels/<arch>/ is a PEP 503 index, which pip
reads happily and a person cannot discover. Before this, data/wheels/
itself was a 404: the only way to reach an index was to already know
the architecture name and type it. data/perf/ has had a landing page
since it was first published; this is the same idea for the wheels.

The page is generated from what is actually on disk rather than from a
list of architectures kept somewhere. An arch that was never published,
or one that has been removed, cannot then linger in the index as a dead
link — the directory is the source of truth.

Usage:  wheelsite.py <wheels-root> [--repo owner/name]
"""
from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path

# Matches the generated metapackage so the page can name the exact
# version a reader would get. Its local segment is <arch>.<pin-digest>,
# which changes whenever the pinned set does.
META_RE = re.compile(r"rocm_torch-(?P<version>[^-]+)-py3-none-any\.whl")

# Only the projects worth naming on a landing page. The index itself
# lists everything; repeating 12 rows per arch here would bury the one
# thing a reader wants, which is the install command.
HIGHLIGHT = ("torch", "triton", "vllm")


def arch_dirs(root: Path):
    """Published architectures, newest-looking name order aside.

    A directory counts as published only if it has the index.html a
    PEP 503 root must have. A half-copied tree is not offered.
    """
    out = []
    for d in sorted(root.iterdir()):
        if d.is_dir() and (d / "index.html").is_file():
            out.append(d)
    return out


def verdicts(arch_dir: Path) -> list[dict]:
    """The measured platform tags wheelindex.py published for this arch.

    Absent for an arch published before this existed, which is a reason
    to say nothing about it rather than to guess. The landing page
    degrades to the prose it had before.
    """
    page = arch_dir / "verdicts.json"
    if not page.is_file():
        return []
    try:
        return json.loads(page.read_text(encoding="utf-8"))["wheels"]
    except (ValueError, KeyError):
        return []


def tag_summary(arch_dir: Path) -> str:
    """"5 manylinux · 4 linux_x86_64 · 3 pure", or an em dash."""
    found = verdicts(arch_dir)
    if not found:
        return "—"
    counts = {}
    for v in found:
        kind = {"pure": "pure", "no-cpu-code": "linux_x86_64",
                "constrained": "linux_x86_64",
                "manylinux": "manylinux"}.get(v.get("kind"), "other")
        counts[kind] = counts.get(kind, 0) + 1
    order = ("manylinux", "linux_x86_64", "pure", "other")
    return " · ".join(f"{counts[k]} {k}" for k in order if k in counts)


def narrow_wheels(root: Path) -> list[tuple[str, dict]]:
    """Every published wheel tagged more narrowly than its symbols need.

    Surfaced on the landing page rather than only in a build log: this
    is the one state in the table a reader can act on, because it means
    pip will refuse the wheel on a host that could have run it.
    """
    out = []
    for d in arch_dirs(root):
        for v in verdicts(d):
            if v.get("best") is False:
                out.append((d.name, v))
    return out


def project_version(arch_dir: Path, project: str) -> str | None:
    """The version of one project, read from its generated page."""
    page = arch_dir / project / "index.html"
    if not page.is_file():
        return None
    text = page.read_text(encoding="utf-8", errors="replace")
    # The href carries the filename; the version is its second field.
    m = re.search(rf"{re.escape(project)}-([^-\"#]+)-", text)
    return m.group(1) if m else None


def metapackage_version(arch_dir: Path) -> str | None:
    page = arch_dir / "rocm-torch" / "index.html"
    if not page.is_file():
        return None
    m = META_RE.search(page.read_text(encoding="utf-8", errors="replace"))
    return m.group("version") if m else None


def render(root: Path, repo: str) -> str:
    site = f"https://{repo.split('/')[0]}.github.io/{repo.split('/')[1]}"
    archs = arch_dirs(root)

    rows = []
    for d in archs:
        meta = metapackage_version(d) or "—"
        cells = "".join(
            f"<td><code>{html.escape(project_version(d, p) or '—')}</code></td>"
            for p in HIGHLIGHT
        )
        rows.append(
            f'<tr><td><a href="{html.escape(d.name)}/">'
            f"<code>{html.escape(d.name)}</code></a></td>"
            f"{cells}<td><code>{html.escape(meta)}</code></td>"
            f"<td>{html.escape(tag_summary(d))}</td></tr>"
        )

    head = "".join(f"<th><code>{p}</code></th>" for p in HIGHLIGHT)
    first = archs[0].name if archs else "gfx950"

    # The note this replaces said the same thing from memory, and said
    # it about whichever wheels were published the day it was written.
    # Each arch index now carries the measurement, so this links to it
    # and names anything a reader could act on.
    narrow = narrow_wheels(root)
    tagnote = (
        '<p class="note">Platform tags differ by wheel and are not a '
        "choice: <code>auditwheel</code> grants a <code>manylinux</code> "
        "tag only where the compiled code's glibc symbols allow one. "
        "Some wheels here reference symbols newer than any defined "
        "policy and stay <code>linux_x86_64</code>; some contain no CPU "
        "code at all. Each architecture's index lists the measured tag "
        "and the glibc behind it, under "
        '<em>Platform tags</em>.</p>'
    )
    if narrow:
        items = "".join(
            f"<li><code>{html.escape(a)}</code> · "
            f"<code>{html.escape(v['project'])}</code> is tagged "
            f"<code>{html.escape(v['tag'])}</code> but needs only glibc "
            f"{html.escape(v['needs_glibc'] or '?')}</li>"
            for a, v in narrow
        )
        tagnote += (
            '<p class="note"><strong>Tagged more narrowly than '
            "required.</strong> pip will refuse these on hosts that "
            f"could run them:</p><ul class=\"note\">{items}</ul>"
        )

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ROCm wheels — {html.escape(repo)}</title>
<style>
 body {{ font-family: system-ui, sans-serif; max-width: 54rem;
        margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }}
 table {{ border-collapse: collapse; margin: 1rem 0; width: 100%; }}
 th, td {{ text-align: left; padding: .35rem .6rem;
          border-bottom: 1px solid #ddd; }}
 pre {{ background: #f6f8fa; padding: .8rem; overflow-x: auto;
       border-radius: 6px; }}
 code {{ font-size: .92em; }}
 .note {{ color: #555; font-size: .92em; }}
</style>
</head>
<body>
<h1>ROCm PyTorch wheels</h1>

<p>One PEP 503 index per GPU architecture. The wheels themselves are
GitHub release assets; these pages point at them, with a
<code>#sha256=</code> on every link so pip verifies what it downloads.</p>

<pre>pip install \\
  --index-url {site}/data/wheels/{html.escape(first)}/ \\
  --extra-index-url https://pypi.org/simple \\
  "rocm-torch[device-{html.escape(first)}]"</pre>

<table>
<thead><tr><th>architecture</th>{head}<th><code>rocm-torch</code></th>
<th>platform tags</th></tr></thead>
<tbody>
{chr(10).join(rows) if rows else '<tr><td colspan="6">none published</td></tr>'}
</tbody>
</table>

<h2>Reading the versions</h2>

<p>A version says which ROCm a wheel was built against. Nothing in a
filename says which <em>GPU</em>: <code>torch</code> for two
architectures is the same filename and differs by tens of MB of device
code. That is what the per-arch index path and the
<code>rocm-torch</code> metapackage carry, and why installing through
the index is the only correct way to get these.</p>

<p class="note">The extra index is not optional — ordinary
dependencies resolve from PyPI. Our wheels win over same-named PyPI
projects because the metapackage pins exact versions whose local
segment (<code>+rocm…</code>) upstream cannot match.</p>

{tagnote}

<p><a href="../perf/">Build performance</a> ·
<a href="https://github.com/{html.escape(repo)}">Source</a></p>
</body>
</html>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("root", help="the data/wheels directory")
    ap.add_argument("--repo", default="sbates130272/rocm-bake")
    args = ap.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 1

    out = root / "index.html"
    out.write_text(render(root, args.repo), encoding="utf-8")
    names = [d.name for d in arch_dirs(root)]
    print(f"wheelsite: {out} ({len(names)} arch: {', '.join(names) or 'none'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
