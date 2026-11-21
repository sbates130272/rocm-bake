#!/usr/bin/env python3
"""Build the public wheel indexes, and their landing page, from manifests.

WHAT THIS OWNS. Everything under data/wheels/ on gh-pages except
builds/, which is its input:

    builds/<tag>.json           one manifest per published build
    rocm<X.Y>/<arch>/           PEP 503 index: every build for that ROCm
    <arch>/                     the same index for the NEWEST ROCm
    index.json, index.html      what exists, for a probe and for a person

WHY IT IS GENERATED FROM MANIFESTS. A publish used to copy one build's
index over data/wheels/<arch>/, after an `rm -rf`. That made the index
a statement about the last publish only: ROCm 10.2 going out dropped
10.1 from it, though the 10.1 releases and every wheel in them were
still public. Keeping an older version installable means the index has
to list builds it was not just handed, so it is rebuilt each time from
a record of all of them. wheelindex.py writes that record, a
manifest.json per build, and wheelpublish.sh files it under builds/.

WHY THE VERSIONED PATH AND THE BARE ONE. rocm<X.Y>/<arch>/ is the
shape download.pytorch.org/whl/rocm6.4 uses, and is what someone
holding a host at an older ROCm points at. <arch>/ is the URL every
release note and document published so far names; it follows the
newest ROCm so none of them broke.

A FILENAME IS LISTED ONCE. Same name and same sha256 keeps the OLDEST
url, so a link that has been handed out never changes. Same name and a
different sha256 is a rebuild at an unchanged version; the newest wins,
since one filename cannot be offered twice and the later bytes are the
ones that were meant.

The second case is the common one, not the exception it was written
as. The builds are not bit-reproducible: of the first two gfx1201
builds for ROCm 10.2, on identical pins, all ten wheels whose version
had not moved differed in sha256. So an older build's metapackage
installs with the newer build's files wherever a version is unchanged,
and a build pin selects versions rather than bytes. The pages say so.

RELEASES ARE THE SOURCE OF TRUTH. gh-pages is not a safe place to keep
the only copy of anything: docs.yml replaces the branch with an orphan
commit on every deploy, and a deploy that races a publish discards
it. --from-releases therefore fills in any manifest builds/ is
missing, from the manifest.json each release carries -- or, for a
release cut before manifests existed, from its asset list, which
already has a sha256 per file.

Usage:  wheelsite.py <wheels-root> [--repo owner/name] [--from-releases]
"""
from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

# `python3 -I` leaves the script's own directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import wheelindex  # noqa: E402

# Only the projects worth naming on a landing page. The index itself
# lists everything; repeating 12 rows per arch here would bury the one
# thing a reader wants, which is the install command.
HIGHLIGHT = ("torch", "triton", "vllm")

# wheels-<rocm>-<arch>[-<build>]. The arch may itself carry a hyphen
# (emu-gfx1151), which is why the build is anchored to the end and to
# its exact shape rather than split off on "-". Releases cut before
# builds were dated have no third field; they are one build each.
TAG_RE = re.compile(
    r"^wheels-(?P<rocm>\d+(?:\.\d+)+)-(?P<arch>.+?)"
    r"(?:-(?P<build>\d{8}(?:\.\d+)?))?$")


def vkey(s) -> tuple:
    return tuple(int(p) for p in re.findall(r"\d+", s or ""))


def rocm_dir(rocm: str) -> str:
    """10.2.0-full -> rocm10.2. Major.minor, as the wheels' ABI goes."""
    parts = rocm.split("-")[0].split(".")
    return "rocm" + ".".join(parts[:2])


# ─── manifests ───────────────────────────────────────────────────────

def load_builds(root: Path) -> list[dict]:
    """Every manifest under builds/, oldest build first.

    Ordered by ROCm version and then build number, which is what
    "newest" means everywhere below. A manifest that does not parse is
    fatal: skipping it would quietly withdraw a published build from
    every index.
    """
    out = []
    for path in sorted((root / "builds").glob("*.json")):
        try:
            m = json.loads(path.read_text(encoding="utf-8"))
            m["tag"] = path.stem
            m["files"], m["arch"], m["rocm"], m["base_url"]
        except (ValueError, KeyError) as exc:
            sys.exit(f"error: {path} is not a build manifest: {exc!r}")
        out.append(m)
    out.sort(key=lambda m: (vkey(m["rocm"]), vkey(m.get("build")), m["tag"]))
    return out


def gh(*args: str) -> str:
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"error: gh {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def synthesise(release: dict, m: re.Match, root: Path, repo: str) -> dict:
    """A manifest for a release that was published without one.

    The asset list is enough for an index: GitHub records a sha256 per
    asset, and the metapackage is an asset like any other. What it
    cannot supply is what only the wheel's contents say --
    Requires-Python and the platform-tag verdicts -- so those are left
    out, except that verdicts are taken from the index this replaces
    when it describes these same files.
    """
    files = []
    sidecars = {a["name"]: a for a in release["assets"]
                if a["name"].endswith(".whl.metadata")}
    newest = ""
    meta_version = None
    for a in release["assets"]:
        w = wheelindex.WHEEL_RE.match(a["name"])
        if not w:
            continue
        newest = max(newest, a.get("updated_at") or "")
        project = wheelindex.normalize(w.group("name"))
        if project == wheelindex.METAPACKAGE:
            meta_version = w.group("version")
        side = sidecars.get(a["name"] + ".metadata")
        files.append(dict(
            project=project, version=w.group("version"),
            filename=a["name"], size=a.get("size"),
            sha256=(a.get("digest") or "").removeprefix("sha256:") or None,
            requires_python=None,
            metadata_sha256=((side.get("digest") or "")
                             .removeprefix("sha256:") or None)
            if side else None))
    names = {f["filename"] for f in files}
    verdicts = []
    old = root / m.group("arch") / "verdicts.json"
    if old.is_file():
        try:
            verdicts = [v for v in json.loads(old.read_text())["wheels"]
                        if v.get("wheel") in names]
        except (ValueError, KeyError):
            verdicts = []
    # No build number in the tag, so the day its last asset landed.
    build = m.group("build") or re.sub(r"\D", "", newest[:10]) or None
    return dict(
        schema=1, arch=m.group("arch"), rocm=m.group("rocm"), build=build,
        python=None, metapackage=meta_version, synthesised=True,
        base_url=(f"https://github.com/{repo}/releases/download/"
                  f"{release['tag_name']}/"),
        files=sorted(files, key=lambda f: f["filename"]),
        verdicts=verdicts)


def from_releases(root: Path, repo: str) -> int:
    """Write every manifest builds/ lacks. Returns how many it added."""
    builds = root / "builds"
    builds.mkdir(parents=True, exist_ok=True)
    added = 0
    lines = gh("api", "--paginate", f"repos/{repo}/releases?per_page=100",
               "--jq", ".[] | select(.draft | not) | tojson").splitlines()
    for line in lines:
        release = json.loads(line)
        tag = release["tag_name"]
        m = TAG_RE.match(tag)
        dest = builds / f"{tag}.json"
        if not m or dest.exists():
            continue
        if any(a["name"] == "manifest.json" for a in release["assets"]):
            dest.write_text(gh("release", "download", tag, "--repo", repo,
                               "--pattern", "manifest.json",
                               "--output", "-"), encoding="utf-8")
            how = "its manifest.json"
        elif m.group("build"):
            # A dated release with no manifest is a publish that has
            # not finished: wheelpublish.sh uploads it last. Listing it
            # would offer a build whose wheels are not all there.
            continue
        else:
            manifest = synthesise(release, m, root, repo)
            if not manifest["files"]:
                continue
            dest.write_text(json.dumps(manifest, indent=1, sort_keys=True)
                            + "\n", encoding="utf-8")
            how = "its asset list"
        print(f"wheelsite: recovered {tag} from {how}")
        added += 1
    return added


# ─── one index ───────────────────────────────────────────────────────

def merged_files(builds: list[dict]) -> dict[str, list[dict]]:
    """{project: [entry]} across builds; see A FILENAME IS LISTED ONCE."""
    by_name: dict[str, dict] = {}
    for m in builds:                                  # oldest first
        for f in m["files"]:
            have = by_name.get(f["filename"])
            if have and have["sha256"] == f["sha256"]:
                continue
            by_name[f["filename"]] = dict(
                f, url=m["base_url"].rstrip("/") + "/" + f["filename"])
    projects: dict[str, list[dict]] = {}
    for name in sorted(by_name):
        f = by_name[name]
        projects.setdefault(f["project"], []).append(wheelindex.file_entry(
            f["url"], name, f.get("sha256"), f.get("requires_python"),
            f.get("metadata_sha256")))
    return projects


def write_index(dest: Path, arch: str, builds: list[dict]) -> None:
    """One PEP 503 index holding every build in `builds`."""
    dest.mkdir(parents=True, exist_ok=True)
    projects = merged_files(builds)
    for project, entries in projects.items():
        wheelindex.write_project(dest, project, entries)

    newest = builds[-1]
    rows = "".join(
        f"<tr><td><code>{html.escape(m.get('build') or '—')}</code></td>"
        f"<td><code>{html.escape(m.get('metapackage') or '—')}</code></td>"
        f"<td><code>{html.escape(m['tag'])}</code></td></tr>"
        for m in reversed(builds))
    root = ["<!DOCTYPE html><html><head>", wheelindex.REPOSITORY_VERSION,
            "</head><body>",
            f"<h1>{html.escape(arch)} · ROCm "
            f"{html.escape(newest['rocm'].split('-')[0])}</h1>"]
    for project in sorted(projects):
        root.append(f'<a href="{project}/">{html.escape(project)}</a><br/>')
    # No <a> below this line, for the reason render_verdicts gives.
    root.append(
        "<h2>Builds</h2><p>Every build's versions stay installable. An "
        "unpinned install takes the newest; name one with "
        f"<code>rocm-torch[device-{html.escape(arch)}]==&lt;version "
        "before the +&gt;</code>.</p><table><tr><th>build</th>"
        "<th>rocm-torch</th><th>release</th></tr>" + rows + "</table>")
    if newest.get("verdicts"):
        root.append(wheelindex.render_verdicts(newest["verdicts"]))
    root.append("</body></html>")
    (dest / "index.html").write_text("\n".join(root) + "\n",
                                     encoding="utf-8")

    # The newest build's measurements, where wheels-probe.yml reads
    # them. Left out for a build that has none rather than written
    # empty: the probe treats a missing file as "not measured yet" and
    # an empty list as "published, and nothing was measured".
    if newest.get("verdicts"):
        (dest / "verdicts.json").write_text(json.dumps(
            {"arch": arch, "rocm": newest["rocm"],
             "build": newest.get("build"), "wheels": newest["verdicts"]},
            indent=1, sort_keys=True) + "\n", encoding="utf-8")


# ─── the tree ────────────────────────────────────────────────────────

def group(builds: list[dict]) -> dict[tuple[str, str], list[dict]]:
    """{(rocm dir, arch): [build, oldest first]}."""
    out: dict[tuple[str, str], list[dict]] = {}
    for m in builds:
        out.setdefault((rocm_dir(m["rocm"]), m["arch"]), []).append(m)
    return out


def latest_per_arch(groups) -> dict[str, tuple[str, str]]:
    """{arch: the (rocm dir, arch) key of its newest ROCm}."""
    out: dict[str, tuple[str, str]] = {}
    for key in groups:
        cur = out.get(key[1])
        if cur is None or vkey(key[0]) > vkey(cur[0]):
            out[key[1]] = key
    return out


def write_tree(root: Path, builds: list[dict]) -> list[dict]:
    """Regenerate every index. Returns one summary row per index."""
    # Everything but the manifests is output, and is rebuilt whole: an
    # index for a build whose manifest was removed must not survive as
    # a directory nothing regenerates.
    for old in root.iterdir():
        if old.name == "builds":
            continue
        shutil.rmtree(old) if old.is_dir() else old.unlink()

    groups = group(builds)
    latest = latest_per_arch(groups)
    rows = []
    for (rdir, arch), members in sorted(
            groups.items(),
            key=lambda kv: (tuple(-n for n in vkey(kv[0][0])), kv[0][1])):
        write_index(root / rdir / arch, arch, members)
        is_latest = latest[arch] == (rdir, arch)
        if is_latest:
            write_index(root / arch, arch, members)
        newest = members[-1]
        versions = {f["project"]: f["version"] for f in newest["files"]}
        rows.append(dict(
            arch=arch, rocm=newest["rocm"].split("-")[0],
            path=f"{rdir}/{arch}/", alias=f"{arch}/" if is_latest else None,
            latest=is_latest, builds=[m.get("build") for m in members],
            metapackage=newest.get("metapackage"),
            versions={p: versions.get(p) for p in HIGHLIGHT},
            verdicts=newest.get("verdicts") or []))
    return rows


def tag_summary(found: list[dict]) -> str:
    """"5 manylinux · 4 linux_x86_64 · 3 pure", or an em dash."""
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


def render(rows: list[dict], repo: str) -> str:
    site = f"https://{repo.split('/')[0]}.github.io/{repo.split('/')[1]}"

    body = []
    for r in rows:
        cells = "".join(
            f"<td><code>{html.escape(r['versions'].get(p) or '—')}</code></td>"
            for p in HIGHLIGHT)
        also = (f' <span class="note">also <a href="{html.escape(r["alias"])}">'
                f'<code>{html.escape(r["alias"])}</code></a></span>'
                if r["alias"] else "")
        body.append(
            f"<tr><td><code>{html.escape(r['rocm'])}</code></td>"
            f'<td><a href="{html.escape(r["path"])}">'
            f"<code>{html.escape(r['path'])}</code></a>{also}</td>"
            f"{cells}"
            f"<td><code>{html.escape(r['metapackage'] or '—')}</code></td>"
            f"<td>{len(r['builds'])}</td>"
            f"<td>{html.escape(tag_summary(r['verdicts']))}</td></tr>")

    head = "".join(f"<th><code>{p}</code></th>" for p in HIGHLIGHT)
    # The arch the landing page's headline `pip install` names. A gfx
    # index on the newest ROCm, not simply the first row: the emulator
    # lane publishes under pseudo-arches named emu-<gfx> (docs/
    # architecture/emulation.md), and "emu-gfx1151" sorts ahead of
    # every real gfx name — so a plain rows[0] would quietly make the
    # front page advertise a build with no GPU support at all as the
    # way to install this project.
    lead = next((r for r in rows if r["latest"]
                 and r["arch"].startswith("gfx")),
                rows[0] if rows else None)
    first = lead["arch"] if lead else "gfx950"
    first_path = lead["path"] if lead else "rocm10.2/gfx950/"
    first_meta = ((lead["metapackage"] or "").split("+")[0]
                  if lead else "") or "10.2.0.20261127"

    # The note this replaces said the same thing from memory, and said
    # it about whichever wheels were published the day it was written.
    # Each arch index now carries the measurement, so this links to it
    # and names anything a reader could act on.
    narrow = [(r["path"], v) for r in rows for v in r["verdicts"]
              if v.get("best") is False]
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

<p>One PEP 503 index per ROCm version and GPU architecture. The wheels
themselves are GitHub release assets; these pages point at them, with a
<code>#sha256=</code> on every link so pip verifies what it downloads.</p>

<pre>pip install \\
  --index-url {site}/data/wheels/{html.escape(first)}/ \\
  --extra-index-url https://pypi.org/simple \\
  "rocm-torch[device-{html.escape(first)}]"</pre>

<table>
<thead><tr><th>ROCm</th><th>index</th>{head}
<th><code>rocm-torch</code></th><th>builds</th>
<th>platform tags</th></tr></thead>
<tbody>
{chr(10).join(body) if body else '<tr><td colspan="8">none published</td></tr>'}
</tbody>
</table>

<h2>Choosing a version</h2>

<p><code>data/wheels/&lt;arch&gt;/</code> follows the newest ROCm
published for that architecture, and an unpinned install from it takes
the newest build. Both can be held still.</p>

<p><strong>A ROCm version</strong> has its own index, which a newer
ROCm never changes:</p>

<pre>pip install \\
  --index-url {site}/data/wheels/{html.escape(first_path)} \\
  --extra-index-url https://pypi.org/simple \\
  "rocm-torch[device-{html.escape(first)}]"</pre>

<p><strong>A build</strong> is a version of <code>rocm-torch</code>.
Every build ever published stays in its index, so pinning the
metapackage pins the version of every wheel in the set:</p>

<pre>pip install \\
  --index-url {site}/data/wheels/{html.escape(first_path)} \\
  --extra-index-url https://pypi.org/simple \\
  "rocm-torch[device-{html.escape(first)}]=={html.escape(first_meta)}"</pre>

<p class="note">Each index page lists its builds. The part of the
version after <code>+</code> is not needed to pin one. A build pin
selects versions, not bytes: where two builds share a filename the
index offers the newer file. Published files are never replaced, so a
lockfile that records hashes is what holds the exact ones.</p>

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
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root", help="the data/wheels directory")
    ap.add_argument("--repo", default="sbates130272/rocm-bake")
    ap.add_argument("--from-releases", action="store_true",
                    help="first recover any manifest builds/ is missing "
                         "from the GitHub releases (needs gh)")
    args = ap.parse_args()

    root = Path(args.root)
    root.mkdir(parents=True, exist_ok=True)
    if args.from_releases:
        from_releases(root, args.repo)

    builds = load_builds(root)
    rows = write_tree(root, builds)

    # The same list as data, so the weekly probe resolves every index
    # that exists rather than the ones someone remembered to name.
    (root / "index.json").write_text(json.dumps(
        {"indexes": [{k: r[k] for k in ("arch", "rocm", "path", "alias",
                                        "latest", "builds", "metapackage")}
                     for r in rows]}, indent=1, sort_keys=True) + "\n",
        encoding="utf-8")
    out = root / "index.html"
    out.write_text(render(rows, args.repo), encoding="utf-8")
    print(f"wheelsite: {out} ({len(builds)} build(s), {len(rows)} index(es): "
          f"{', '.join(r['path'] for r in rows) or 'none'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
