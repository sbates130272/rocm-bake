#!/usr/bin/env python3
"""Report what is inside each published wheel image, without pulling it.

A "wheelhouse" here is a directory of .whl files that pip consumes with
--no-index --find-links. We ship those directories as scratch images in
Zot, so this reads each image's manifest straight from the registry and
reports the layer sizes and tags rather than downloading hundreds of MB.
"""
import json
import re
import sys
import urllib.request

ACCEPT = (
    "application/vnd.oci.image.index.v1+json,"
    "application/vnd.docker.distribution.manifest.list.v2+json,"
    "application/vnd.oci.image.manifest.v1+json,"
    "application/vnd.docker.distribution.manifest.v2+json"
)


# Tags are <version>-<rocm>-<arch>[-g<sha>[-dirty]], except triton's,
# which has no version of its own and starts at the ROCm release. Parse
# rather than print raw: the interesting columns are what was built and
# for which card, and those are buried mid-string.
# The arch group is optional: triton is a compiler and publishes one
# architecture-independent wheel, so its tags are <version>-<rocm> with
# no gfx component at all. Without the "?" those tags fail to parse and
# fall into the floating bucket beside "latest", which is wrong — they
# are artifact tags, they just have nothing to say about a GPU.
TAG_RE = re.compile(
    r"^(?P<version>.*?)-?"
    r"(?P<rocm>\d+\.\d+\.\d+-\w+)"
    r"(?:-(?P<arch>gfx[0-9a-z_]+))?"
    r"(?:-g(?P<build>[0-9a-f]+(?:-dirty)?))?$"
)


def parse_tag(tag):
    """Split a tag into (version, rocm, arch, build), or None if it is
    not an artifact tag — "latest" and friends fall through here."""
    m = TAG_RE.match(tag)
    if not m:
        return None
    d = m.groupdict()
    return (d["version"] or "-", d["rocm"], d["arch"] or "noarch",
            d["build"] or "-")


def device_extra(arch):
    """The pip extra that selects this tag's wheel, for the index
    wheelindex.py generates.

    Spelling it out beside the arch is the point: the arch is a
    property of the tag, while the extra is the string you actually
    type at an install, and deriving one from the other in your head is
    where the mistake happens — these wheels have arch-independent
    filenames, so installing the wrong one is silent until the GPU
    rejects the kernels.

    "-" for the arch-independent wheels: triton publishes one noarch
    wheel and carries no device extra, so it is pulled in by whichever
    arch's metapackage asked for it.
    """
    return "-" if arch in ("noarch", "-") else f"device-{arch}"


def fetch(url):
    # Relies on no_proxy covering the tailnet; the Makefile exports it.
    req = urllib.request.Request(url, headers={"Accept": ACCEPT})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def layers_of(base, tag):
    """The layer descriptors of a wheel image, following an index."""
    manifest = fetch(f"{base}/manifests/{tag}")
    # An index points at per-platform manifests; follow the first.
    if "manifests" in manifest:
        digest = manifest["manifests"][0]["digest"]
        manifest = fetch(f"{base}/manifests/{digest}")
    return manifest.get("layers", [])


def wheel_bytes(base, tag):
    """Compressed size of a wheel image's payload layers."""
    return sum(layer.get("size", 0) for layer in layers_of(base, tag))


def _decompress_prefix(data, media_type):
    """Best-effort decompress of a truncated layer blob.

    Every one of these raises on a short stream, which is exactly what
    we are handing it — the point is the bytes it produced before giving
    up, so the exception is the normal path rather than an error.
    """
    if "zstd" in media_type:
        try:
            from compression import zstd            # Python 3.14+
            d = zstd.ZstdDecompressor()
        except ImportError:
            try:
                import zstandard                    # pip install zstandard
                d = zstandard.ZstdDecompressor().decompressobj()
            except ImportError:
                return b""
        try:
            return d.decompress(data)
        except Exception:
            # Both implementations buffer what they managed to decode.
            return getattr(d, "_buffer", b"") or b""
    if "gzip" in media_type:
        import zlib
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            return d.decompress(data)
        except zlib.error:
            return b""
    return data  # uncompressed tar


def _tar_names(blob):
    """File names from as many 512-byte tar headers as `blob` holds.

    Walks header -> data -> next header, so it stops naturally once the
    prefix we fetched runs out. Long-name (GNU/PAX) entries are skipped
    rather than decoded: wheel filenames are well under the 100-byte
    field, so the plain header covers every name this reports on.
    """
    names, off = [], 0
    while off + 512 <= len(blob):
        header = blob[off:off + 512]
        if header[257:262] != b"ustar":
            break
        name = header[0:100].split(b"\0", 1)[0].decode("utf-8", "replace")
        if not name:
            break
        names.append(name)
        try:
            size = int(header[124:136].split(b"\0", 1)[0].strip() or b"0", 8)
        except ValueError:
            break
        off += 512 + (size + 511) // 512 * 512
    return names


# How much of a layer to read before giving up on finding the name.
# Escalating rather than one fixed size: a zstd frame emits nothing at
# all until it has a whole block, and the block size varies per layer —
# 64KB was enough for most of these repos but produced zero bytes for
# nixl-wheel, whose name then printed as "-". The cap still bounds the
# cost: without one, listing the registry would download every wheel in
# it. Both numbers are compressed bytes, and the common case stops at
# the first.
PREFIX_STEPS = (65536, 1048576)


def wheel_filename(base, tag):
    """The .whl name inside a wheel image, without pulling the image.

    The registry has no index of what is inside a layer, so there is no
    way to ask for this directly — but a tar puts its first file header
    in the first few hundred bytes, so a ranged GET of the start of the
    blob is enough. Returns "-" when the name cannot be read cheaply,
    which is not worth failing over: the size and tag still print.
    """
    try:
        layers = layers_of(base, tag)
    except Exception:
        return "-"
    for layer in layers:
        digest, media = layer.get("digest"), layer.get("mediaType", "")
        if not digest:
            continue
        for want in PREFIX_STEPS:
            req = urllib.request.Request(
                f"{base}/blobs/{digest}",
                headers={"Range": f"bytes=0-{want - 1}"})
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    blob = r.read(want)
            except Exception:
                break
            names = _tar_names(_decompress_prefix(blob, media))
            for name in names:
                if name.endswith(".whl"):
                    return name.rsplit("/", 1)[-1]
            # Names came out and none was a wheel: this layer is the
            # logs, not the payload. Reading more of it will not help.
            if names or len(blob) < want:
                break
    return "-"


def zot_tag_info(registry, namespace, repo):
    """Per-tag size and push time from Zot's search extension.

    The registry API proper has neither. An image's config carries a
    `created` field, but SOURCE_DATE_EPOCH pins that to a constant so
    every image reports the same date — deliberately, so a rebuild of
    unchanged content keeps its digest. Zot's GraphQL extension records
    when the manifest was actually pushed, which is the question
    "when was this published" is really asking.

    Returns {tag: (size_bytes, iso_date)} or {} if the extension is
    absent — the caller falls back to sizing manifests by hand.
    """
    query = ('{ImageList(repo:"%s/%s"){Results{Tag LastUpdated Size}}}'
             % (namespace, repo))
    body = json.dumps({"query": query}).encode()
    req = urllib.request.Request(
        f"http://{registry}/v2/_zot/ext/search", data=body,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            results = json.load(r)["data"]["ImageList"]["Results"]
    except Exception:
        return {}
    out = {}
    for item in results:
        try:
            out[item["Tag"]] = (int(item["Size"]), item["LastUpdated"])
        except (KeyError, TypeError, ValueError):
            continue
    return out


def main():
    args = sys.argv[1:]
    # --brief is the one-line-per-repo form behind `make zot-wheels`;
    # without it we expand every tag, which is `make zot-wheelhouse`.
    brief = "--brief" in args
    args = [a for a in args if a != "--brief"]
    # How many tags to show per repo, newest first. Every build adds a
    # tag and none are ever removed, so without a cap this grows without
    # bound and the useful rows scroll away. 0 means "all".
    limit = 5
    if "--limit" in args:
        i = args.index("--limit")
        try:
            limit = int(args[i + 1])
        except (IndexError, ValueError):
            print("--limit needs a number", file=sys.stderr)
            return 2
        del args[i:i + 2]
    registry, namespace, *repos = args

    for repo in repos:
        base = f"http://{registry}/v2/{namespace}/{repo}"
        try:
            tags = sorted(fetch(f"{base}/tags/list")["tags"])
        except Exception:
            print(f"  {repo:<14} (not published)")
            continue
        try:
            size = wheel_bytes(base, "latest")
        except Exception as exc:
            print(f"  {repo:<14} (manifest unreadable: {exc})")
            continue

        if brief:
            info = zot_tag_info(registry, namespace, repo)
            parsed = [(t, parse_tag(t)) for t in tags]
            artifacts = [(t, p) for t, p in parsed if p]
            floating = [t for t, p in parsed if not p]

            # Newest first, by when the manifest was actually pushed.
            # This used to sort by arch, on the reasoning that "what do
            # we have for this card" was the question — but every repo
            # accumulates a tag per build, so the answer that matters is
            # almost always "what did I just publish", and that was
            # landing in the middle of the list. Tags Zot has no push
            # time for sort last rather than first: an unknown date is
            # not evidence of being recent.
            artifacts.sort(key=lambda x: info.get(x[0], (0, ""))[1] or "",
                           reverse=True)
            shown = artifacts[:limit] if limit else artifacts
            hidden = len(artifacts) - len(shown)

            print(f"  \033[1m{repo}\033[0m  {size / 1048576:.1f} MB"
                  f"  ({len(tags)} tags)")
            if shown:
                # Every header is left-aligned, size included, even
                # though its values are right-aligned underneath. The
                # alignment of a column of numbers and the alignment of
                # the word naming it are separate choices: the numbers
                # line up on their units so they can be compared, while
                # a right-aligned header was the only one in the row
                # that did not start where its column does.
                print(f"      \033[2m{'published':<17} {'arch':<9} "
                      f"{'extra':<16} "
                      f"{'version':<9} {'rocm':<13} {'size':<9}  "
                      f"{'build':<16} wheel\033[0m")
            # Each tag is sized separately rather than assumed to alias
            # the repo's latest. Usually they do, but a tag left behind
            # by an earlier build does not, and that difference is the
            # interesting one — it is how you spot a stale artifact.
            for tag, (version, rocm, arch, build) in shown:
                size_b, when = info.get(tag, (None, None))
                if size_b is None:
                    try:
                        size_b = wheel_bytes(base, tag)
                    except Exception:
                        size_b = None
                mb = f"{size_b / 1048576:.1f} MB" if size_b else "? MB"
                # Date and time now, not date alone: several builds of
                # the same repo land on one day and the ordering is
                # unreadable without the clock.
                stamp = (when or "").replace("T", " ")[:16] or "-"
                print(f"      {stamp:<17} {arch:<9} {device_extra(arch):<16} "
                      f"{version:<9} "
                      f"{rocm:<13} {mb:>9}  {build:<16} "
                      f"{wheel_filename(base, tag)}")
            if hidden:
                print(f"      \033[2m… {hidden} older tag(s); "
                      f"ZOT_TAGS=0 for all\033[0m")
            if floating:
                print(f"      \033[2m{', '.join(floating)}\033[0m")
            continue

        print(f"  {repo:<14} {size / 1048576:8.1f} MB  {len(tags)} tag(s)")
        for tag in tags:
            # Tags usually alias one manifest, but a stale tag left behind
            # by an earlier build does not — so size each one.
            try:
                print(f"      {tag:<42} {wheel_bytes(base, tag) / 1048576:8.1f} MB"
                      f"  {wheel_filename(base, tag)}")
            except Exception:
                print(f"      {tag:<42}        ? MB")


if __name__ == "__main__":
    sys.exit(main() or 0)
