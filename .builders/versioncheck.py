#!/usr/bin/env python3
"""versioncheck.py - what upstream released, what we published, what we pin.

rocm-bake.hcl is the single source for every version a build reads, and
nothing told you when one of those pins went stale. The weekly workflow
watched two of the thirteen; the other eleven - AITER, NIXL, UCX, vLLM,
CuPy, LMCache, Triton, Rust, sccache - were unwatched. And the two it
did watch it compared wrong: it reduced the ROCm tag to "10.1" and
compared that against the bake default "10.1.0-full", so it reported
drift every single week regardless of the truth.

Two jobs, deliberately not entangled:

  report   (default, --markdown)
      Per component: the latest upstream release, the versions we have
      wheels published for in Zot, and the default in rocm-bake.hcl.
      Needs api.github.com through the proxy and the tailnet for the
      registry, so it runs on the fleet. Never writes a file.

  scrub    (--scrub, --scrub-check)
      Regenerates the marker blocks in README.md and
      docs/reference/bake-variables.md from rocm-bake.hcl alone. No
      network at all, which is what lets it gate every pull request
      in lint.yml - where the report could not run.

A lookup that fails is a "?" in its row, never a crash. The ROCm org
rejects classic personal access tokens, hub.docker.com fails TLS
through the corporate proxy, and the registry is a tailnet name a
GitHub runner cannot resolve. Any one of those turning the weekly
report red would mean the report gets switched off.

Exit codes: 0 ok, 1 scrub drift (--scrub-check), 2 usage error.

Usage: .builders/versioncheck.py [--markdown] [--no-zot]
                                 [--registry HOST] [--namespace NS]
       .builders/versioncheck.py --scrub | --scrub-check
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# parse_tag only, and not wheelhouse.fetch beside it. The regex that
# splits a published tag into (version, rocm, arch, build) is the one
# thing here that would genuinely drift if copied - it has already
# grown two special cases, for triton's missing arch and for the older
# triton tags that carry no version at all. fetch() is three lines and
# assumes no_proxy covers the tailnet, which is true under make and not
# true when this script is run directly, so this file does its own.
#
# The contract this import relies on: wheelhouse.py is stdlib-only and
# has no module-level side effects - everything is under its
# `if __name__ == "__main__"`. Keep it that way, or a stray print
# lands in the middle of this table.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import wheelhouse  # noqa: E402

# The tailnet must never traverse the corporate proxy, and neither must
# hub.docker.com: ZScaler's MITM certificate is not in this trust store,
# so a proxied call there dies with "unable to get local issuer
# certificate" before it sends a byte. Bypassing is right for both -
# one is a private network the proxy cannot reach, the other is a
# public host the proxy has no business inspecting.
DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# Releases whose tags are strictly vX.Y.Z and nothing else.
#
# Needed because `prerelease: false` is not evidence. LMCache publishes
# v0.5.7rc2-rocm, v0.5.7rc2-cu129, v0.5.7rc2-xpu and five more per
# release candidate, every one of them flagged as a full release;
# /releases/latest happens to return v0.5.6 today only because of how
# the underlying tags are dated. AITER does the same with v0.1.24.post1.
# Without this filter the next RC reports us "behind" a tag we must not
# build.
SEMVER = r"^v[0-9]+\\.[0-9]+\\.[0-9]+$"

# One row per thing we pin, in rocm-bake.hcl declaration order, which
# is also roughly build order. This is the only place a component is
# named.
#
# `source` names the lookup, not the project. TRITON_* and
# RUST_VERSION are pinned *by* pytorch and vllm respectively, and
# asking triton-lang or rust-lang directly is the wrong question:
# triton-lang's latest is v3.9.0 and rust-lang's is past 1.99, and
# bumping to either independently would build a stack whose compiler
# disagrees with the torch it compiles for. rocm-bake.hcl:80 and :250
# say so in prose; this encodes it. Verified: pytorch v2.14.1 pins
# triton 3.8.0 at 675c5987, and vllm v0.32.0 pins rust 1.95 - exactly
# our three defaults.
COMPONENTS = [
    dict(name="PyTorch", var="PYTORCH_VERSION", readme=True,
         source=("gh", "pytorch/pytorch"), norm="strip_v",
         wheel_repo="pytorch-wheel", label="pytorch/pytorch",
         url="https://github.com/pytorch/pytorch"),
    dict(name="ROCm", var="ROCM_VERSION", readme=True,
         source=("hub", "rocm/dev-ubuntu-26.04"), norm="verbatim",
         wheel_repo=None, label="rocm/dev-ubuntu-26.04",
         url="https://hub.docker.com/r/rocm/dev-ubuntu-26.04"),
    # No `source`: the version is not chosen against an upstream release
    # but by what the ROCm base image's Ubuntu archive carries, which is
    # why version-check reports it as "the base image decides" rather
    # than comparing it to anything. The link is the language's own
    # home, for reference only — bumping PYTHON_VERSION past what the
    # base image can apt-install fails regardless of what python.org has
    # released.
    dict(name="Python", var="PYTHON_VERSION", readme=True,
         source=("none", None), norm="verbatim", wheel_repo=None,
         label="python.org", url="https://www.python.org/"),
    dict(name="Triton", var="TRITON_VERSION", readme=True,
         source=("pin", ("pytorch/pytorch", ".ci/docker/triton_version.txt",
                         "PYTORCH_VERSION", "v{}", "text")),
         norm="verbatim", wheel_repo="triton-wheel",
         label="triton-lang/triton",
         url="https://github.com/triton-lang/triton"),
    dict(name="Triton commit", var="TRITON_REF", readme=False,
         source=("pin", ("pytorch/pytorch",
                         ".ci/docker/ci_commit_pins/triton.txt",
                         "PYTORCH_VERSION", "v{}", "text")),
         norm="verbatim", wheel_repo=None, label=None, url=None),
    # tag_var: aiter-wheel's tag is
    # aiter-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}
    # (rocm-bake.hcl:678), so the version component of a published
    # AITER tag is the *torch* version and says nothing about which
    # AITER_REF built it. Reporting it in the published column read as
    # "we have AITER 2.14.1", which is not a thing. Declared rather
    # than silently dropped: the column stays honest and the oddity
    # stays visible.
    dict(name="AITER", var="AITER_REF", readme=True,
         source=("gh", "ROCm/aiter"), norm="verbatim",
         wheel_repo="aiter-wheel", tag_var="PYTORCH_VERSION",
         label="ROCm/aiter",
         url="https://github.com/ROCm/aiter"),
    dict(name="NIXL", var="NIXL_REF", readme=True,
         source=("gh", "ai-dynamo/nixl"), norm="verbatim",
         wheel_repo="nixl-wheel", label="ai-dynamo/nixl",
         url="https://github.com/ai-dynamo/nixl"),
    dict(name="UCX", var="UCX_REF", readme=True,
         source=("gh", "openucx/ucx"), norm="verbatim",
         wheel_repo=None, label="openucx/ucx",
         url="https://github.com/openucx/ucx"),
    dict(name="vLLM", var="VLLM_REF", readme=True,
         source=("gh", "vllm-project/vllm"), norm="verbatim",
         wheel_repo="vllm-wheel", label="vllm-project/vllm",
         url="https://github.com/vllm-project/vllm"),
    dict(name="CuPy", var="CUPY_REF", readme=True,
         source=("gh", "cupy/cupy"), norm="verbatim",
         wheel_repo="cupy-wheel", label="cupy/cupy",
         url="https://github.com/cupy/cupy"),
    dict(name="LMCache", var="LMCACHE_REF", readme=True,
         source=("gh", "LMCache/LMCache"), norm="verbatim",
         wheel_repo="lmcache-wheel", label="LMCache/LMCache",
         url="https://github.com/LMCache/LMCache"),
    dict(name="Rust", var="RUST_VERSION", readme=False,
         source=("pin", ("vllm-project/vllm", "rust-toolchain.toml",
                         "VLLM_REF", "{}", "toml_channel")),
         norm="verbatim", wheel_repo=None, label=None, url=None),
    dict(name="sccache", var="SCCACHE_VERSION", readme=False,
         source=("gh", "mozilla/sccache"), norm="strip_v",
         wheel_repo=None, label="mozilla/sccache",
         url="https://github.com/mozilla/sccache"),
]

# Repos whose releases need the strict filter above rather than
# /releases/latest.
STRICT_SEMVER_REPOS = {"LMCache/LMCache", "ROCm/aiter"}

# Rows where "behind upstream" is the intended state, with the reason.
# Same shape and same purpose as check-defaults.py's ALLOWED: adding
# one is a deliberate act visible in review, which is why it lives here
# rather than in a cleverer comparison.
PINNED = {
    "TRITON_REF": "a sha pytorch pins",
    "PYTHON_VERSION": "the base image decides",
    "UCX_REF": "bumped with NIXL_REF",
}

# Rows whose Default cell in the docs says more than the bare value.
# The alternative is a generator that strips the explanation off a
# variable whose empty default is the entire point.
BAKE_NOTES = {"GIT_REF": '`""` - a specific PyTorch ref to build'}

# The order of docs/reference/bake-variables.md's version table. Not
# COMPONENTS: GIT_REF has no upstream so it is not a component, and
# SCCACHE_VERSION lives in that page's Compiler cache table instead -
# a marker block around one cell of an unrelated table would be worse
# than the staleness it removes.
BAKE_TABLE_VARS = [c["var"] for c in COMPONENTS
                   if c["var"] != "SCCACHE_VERSION"] + ["GIT_REF"]

# Where the generated blocks live. Keyed by marker name rather than by
# filename so the same generator can be pointed at a moved file.
SCRUB_TARGETS = [
    ("README.md", "VERSIONS"),
    ("docs/reference/bake-variables.md", "BAKE_VERSIONS"),
]


# ─── rocm-bake.hcl ────────────────────────────────────────────────

VAR_RE = re.compile(
    r'^variable\s+"(?P<name>[A-Za-z0-9_]+)"\s*\{(?P<body>.*?)^\}',
    re.M | re.S)
VAR_ONELINE_RE = re.compile(
    r'^variable\s+"(?P<name>[A-Za-z0-9_]+)"\s*\{(?P<body>[^\n}]*)\}', re.M)
DEF_RE = re.compile(r'default\s*=\s*"(?P<value>[^"]*)"')


def bake_defaults():
    """Every `variable "X" { ... default = "v" }` in rocm-bake.hcl.

    A block-then-default parse rather than a copy of the Makefile's awk
    (Makefile:21-26). That pass is constrained to POSIX awk and to a
    word list that cannot carry a space; neither constraint applies
    here, and the single-line `variable "X" { default = "" }` form the
    SDE_* block uses needs its own pattern either way.

    This is the third parser of this file and not the fourth: the
    grep|grep|sed in version-check.yml goes away with it.
    check-defaults.py keeps its own because it answers a different
    question - which names exist, for the Makefile cross-check.
    """
    text = (ROOT / "rocm-bake.hcl").read_text()
    out = {}
    for pattern in (VAR_ONELINE_RE, VAR_RE):
        for m in pattern.finditer(text):
            if m.group("name") in out:
                continue
            d = DEF_RE.search(m.group("body"))
            if d:
                out[m.group("name")] = d.group("value")
    return out


# ─── transports ───────────────────────────────────────────────────

CLASSIC_PAT = "personal access token (classic)"


def gh_api(path, jq=None):
    """`gh api <path>` -> parsed JSON (or the raw --jq string), or None.

    gh and not urllib. An unauthenticated api.github.com call from this
    network answers 403 immediately: the 60/hour anonymous budget is
    keyed on the corporate NAT address and is already spent by everyone
    else behind the same proxy. A tokenless fallback would never once
    succeed, so it would only disguise the reason every row said "?".

    The retry is for the ROCm org, which refuses classic PATs outright:

        `ROCm` forbids access via a personal access token (classic).

    gh prefers $GITHUB_TOKEN over hosts.yml, so `gh auth switch` does
    not help - the variable has to leave the child environment, which
    drops gh back to its configured account. Detected from the message
    rather than hardcoded per repo, because the policy is the org's to
    change and because a GitHub runner has no hosts.yml to fall back
    to: there the Actions token is an App installation token, which the
    policy accepts, and this retry never fires.
    """
    cmd = ["gh", "api", path]
    if jq:
        cmd += ["--jq", jq]
    for drop_token in (False, True):
        env = dict(os.environ)
        if drop_token:
            env.pop("GITHUB_TOKEN", None)
            env.pop("GH_TOKEN", None)
        try:
            p = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=30, env=env)
        except (OSError, subprocess.SubprocessError) as exc:
            return None, str(exc)
        if p.returncode == 0:
            body = p.stdout.strip()
            if not body:
                return None, "empty response"
            if jq:
                return body, None
            try:
                return json.loads(body), None
            except ValueError as exc:
                return None, str(exc)
        if CLASSIC_PAT not in p.stderr and not drop_token:
            break
    detail = (p.stderr or p.stdout).strip().splitlines()
    return None, detail[0] if detail else "gh api failed"


def gh_latest(repo):
    """The newest real release tag of a GitHub repo, or None.

    /releases/latest, never /tags: the tags endpoint lists in creation
    order and pytorch/pytorch's first page is CI bookmarks -
    viable/strict/1793287369 and friends. /releases/latest already
    excludes drafts and prereleases, which covers CuPy's rc tags and
    UCX's -rc2 tags because those repos flag them honestly.

    The repos in STRICT_SEMVER_REPOS do not flag them honestly, so they
    get the full list and a shape filter instead.
    """
    if repo in STRICT_SEMVER_REPOS:
        jq = ('[.[]|select(.prerelease==false and .draft==false)'
              '|.tag_name|select(test("%s"))][0]' % SEMVER)
        return gh_api("repos/%s/releases?per_page=100" % repo, jq)
    return gh_api("repos/%s/releases/latest" % repo, ".tag_name")


def gh_file(repo, path, ref):
    """A text file from a repo at a ref, decoded, or None.

    The contents API base64-encodes, and --jq .content hands back that
    encoding rather than the file.
    """
    url = "repos/%s/contents/%s?ref=%s" % (repo, path, ref)
    raw, err = gh_api(url, ".content")
    if raw is None:
        return None, err
    try:
        return base64.b64decode(raw).decode().strip(), None
    except (ValueError, UnicodeDecodeError) as exc:
        return None, str(exc)


def hub_latest(image, flavour):
    """The newest tag of a Docker Hub image carrying `flavour`.

    ROCM_VERSION *is* a docker tag - "10.1.0-full", where "-full" is an
    image flavour that appears in no git tag anywhere. That is why the
    ROCm/ROCm releases feed is the wrong source and why the old
    workflow, which reduced it to "10.1", reported drift every week.

    Sorted by version rather than taken in last_updated order: a patch
    to an older series can be pushed after a newer one, and
    7.14.1-full landing after 10.1.0-full would otherwise read as an
    upgrade. The flavour comes from our own default rather than being
    hardcoded, so publishing a "-base" variant first cannot make us
    chase a tag we cannot use.
    """
    url = ("https://hub.docker.com/v2/repositories/%s/tags"
           "?page_size=100&ordering=last_updated" % image)
    try:
        with DIRECT.open(url, timeout=20) as r:
            results = json.load(r)["results"]
    except Exception as exc:                        # noqa: BLE001
        return None, str(exc)
    want = re.compile(r"^[0-9]+(\.[0-9]+)*-%s$" % re.escape(flavour))
    tags = [t["name"] for t in results
            if isinstance(t.get("name"), str) and want.match(t["name"])]
    if not tags:
        return None, "no %s tags matched" % flavour
    return max(tags, key=vkey), None


def zot_versions(registry, namespace, repo):
    """The distinct upstream versions published under a wheel repo.

    Read through wheelhouse.parse_tag so the tag grammar has one
    definition. Tags that parse to no version are dropped rather than
    shown: triton-wheel still carries pre-ARCH_TAG tags like
    10.1.0-full-gfx950, which have a ROCm version and no Triton one,
    and reporting those as "-" would read as "nothing published".
    """
    url = "http://%s/v2/%s/%s/tags/list" % (registry, namespace, repo)
    with DIRECT.open(url, timeout=15) as r:
        tags = json.load(r).get("tags") or []
    seen = []
    for tag in tags:
        parsed = wheelhouse.parse_tag(tag)
        if not parsed:
            continue
        version = parsed[0]
        if version in ("-", "") or version in seen:
            continue
        seen.append(version)
    return sorted(seen, key=vkey, reverse=True)


# ─── comparison ───────────────────────────────────────────────────

def vkey(s):
    """A sortable key for a version-ish string.

    Leading "v" and any trailing flavour are ignored, so "v2.15.0",
    "2.15.0" and "10.1.0-full" all reduce to the numbers that order
    them. Anything with no digits sorts first, which only happens for
    values that are never compared.
    """
    return tuple(int(p) for p in re.findall(r"[0-9]+", s or ""))


def normalise(value, how):
    """Bring an upstream answer into the space our default lives in."""
    if value is None:
        return None
    if how == "strip_v":
        return value[1:] if value.startswith("v") else value
    if how == "toml_channel":
        m = re.search(r'channel\s*=\s*"([^"]+)"', value)
        return m.group(1) if m else None
    return value


def status_of(var, upstream, default):
    """One of: pinned, ?, current, behind, ahead, differs.

    Never silently "current". String equality is wrong for four of the
    thirteen - PYTORCH_VERSION is "2.14.1" against a "v2.14.1" tag,
    ROCM_VERSION carries a flavour suffix, TRITON_REF is a sha - so
    both sides are normalised first and only then compared.
    """
    # Equality first, even for a deliberately-pinned row. "pinned"
    # explains why a row may legitimately differ; when it does not
    # differ there is nothing to explain, and saying "pinned" there
    # hides the one fact the reader wanted — UCX_REF happens to be on
    # upstream's latest today, and that is worth seeing.
    if upstream is not None and upstream == default:
        return "current"
    if var in PINNED:
        return "pinned"
    if upstream is None:
        return "?"
    up, cur = vkey(upstream), vkey(default)
    if up and cur and up != cur:
        return "behind" if up > cur else "ahead"
    return "differs"


# ─── gathering ────────────────────────────────────────────────────

def upstream_of(comp, defaults):
    """(latest, error) for one component, never raising."""
    kind, spec = comp["source"][0], comp["source"][1]
    if kind == "none":
        return None, None
    if kind == "gh":
        raw, err = gh_latest(spec)
        return normalise(raw, comp["norm"]), err
    if kind == "hub":
        # The flavour we actually run, taken from our own default.
        flavour = defaults.get(comp["var"], "").rsplit("-", 1)[-1]
        raw, err = hub_latest(spec, flavour or "full")
        return normalise(raw, comp["norm"]), err
    if kind == "pin":
        repo, path, ref_var, tmpl, shape = spec
        ref = tmpl.format(defaults.get(ref_var, ""))
        text, err = gh_file(repo, path, ref)
        if text is None:
            return None, err
        return normalise(text, "toml_channel" if shape == "toml_channel"
                         else comp["norm"]), None
    return None, "unknown source %r" % kind


def collect(defaults, registry, namespace, use_zot):
    """Every component's row, gathered concurrently.

    Threads because thirteen serial round-trips through a proxy is
    twenty seconds of nothing. Six at a time: the GitHub budget is
    ~5000/hour authenticated and this costs fifteen requests, so the
    cap is about being a good citizen of the shared NAT rather than
    about rate limits.
    """
    zot_error = None
    tags = {}
    if use_zot:
        repos = [c["wheel_repo"] for c in COMPONENTS if c["wheel_repo"]]
        try:
            with ThreadPoolExecutor(max_workers=6) as pool:
                got = pool.map(
                    lambda r: zot_versions(registry, namespace, r), repos)
                tags = dict(zip(repos, got))
        except Exception as exc:                    # noqa: BLE001
            # One message for the column, not one per row: the registry
            # being unreachable is a single fact about the network.
            zot_error = str(exc)
            tags = {}

    with ThreadPoolExecutor(max_workers=6) as pool:
        found = list(pool.map(lambda c: upstream_of(c, defaults), COMPONENTS))

    rows = []
    for comp, (upstream, err) in zip(COMPONENTS, found):
        default = defaults.get(comp["var"], "")
        # A wheel repo whose tag encodes some other variable cannot
        # answer "which versions of this do we have published".
        published = ([] if comp.get("tag_var")
                     else tags.get(comp["wheel_repo"]) or [])
        rows.append(dict(
            comp=comp,
            upstream=upstream,
            error=err,
            published=published,
            default=default,
            status=status_of(comp["var"], upstream, default),
        ))
    return rows, zot_error


# ─── report ───────────────────────────────────────────────────────

def fmt_published(versions, limit=3):
    if not versions:
        return "-"
    shown = ", ".join(versions[:limit])
    extra = len(versions) - limit
    return "%s +%d more" % (shown, extra) if extra > 0 else shown


SHA_RE = re.compile(r"^[0-9a-f]{20,}$")


def short(value):
    """A 40-character sha in a fixed-width column destroys the table.

    Abbreviated the way git does, and only for something that is
    actually a sha — a version string is short already and truncating
    one would be a lie.
    """
    if value and SHA_RE.match(value):
        return value[:12]
    return value or "-"


def print_report(rows, zot_error, use_zot):
    print("\n\033[1mVersions\033[0m  upstream latest, "
          "published wheels, our pins\n")
    print("  \033[2m%-18s %-16s %-26s %-16s %s\033[0m"
          % ("variable", "upstream", "published", "pinned", "status"))
    for r in rows:
        pub = "n/a" if (use_zot and zot_error) else fmt_published(
            r["published"])
        if not use_zot:
            pub = "-"
        print("  \033[36m%-18s\033[0m %-16s %-26s %-16s %s"
              % (r["comp"]["var"], short(r["upstream"]), pub,
                 short(r["default"]),
                 status_label(r["comp"]["var"], r["status"])))

    print("\n  \033[2mupstream for TRITON_* is what pytorch/pytorch pins "
          "at its release tag;\n  for RUST_VERSION, what vllm-project/vllm "
          "pins at its.\033[0m")
    for r in rows:
        tag_var = r["comp"].get("tag_var")
        if tag_var and use_zot:
            print("  \033[2mpublished is blank for %s: %s tags carry "
                  "%s, not %s.\033[0m"
                  % (r["comp"]["var"], r["comp"]["wheel_repo"], tag_var,
                     r["comp"]["var"]))
    if use_zot and zot_error:
        print("  \033[2mpublished: registry unreachable (%s)\033[0m"
              % zot_error.splitlines()[0][:60])
    summarise(rows)


def status_label(var, status):
    if status == "pinned":
        return "pinned (%s)" % PINNED[var]
    return status


def summarise(rows):
    behind = [r for r in rows if r["status"] == "behind"]
    unknown = [r for r in rows if r["status"] == "?"]
    odd = [r for r in rows if r["status"] in ("ahead", "differs")]
    if behind:
        print("\n  %d behind: %s" % (
            len(behind), ", ".join(r["comp"]["var"] for r in behind)))
        print("  Bump it in rocm-bake.hcl, then: make version-scrub")
    if odd:
        print("  %d not comparable: %s" % (
            len(odd), ", ".join("%s (%s)" % (r["comp"]["var"], r["status"])
                                for r in odd)))
    # A persistent "?" is the failure mode nobody notices, because it
    # is not "behind" and so files no issue. Name the rows and the
    # reason every time rather than letting them blend into the table.
    if unknown:
        print("  %d lookup(s) failed: %s" % (
            len(unknown), ", ".join(r["comp"]["var"] for r in unknown)))
        for r in unknown:
            err = r["error"]
            if isinstance(err, list):
                err = err[0] if err else "?"
            print("      %-18s %s" % (r["comp"]["var"], str(err)[:90]),
                  file=sys.stderr)
    if not behind and not unknown and not odd:
        print("\n  all %d pins current." % len(rows))


def markdown_report(rows, zot_error, use_zot):
    """The same rows as GFM, for the weekly issue body."""
    out = ["| Variable | Upstream | Published | Pinned | Status |",
           "| --- | --- | --- | --- | --- |"]
    for r in rows:
        if not use_zot:
            pub = "n/a"
        elif zot_error:
            pub = "n/a"
        else:
            pub = fmt_published(r["published"])
        out.append("| `%s` | %s | %s | `%s` | %s |" % (
            r["comp"]["var"], r["upstream"] or "-", pub,
            r["default"] or "-", status_label(r["comp"]["var"], r["status"])))
    unknown = [r["comp"]["var"] for r in rows if r["status"] == "?"]
    if unknown:
        out += ["", "Lookups that failed: %s." % ", ".join("`%s`" % u
                                                           for u in unknown)]
    out += ["",
            "`TRITON_VERSION` and `TRITON_REF` track what pytorch/pytorch "
            "pins at its release tag; `RUST_VERSION` tracks what "
            "vllm-project/vllm pins at its."]
    return "\n".join(out)


# ─── scrub ────────────────────────────────────────────────────────

def readme_table(defaults):
    """The README's version table. Our own pins only - never upstream.

    A live "latest upstream" column could not be checked: it goes stale
    the moment someone else ships, so the gate would fail on unrelated
    pull requests and would be turned off within a month. Restricted to
    rocm-bake.hcl, the table is a pure function of a file in the same
    commit, which is exactly what makes it gateable the way
    check-defaults.py gates the Makefile.

    Published wheel tags are absent for a related reason: the registry
    is a tailnet name, so every reader on GitHub would be looking at
    claims about a host they cannot resolve.
    """
    rows = ["| Component | Upstream | Bake variable | Pinned |",
            "| --- | --- | --- | --- |"]
    for c in COMPONENTS:
        if not c["readme"]:
            continue
        where = ("[%s](%s)" % (c["label"], c["url"]) if c["url"]
                 else "&mdash;")
        rows.append("| %s | %s | `%s` | `%s` |"
                    % (c["name"], where, c["var"],
                       defaults.get(c["var"], "?")))
    return "\n".join(rows)


def bake_table(defaults):
    """The versions table on docs/reference/bake-variables.md."""
    rows = ["| Variable | Default |", "| --- | --- |"]
    for var in BAKE_TABLE_VARS:
        note = BAKE_NOTES.get(var)
        value = note if note else "`%s`" % defaults.get(var, "?")
        rows.append("| `%s` | %s |" % (var, value))
    return "\n".join(rows)


GENERATORS = {"VERSIONS": readme_table, "BAKE_VERSIONS": bake_table}


def splice(text, marker, body):
    """Replace what sits between <!-- BEGIN X --> and <!-- END X -->.

    Markers rather than owning the whole file: these are hand-written
    prose documents with one generated region each, and a generator
    that owned the file would make every future prose edit a generator
    edit.

    The blank lines around the body are load-bearing. Python-Markdown
    only treats raw HTML as a block when it starts one, so a table
    opening on the line directly below the comment risks the tables
    extension never seeing a table. GitHub's sanitiser drops comment
    nodes outright, so both renderers show the table and neither shows
    the marker.
    """
    pat = re.compile(
        r"(<!-- BEGIN %s -->\n)(.*?)(<!-- END %s -->)" % (marker, marker),
        re.S)
    m = pat.search(text)
    if not m:
        return None, None
    # The END marker is inside the match, so the replacement has to put
    # it back. Dropping it left the file with one unterminated block
    # and the second scrub then had nothing to anchor on.
    rebuilt = "%s\n%s\n\n%s" % (m.group(1), body, m.group(3))
    return pat.sub(lambda _: rebuilt, text), m.group(2).strip()


def scrub(defaults, write):
    """Regenerate every marker block. Returns the number that drifted."""
    drifted = 0
    for relpath, marker in SCRUB_TARGETS:
        path = ROOT / relpath
        text = path.read_text()
        body = GENERATORS[marker](defaults)
        updated, current = splice(text, marker, body)
        if updated is None:
            print("%s: no <!-- BEGIN %s --> marker" % (relpath, marker),
                  file=sys.stderr)
            return -1
        if current == body:
            continue
        drifted += 1
        if write:
            path.write_text(updated)
            print("  regenerated %s" % relpath)
        else:
            report_drift(relpath, marker, current, body)
    return drifted


def report_drift(relpath, marker, current, wanted):
    """Name the variables that moved, not just "files differ".

    The contributor who bumped VLLM_REF and got a red X needs to see
    that the failure is about their own change and is one command away.
    """
    print("%s: the generated %s table is out of date.\n" % (relpath, marker),
          file=sys.stderr)
    cell = re.compile(r"^\| `?([A-Za-z0-9_ ]+)`? \|.*`([^`]*)` \|$")
    was = {}
    for line in current.splitlines():
        m = cell.match(line.strip())
        if m:
            was[m.group(1).strip()] = m.group(2)
    for line in wanted.splitlines():
        m = cell.match(line.strip())
        if not m:
            continue
        key, now = m.group(1).strip(), m.group(2)
        if was.get(key, now) != now:
            print("  %-18s table says %s, rocm-bake.hcl says %s"
                  % (key, was[key], now), file=sys.stderr)
    print("\nrocm-bake.hcl is the single source for every version a build\n"
          "reads. These tables are generated from it.\n\n"
          "Run:  make version-scrub\nand commit the result.\n",
          file=sys.stderr)


# ─── entry ────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--markdown", action="store_true",
                    help="emit the report as a markdown table")
    ap.add_argument("--no-zot", action="store_true",
                    help="skip the published-wheels column")
    ap.add_argument("--registry", default=None,
                    help="registry host (default: bake's REGISTRY)")
    ap.add_argument("--namespace", default=None,
                    help="registry namespace (default: REGISTRY_NAME)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--scrub", action="store_true",
                      help="rewrite the generated tables in place")
    mode.add_argument("--scrub-check", action="store_true",
                      help="report drift in those tables, write nothing")
    args = ap.parse_args()

    defaults = bake_defaults()

    if args.scrub or args.scrub_check:
        if args.markdown or args.no_zot or args.registry or args.namespace:
            print("--scrub reads rocm-bake.hcl only; it takes no network "
                  "options", file=sys.stderr)
            return 2
        drifted = scrub(defaults, write=args.scrub)
        if drifted < 0:
            return 2
        if args.scrub:
            if not drifted:
                print("  version tables already current")
            return 0
        return 1 if drifted else 0

    # gh is the only way onto api.github.com from here, so say so once
    # rather than printing thirteen "?" rows and leaving the reason to
    # be guessed.
    if shutil.which("gh") is None:
        print("gh not found: version-check needs the GitHub CLI.",
              file=sys.stderr)
        return 0

    registry = args.registry or os.environ.get("REGISTRY") \
        or defaults.get("REGISTRY", "")
    namespace = args.namespace or os.environ.get("REGISTRY_NAME") \
        or defaults.get("REGISTRY_NAME", "")
    use_zot = not args.no_zot and bool(registry and namespace)

    rows, zot_error = collect(defaults, registry, namespace, use_zot)

    if args.markdown:
        print(markdown_report(rows, zot_error, use_zot))
    else:
        print_report(rows, zot_error, use_zot)
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
