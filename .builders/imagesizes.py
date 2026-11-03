#!/usr/bin/env python3
"""Report how big every published image is, and what is making it big.

`wheelhouse.py` already answers this for the wheel repos, which are
scratch images whose only payload is /wheels. The run images are the
ones that get pulled onto a GPU host, and nothing sized them — which is
how `rocm/dev-ubuntu-26.04:10.1.0-full` came to be 8.67 GB of every one
of them without anyone noticing.

The interesting number is not the total. It is the split between layers
this image shares with the others and layers it owns: a 12 GB image
whose own contribution is 3 GB has a base problem, not a vLLM problem,
and the two have completely different fixes. Shared-ness is measured
rather than declared — a layer digest that appears under more than one
repository is shared, by definition, so nothing here has to know what
the base image is called.

Registry access is wheelhouse.py's: same manifest walk, same Zot search
extension, same tag grammar. This adds the layer arithmetic and the
JSON the documentation site plots.

Usage:
  imagesizes.py <registry> <namespace> --images R... [--wheels R...]
                [--caches R...] [--layers] [--json PATH]
"""
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wheelhouse import fetch, layers_of, parse_tag, zot_tag_info  # noqa: E402

# How many history points data/images.json keeps. One per `make
# image-data`, and the page plots them as a drift line — enough to see a
# regression arrive, bounded so a branch GitHub Pages serves does not
# accumulate a megabyte of JSON nobody reads.
HISTORY_KEEP = 60


def gb(n):
    return f"{n / 1e9:.2f} GB"


def tag_arch(tag):
    """The GPU architecture a tag is for, or None if it names none.

    parse_tag() is the right reader for a wheel tag and cannot read
    every tag here. It expects `<version>-<rocm>-<arch>`, and `base`
    publishes `<rocm>-<python>-<arch>` — 10.1.0-full-3.14-gfx1201 —
    which puts a second version where the arch should be and does not
    match. So `base` has never parsed as an artifact tag, and the
    `artifacts or tags` fallback below quietly sized whatever it had
    pushed most recently instead: a *dirty* build, in the table that
    prompted this.

    Widening wheelhouse.TAG_RE would be the wrong fix — wheelindex.py
    and the pip index depend on its groups, and this needs one of them.
    `gfxNNNN` appears in exactly one place in every tag this repo
    publishes, so look for it directly and leave the regex alone.
    """
    parsed = parse_tag(tag)
    if parsed:
        return parsed[2]
    m = re.search(r"-(gfx[0-9a-z_]+?)(?:-g[0-9a-f]+(?:-dirty)?)?$", tag)
    return m.group(1) if m else None


def newest_tag(registry, namespace, repo, tags, arch=None):
    """The tag most recently pushed for `arch`, preferring artifact tags.

    `latest` is excluded when anything else is available: it aliases
    whichever build ran last, so sizing it tells you nothing about
    *which* build, and the arch is exactly what you want in the table.

    `arch` narrows the pool to one GPU, and the shared/own split below
    is meaningless without it. Picking per repo by push time alone put
    six architectures in one table — rocm-runtime gfx1201 beside base
    on a dirty arch-less tag, pytorch gfx950, vllm gfx1250 — and
    mark_shared() then compared layers across all of them. That is why
    rocm-runtime reported `shared 0.00 GB`: the gfx1201 base that
    carries its layer was not the base being sized.

    noarch survives the filter: triton publishes one architecture-
    independent wheel, and it is genuinely shared by every image here.
    """
    info = zot_tag_info(registry, namespace, repo)
    if arch:
        # Anything naming this GPU, plus the genuinely arch-independent
        # tags — triton publishes one noarch wheel that every image
        # here really does share.
        pool = [t for t in tags
                if tag_arch(t) == arch
                or (parse_tag(t) and parse_tag(t)[2] == "noarch")]
    else:
        # The `or tags` fallback is for an unfiltered call only. Under
        # a filter it would reach for `latest` — an alias to whichever
        # arch built last — and reintroduce exactly the mixing the
        # filter exists to stop. "Not published for this arch" is the
        # honest answer, and the caller drops the row.
        pool = [t for t in tags if parse_tag(t)] or tags

    # A dirty build is a build from an uncommitted tree. It is a real
    # image and worth keeping reachable, but it should never be the one
    # a size table reports while a clean build of the same thing
    # exists — that is how `base` came to be represented by
    # 10.1.0-full-3.14-gab7317e-dirty.
    clean = [t for t in pool if not t.endswith("-dirty")]
    pool = clean or pool

    pool = sorted(pool, key=lambda t: info.get(t, (0, ""))[1] or "",
                  reverse=True)
    if not pool:
        return None, None
    tag = pool[0]
    return tag, (info.get(tag, (None, None))[1])


def image_entry(registry, namespace, repo, arch=None):
    """Size one repository's newest image, or None if it has none."""
    base = f"http://{registry}/v2/{namespace}/{repo}"
    try:
        tags = fetch(f"{base}/tags/list")["tags"] or []
    except Exception:
        return None
    tag, pushed = newest_tag(registry, namespace, repo, tags, arch)
    if not tag:
        return None
    try:
        layers = layers_of(base, tag)
    except Exception:
        return None
    parsed = parse_tag(tag) or (None, None, None, None)
    return {
        "repo": repo,
        "tag": tag,
        "arch": parsed[2] or "-",
        "pushed": pushed,
        "tags": len(tags),
        "bytes": sum(layer.get("size", 0) for layer in layers),
        "layers": [{"digest": layer.get("digest"),
                    "bytes": layer.get("size", 0)} for layer in layers],
    }


def mark_shared(entries):
    """Flag each layer that more than one of these images carries.

    Counted per repository, not per image: two tags of the same repo
    sharing a layer is the uninteresting case, and we only size one tag
    per repo anyway.
    """
    owners = {}
    for e in entries:
        for digest in {layer["digest"] for layer in e["layers"]}:
            owners.setdefault(digest, set()).add(e["repo"])
    for e in entries:
        shared = own = 0
        for layer in e["layers"]:
            layer["shared"] = len(owners.get(layer["digest"], ())) > 1
            if layer["shared"]:
                shared += layer["bytes"]
            else:
                own += layer["bytes"]
        e["shared_bytes"] = shared
        e["own_bytes"] = own
    return entries


def cache_entry(registry, namespace, repo):
    """A layer-cache repo's tag count and total size.

    Summed across tags, which overstates disk: these repos hold five
    fixed tags each — latest, latest-<arch>, latest-<arch>-ref — and the
    arch variants share most of their layers. It is still the right
    number for comparing one target's cache against another's, which is
    what the column is for. `make zot-disk` has the deduplicated figure.
    """
    results = zot_tag_info(registry, namespace, repo)
    if not results:
        return None
    return {"repo": repo, "tags": len(results),
            "bytes": sum(size for size, _ in results.values())}


def print_table(images, wheels, caches, show_layers):
    if images:
        print("\033[36m══ run images\033[0m  (shared = a layer another "
              "image also carries)")
        print(f"  \033[2m{'repo':<16} {'tag':<40} {'total':>9} "
              f"{'shared':>9} {'own':>9}  pushed\033[0m")
        for e in images:
            print(f"  \033[1m{e['repo']:<16}\033[0m {e['tag'][:40]:<40} "
                  f"{gb(e['bytes']):>9} {gb(e['shared_bytes']):>9} "
                  f"{gb(e['own_bytes']):>9}  "
                  f"{(e['pushed'] or '-').replace('T', ' ')[:16]}")
            if not show_layers:
                continue
            for i, layer in enumerate(e["layers"]):
                if layer["bytes"] < 50_000_000:
                    continue
                kind = "shared" if layer["shared"] else "own"
                print(f"      \033[2mlayer {i:<3} {gb(layer['bytes']):>9}"
                      f"  {kind}\033[0m")
    if wheels:
        print("\033[36m══ wheel images\033[0m")
        for e in wheels:
            print(f"  {e['repo']:<16} {e['tag'][:42]:<42} "
                  f"{gb(e['bytes']):>9}")
    if caches:
        print("\033[36m══ layer-cache repos\033[0m  (summed over tags, so "
              "shared layers count twice — see `make zot-disk`)")
        total = 0
        for e in caches:
            total += e["bytes"]
            print(f"  {e['repo']:<20} {e['tags']:>3} tags "
                  f"{gb(e['bytes']):>12}")
        print(f"  \033[1m{'total':<20} {'':>3}      {gb(total):>12}\033[0m")


def split_args(argv, flag):
    """Everything after --flag up to the next --flag, as a list."""
    if flag not in argv:
        return []
    i = argv.index(flag)
    out = []
    for a in argv[i + 1:]:
        if a.startswith("--"):
            break
        out.append(a)
    return out


def main(argv):
    positional = [a for a in argv if not a.startswith("--")]
    # Only the first two bare words are positional; the rest belong to
    # whichever --flag list they follow.
    consumed = set()
    for flag in ("--images", "--wheels", "--caches", "--json", "--arch"):
        consumed.update(split_args(argv, flag))
    positional = [a for a in positional if a not in consumed]
    if len(positional) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    registry, namespace = positional[0], positional[1]

    # One architecture per table, because shared/own is only meaningful
    # within one. The Makefile always passes it; a bare call without it
    # keeps the old cross-arch behaviour rather than guessing.
    arch = (split_args(argv, "--arch") or [None])[0]

    images = [e for e in (image_entry(registry, namespace, r, arch)
                          for r in split_args(argv, "--images")) if e]
    wheels = [e for e in (image_entry(registry, namespace, r, arch)
                          for r in split_args(argv, "--wheels")) if e]
    caches = [e for e in (cache_entry(registry, namespace, r)
                          for r in split_args(argv, "--caches")) if e]

    # Shared-ness is computed over the run images and the wheel images
    # together: the wheel images are scratch and share nothing, which is
    # worth being able to see rather than assert.
    mark_shared(images + wheels)

    out = split_args(argv, "--json")
    if out:
        path = Path(out[0])
        now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
        point = {"generated": now,
                 "images": [{k: v for k, v in e.items() if k != "layers"}
                            for e in images],
                 "caches": caches}
        history = []
        if path.exists():
            try:
                history = json.loads(path.read_text()).get("history", [])
            except Exception:
                history = []
        # Same timestamp twice means the same snapshot regenerated, not
        # two data points.
        history = [h for h in history if h.get("generated") != now]
        history.append(point)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "generated": now,
            "registry": f"{registry}/{namespace}",
            "images": images,
            "wheels": wheels,
            "caches": caches,
            "history": history[-HISTORY_KEEP:],
        }, indent=1))
        print(f"image data: {path}")
        return 0

    print_table(images, wheels, caches, "--layers" in argv)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
