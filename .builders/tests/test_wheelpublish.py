"""Does publishing keep every build, and never change one already public?

Those are the two promises the public index makes, and the old
publisher broke both by design. It kept one release per (ROCm, arch),
uploaded over it with --clobber and pruned what the new build had not
produced, then replaced data/wheels/<arch>/ wholesale. So a URL meant
different bytes on different days, and publishing ROCm 10.2 dropped
10.1 from the index while every 10.1 wheel was still public.

What is pinned here:

    a build that differs    -> a new release; the old one untouched
    a build that does not   -> nothing uploaded at all
    same tag, other wheels  -> refused, nothing uploaded
    a publish that died     -> resumed into the same release
    gh is never asked to replace or delete anything

and, of the index built from the result:

    every build and every ROCm version is listed
    <arch>/ is the newest ROCm's index, byte for byte
    a wheel two builds share keeps the URL it was first given
    an unfinished release is not offered

`gh` is fake-gh beside this file: releases are directories. No network,
no Docker, and --no-push, so the gh-pages half is exercised through
wheelsite.py directly rather than through a git push.
"""
import json
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILDERS = HERE.parent
FAILED = []


def check(ok, what):
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok:
        FAILED.append(what)


def wheel(d, dist, ver, body="x", requires=()):
    d.mkdir(parents=True, exist_ok=True)
    meta = (f"Metadata-Version: 2.1\nName: {dist}\nVersion: {ver}\n"
            "Requires-Python: >=3.10\n"
            + "".join(f"Requires-Dist: {r}\n" for r in requires))
    members = ((f"{dist}/__init__.py", body),
               (f"{dist}-{ver}.dist-info/METADATA", meta),
               (f"{dist}-{ver}.dist-info/WHEEL",
                "Wheel-Version: 1.0\nGenerator: test\n"
                "Root-Is-Purelib: true\nTag: py3-none-any\n"),
               (f"{dist}-{ver}.dist-info/RECORD", ""))
    with zipfile.ZipFile(d / f"{dist}-{ver}-py3-none-any.whl", "w") as z:
        for name, text in members:
            z.writestr(zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0)), text)


def main():
    tmp = Path(tempfile.mkdtemp(prefix="wheelpublish-"))
    state = tmp / "gh" / "releases"
    env = dict(os.environ, GH_STATE=str(state),
               PATH=f"{tmp / 'bin'}{os.pathsep}{os.environ['PATH']}")
    (tmp / "bin").mkdir()
    (tmp / "bin" / "gh").symlink_to(HERE / "fake-gh")

    torch = "torch-2.15.0+rocm10.2.0-py3-none-any.whl"
    wheel(tmp / "b1", "torch", "2.15.0+rocm10.2.0")
    wheel(tmp / "b1", "vllm", "0.34.0+rocm102", requires=["torch"])
    wheel(tmp / "b2", "torch", "2.15.0+rocm10.2.0")        # same bytes
    wheel(tmp / "b2", "vllm", "0.35.0+rocm102", requires=["torch"])
    wheel(tmp / "old", "torch", "2.15.0+rocm10.1.0")

    def publish(wheels, rocm="10.2.0-full", *extra):
        r = subprocess.run(
            [str(BUILDERS / "wheelpublish.sh"), "--arch", "gfx950",
             "--rocm", rocm, "--wheels", str(tmp / wheels),
             "--index", str(tmp / "index" / "gfx950"),
             "--repo", "o/r", "--no-push", *extra],
            env=env, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def assets(tag):
        d = state / tag
        return {f.name: f.read_bytes() for f in d.iterdir()} if d.is_dir() \
            else None

    t1, t2 = "wheels-10.2.0-gfx950-20261120", "wheels-10.2.0-gfx950-20261127"

    print("a dry run")
    rc, out = publish("b1", "10.2.0-full", "--build", "20261120", "--dry-run")
    check(rc == 0 and not list(state.glob("*")), "touches no release")
    check("manifest.json" in out, "names the assets it would send")

    print("a first build")
    rc, out = publish("b1", "10.2.0-full", "--build", "20261120")
    first = assets(t1)
    check(rc == 0 and first is not None, f"creates {t1}")
    check(first and {torch, torch + ".metadata",
                     "manifest.json"} <= set(first),
          "uploads the wheels, their .metadata and the manifest")

    print("the same wheels again")
    rc, out = publish("b1")
    check(rc == 0 and "nothing new to upload" in out, "is recognised")
    check(sorted(p.name for p in state.iterdir()) == [t1]
          and assets(t1) == first, "creates no release and changes none")

    print("different wheels under the same build number")
    rc, out = publish("b2", "10.2.0-full", "--build", "20261120")
    check(rc != 0 and "--build 20261120.1" in out,
          "is refused, and says how to publish it")
    check(assets(t1) == first, "leaves the published build untouched")

    print("different wheels as a new build")
    rc, out = publish("b2", "10.2.0-full", "--build", "20261127")
    check(rc == 0 and assets(t2) is not None, f"creates {t2}")
    check(assets(t1) == first, f"leaves {t1} untouched")

    print("a publish that died after one upload")
    t3 = "wheels-10.2.0-gfx950-20261204"
    (state / t3).mkdir()
    (state / t3 / torch).write_bytes((tmp / "b2" / torch).read_bytes())
    partial = dict(assets(t3))
    rc, out = publish("b2")
    check(rc == 0 and "resuming" in out, "is resumed into the same release")
    done = assets(t3)
    check("manifest.json" in done and done[torch] == partial[torch],
          "completes it without re-sending what was there")

    print("an asset that is already there with other bytes")
    t4 = "wheels-10.2.0-gfx950-20261211"
    (state / t4).mkdir()
    (state / t4 / torch).write_bytes(b"not the same wheel")
    rc, out = publish("b2", "10.2.0-full", "--build", "20261211")
    check(rc != 0 and set(assets(t4)) == {torch},
          "is refused with nothing uploaded")

    log = (tmp / "gh" / "gh.log").read_text()
    check("--clobber" not in log and "delete" not in log,
          "gh was never asked to replace or delete an asset")

    # ── the index ────────────────────────────────────────────────
    # An older ROCm, published the way releases were before builds
    # were dated: no build in the tag and no manifest. And t4, which
    # is unfinished and must not be offered.
    legacy = state / "wheels-10.1.0-gfx950"
    legacy.mkdir()
    old_torch = "torch-2.15.0+rocm10.1.0-py3-none-any.whl"
    (legacy / old_torch).write_bytes((tmp / "old" / old_torch).read_bytes())
    (legacy / "rocm_torch-10.1.0+gfx950.6b049405-py3-none-any.whl") \
        .write_bytes(b"")

    site = tmp / "site"
    r = subprocess.run(
        [sys.executable, "-I", str(BUILDERS / "wheelsite.py"), str(site),
         "--repo", "o/r", "--from-releases"],
        env=env, capture_output=True, text=True)
    print("the index rebuilt from the releases")
    check(r.returncode == 0, "builds" + ("" if r.returncode == 0
                                         else f": {r.stderr}"))
    if r.returncode:
        return 1

    def page(*parts):
        return (site.joinpath(*parts) / "index.html").read_text()

    listed = json.loads((site / "index.json").read_text())["indexes"]
    by_path = {i["path"]: i for i in listed}
    check(set(by_path) == {"rocm10.2/gfx950/", "rocm10.1/gfx950/"},
          "has one index per ROCm version")
    check(by_path["rocm10.2/gfx950/"]["builds"]
          == ["20261120", "20261127", "20261204"],
          "lists every finished build, and not the unfinished one")
    check(old_torch in page("rocm10.1", "gfx950", "torch"),
          "still offers the older ROCm, from a release with no manifest")

    vllm = page("rocm10.2", "gfx950", "vllm")
    check("vllm-0.34.0" in vllm and "vllm-0.35.0" in vllm,
          "offers both builds' vllm")
    torch_page = page("rocm10.2", "gfx950", "torch")
    check(torch_page.count("<a ") == 1 and f"{t1}/{torch}" in torch_page,
          "lists a shared wheel once, at the URL it was first given")
    check("data-core-metadata=" in torch_page
          and "data-requires-python=" in torch_page,
          "carries PEP 658 and Requires-Python attributes")

    same = all(
        (site / "gfx950" / f.relative_to(site / "rocm10.2" / "gfx950"))
        .read_bytes() == f.read_bytes()
        for f in (site / "rocm10.2" / "gfx950").rglob("*") if f.is_file())
    check(same and by_path["rocm10.2/gfx950/"]["alias"] == "gfx950/"
          and by_path["rocm10.1/gfx950/"]["alias"] is None,
          "<arch>/ is the newest ROCm's index, byte for byte")

    metas = page("rocm10.2", "gfx950", "rocm-torch")
    check(all(f"rocm_torch-10.2.0.{b}+" in metas
              for b in ("20261120", "20261127", "20261204")),
          "rocm-torch carries the build number in its public version")

    # GitHub Pages fails the whole site on a "+" in a filename.
    plus = [str(f) for f in site.rglob("*") if "+" in f.name]
    check(not plus, 'nothing on the site has a "+" in its name')

    print()
    if FAILED:
        print(f"{len(FAILED)} check(s) failed:")
        for what in FAILED:
            print(f"  {what}")
        return 1
    print("wheel publishing keeps every build and replaces none")
    return 0


if __name__ == "__main__":
    sys.exit(main())
