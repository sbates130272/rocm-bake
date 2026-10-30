#!/usr/bin/env python3
"""The build DAG, read out of bake instead of kept beside it.

balance.sh used to carry the dependency order by hand as STAGE_1
through STAGE_5. That was a second copy of something rocm-bake.hcl
already states exactly — every target's `contexts` block — and the two
could disagree without anything saying so. A gfx1250 perf-build
scheduled vllm-wheel when no gfx1250 pytorch image existed anywhere;
it failed resolving its base image at step 1 of 7, 0s in, and took the
rest of that node's queue down with it.

bake knows the graph. `--print` *without* PUBLISHED_INPUTS leaves the
`target:` contexts intact, and those edges are the graph. With
PUBLISHED_INPUTS the same edges collapse to registry refs in
`args.*_IMAGE`, which is what the scheduler actually builds against —
so both views are needed, and this reads both.

Two modes, because the scheduler needs two different answers:

  --deps       "<target> <dep>..." per requested target. Edges leaving
               the requested set are kept; the scheduler treats those
               as external, which is what --preflight is for.

  --preflight  Every image a requested target resolves from the
               registry, minus the ones this run will publish itself,
               checked against the registry. Exits 1 listing what is
               absent and the make target that would create it.

  --group      The members of a bake group. So that callers naming a
               set of targets — the Makefile, perfrun.sh — do not keep
               their own copy of a list rocm-bake.hcl already has.

Usage:
  depgraph.py --deps <target>...
  depgraph.py --preflight <target>...
  depgraph.py --group <name>
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))

# bake target -> the make rule that publishes it. Same mapping
# balance.sh uses; duplicated here only to name the fix in an error
# message, never to dispatch a build.
MAKE_RULE = {
    "pytorch-base": "push-base",
    "pytorch": "push-pytorch",
    "pytorch-run": "push-runtime",
    "pytorch-wheel": "push-torch-wheel",
    "triton-wheel": "push-triton-wheel",
    "aiter-wheel": "push-aiter-wheel",
}


def bake_print(targets, published):
    """bake's resolved view of `targets`, or None if bake refuses.

    stderr is dropped: bake writes its progress there and a failure is
    already visible as a non-zero exit.
    """
    env = dict(os.environ)
    if published:
        env["PUBLISHED_INPUTS"] = "1"
    else:
        env.pop("PUBLISHED_INPUTS", None)
    try:
        out = subprocess.run(
            ["docker", "buildx", "bake", "-f", "rocm-bake.hcl", "--print",
             *targets],
            capture_output=True, text=True, env=env, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except ValueError:
        return None


def deps_of(doc):
    """{target: [dep, ...]} from the `target:` contexts."""
    out = {}
    for name, spec in (doc.get("target") or {}).items():
        edges = []
        for value in (spec.get("contexts") or {}).values():
            value = str(value)
            if value.startswith("target:"):
                edges.append(value.split(":", 1)[1])
        out[name] = sorted(set(edges))
    return out


def ref_parts(ref):
    """(host, path, tag) for a registry reference, or None.

    A digest reference has no tag to check by name; those are pinned
    by content and cannot dangle, so they are skipped rather than
    treated as missing.
    """
    if "@" in ref or "/" not in ref:
        return None
    head, _, tag = ref.rpartition(":")
    if not tag or "/" in tag:
        return None
    host, _, path = head.partition("/")
    if not path:
        return None
    return host, path, tag


def produced(doc):
    """{ref: target} for everything this graph publishes."""
    out = {}
    for name, spec in (doc.get("target") or {}).items():
        for tag in (spec.get("tags") or []):
            out[str(tag)] = name
    return out


def needed(doc):
    """{target: [ref, ...]} — the images each target resolves remotely."""
    out = {}
    for name, spec in (doc.get("target") or {}).items():
        refs = []
        for key, value in (spec.get("args") or {}).items():
            if not key.endswith("_IMAGE"):
                continue
            value = str(value)
            if ref_parts(value):
                refs.append(value)
        out[name] = sorted(set(refs))
    return out


def exists(ref):
    """True if the registry has that manifest."""
    parts = ref_parts(ref)
    if not parts:
        return True
    host, path, tag = parts
    url = f"http://{host}/v2/{path}/manifests/{tag}"
    req = urllib.request.Request(url, method="HEAD",
                                 headers={"Accept": ACCEPT})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return 200 <= r.status < 300
    except urllib.error.HTTPError as e:
        # Only 404 means absent. Anything else is the registry, or
        # something in front of it, declining to answer — and the
        # corporate proxy answers 403 for the tailnet unless no_proxy
        # covers it, which made every ref look missing when this was
        # run outside make. Blocking a build on that would be wrong.
        return e.code != 404
    except OSError:
        # Registry unreachable. Not the same as absent, and refusing to
        # schedule because Zot blinked would be worse than letting the
        # build fail with its own message.
        return True


def main(argv):
    if len(argv) < 2 or argv[0] not in ("--deps", "--preflight", "--group"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    mode, targets = argv[0], argv[1:]

    if mode == "--group":
        doc = bake_print(targets[:1], published=False)
        if doc is None:
            print(f"depgraph: no such bake group: {targets[0]}",
                  file=sys.stderr)
            return 2
        members = ((doc.get("group") or {}).get(targets[0]) or {}).get(
            "targets")
        if not members:
            print(f"depgraph: {targets[0]!r} is not a group in "
                  f"rocm-bake.hcl", file=sys.stderr)
            return 2
        print(" ".join(members))
        return 0

    plain = bake_print(targets, published=False)
    if plain is None:
        print("depgraph: bake --print failed; cannot read the build graph",
              file=sys.stderr)
        return 2

    if mode == "--deps":
        graph = deps_of(plain)
        for name in targets:
            print(name, *graph.get(name, []))
        return 0

    pub = bake_print(targets, published=True)
    if pub is None:
        print("depgraph: bake --print failed under PUBLISHED_INPUTS",
              file=sys.stderr)
        return 2

    mine = produced(pub)
    wanted = set(targets)
    missing = {}
    for name in targets:
        for ref in needed(pub).get(name, []):
            # Produced by something this run will build and push, so it
            # is the scheduler's job to order it, not the registry's to
            # already have it.
            if mine.get(ref) in wanted:
                continue
            if not exists(ref):
                missing.setdefault(ref, set()).add(name)

    if not missing:
        return 0

    print("depgraph: these images are needed but not published, and "
          "nothing in this run builds them:", file=sys.stderr)
    for ref in sorted(missing):
        who = ", ".join(sorted(missing[ref]))
        owner = mine.get(ref)
        fix = ""
        if owner:
            rule = MAKE_RULE.get(owner, f"push-{owner}")
            fix = f"   build it with: make {rule}"
        print(f"  {ref}\n      needed by: {who}{fix}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
