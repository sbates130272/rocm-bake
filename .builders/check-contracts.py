#!/usr/bin/env python3
"""check-contracts.py - fail if two files that must agree have drifted.

check-defaults.py guards the Makefile/bake boundary. This guards the
others: the places where one file produces a string and a different
file parses it, with nothing but a comment connecting them. Each of
these has the same failure mode — the producer changes, the consumer
silently matches nothing, and the result is a report that renders
perfectly and says "0" where it should say something.

No registry, no GPU, no builders, no sudo. It only reads files, so it
runs on a bare CI runner in under a second.

Checks:
  1. nginx log_format in deploy-webdav.sh parses with perfreport's
     SCCACHE_RE.
  2. balance.sh's placement echo matches perfreport's placement regex.
  3. perfsample's DEFAULT_NODES and perfreport's SERIES name the same
     builders.
  4. perfsample writes every sample field perfreport reads.
  5. The schedulers name their work by bake group, through depgraph.py,
     rather than keeping a hand-written copy of it.
  6. Every target they can be asked for has a build-* Makefile rule,
     via the same mk_name mapping bench.sh uses.
  7. target-costs covers every wheel, so no target is scheduled as
     though it were free.
  8. versioncheck.py's wheel_repo names are real artifacts, i.e. they
     are in bake's `wheels` group.
  9. Every manifest loads, every build node in one has a link speed,
     and the default manifest agrees with rocm-bake.hcl about where
     the registry and the compiler cache are.
"""
import importlib.util
import re
import shutil
import tempfile
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAIL = []


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fail(check, msg):
    FAIL.append(f"{check}: {msg}")


def read(p):
    return (ROOT / p).read_text(errors="replace")


# ── 1. nginx log_format ↔ SCCACHE_RE ──────────────────────────────
def check_sccache_format(report):
    src = read(".builders/deploy-webdav.sh")
    m = re.search(r"log_format\s+sccache\s+((?:'[^']*'\s*)+);", src)
    if not m:
        return fail("sccache-format",
                    "no `log_format sccache` in deploy-webdav.sh")
    fmt = " ".join(re.findall(r"'([^']*)'", m.group(1)))
    fmt = fmt.replace("\\$", "$")
    sample = {
        "time_iso8601": "2026-10-29T12:16:49-06:00",
        "remote_addr": "127.0.0.1", "request_method": "PUT",
        "uri": "/rocm-pytorch/ab/cd/obj", "status": "201",
        "request_length": "1048705", "body_bytes_sent": "0",
        "request_time": "0.213",
    }
    line = re.sub(r"\$(\w+)", lambda g: sample.get(g.group(1), "x"), fmt)
    line = re.sub(r"\s+", " ", line).strip()
    hit = report.SCCACHE_RE.match(line)
    if not hit:
        return fail("sccache-format",
                    f"perfreport.SCCACHE_RE does not match a line nginx "
                    f"would emit:\n    {line}")
    for field, want in (("req", "1048705"), ("secs", "0.213"),
                        ("method", "PUT")):
        if hit.group(field) != want:
            fail("sccache-format",
                 f"{field}={hit.group(field)!r}, expected {want!r}")


# ── 2. balance.sh placement echo ↔ perfreport regex ───────────────
def check_placement(report):
    """Both scheduling formats must parse.

    The balancer emits "<target> -> <node>" in stage mode and
    "<node>: starting <target>" in queue mode. The first was the only
    one parsed when the second was added, and three callers then
    silently attributed every target to "unknown" or captured no
    traces at all — none of them errored.
    """
    src = read(".builders/balance.sh")
    cases = []

    m = re.search(r'echo\s+"(\s+\$target -> \$node[^"]*)"', src)
    if not m:
        fail("placement", "balance.sh no longer echoes `$target -> $node`")
    else:
        cases.append(m.group(1).replace("$target", "pytorch-wheel")
                               .replace("$node", "snoc-think"))

    m = re.search(r'echo\s+"(\s+\$node: starting \$t)"', src)
    if not m:
        fail("placement", "balance.sh no longer echoes `$node: starting $t`")
    else:
        cases.append(m.group(1).replace("$node", "snoc-think")
                               .replace("$t", "pytorch-wheel"))

    for line in cases:
        tmp = Path(tempfile.mkdtemp())
        (tmp / "balance.log").write_text(line + "\n")
        got = report.read_placement(tmp)
        shutil.rmtree(tmp, ignore_errors=True)
        if got.get("pytorch-wheel") != "snoc-think":
            fail("placement",
                 f"read_placement does not parse balance.sh's line:\n"
                 f"    {line!r} -> {got!r}")


# ── 3 & 4. perfsample ↔ perfreport ────────────────────────────────
def check_sample_shape(report, sample):
    if set(sample.DEFAULT_NODES) != set(report.SERIES):
        fail("builders",
             f"perfsample.DEFAULT_NODES {sorted(sample.DEFAULT_NODES)} != "
             f"perfreport.SERIES {sorted(report.SERIES)}; colour would stop "
             f"following the builder")
    # Fields perfreport reads off a sample row, against what the
    # sampler's writer actually emits.
    # Any quoted name in the writer, not just `"key":` literals: the
    # sampler builds rows with row["cpu_busy_pct"] = ... assignments
    # and (src, dst) tuples, so a dict-key-only scan reported three
    # fields it writes every tick as missing.
    writer = read(".builders/perfsample.py")
    emitted = set(re.findall(r'"(\w+)"', writer))
    needed = {"t", "ts", "builder", "cpu_busy_pct", "mem_available_bytes",
              "mem_total_bytes", "net_rx_bps", "interval_seconds"}
    missing = needed - emitted
    if missing:
        fail("sample-shape",
             f"perfreport reads fields perfsample never writes: "
             f"{sorted(missing)}")


# ── 7. target-costs ↔ bake wheels group ↔ balance.sh NODES ────────
def check_costs():
    """Every scheduled target and node must have a cost.

    balance.sh looks these up with awk and falls back to `build=1` on a
    miss, so a wheel absent from the table costs one second: LPT sorts
    it last, earliest-finish drops it on whichever node is free, and a
    multi-GB export can land on the node behind WiFi. The schedule
    silently reverts to what it was before the network term existed,
    and nothing anywhere errors — which is the whole reason this file
    exists.
    """
    path = ROOT / ".builders/target-costs"
    if not path.exists():
        return fail("costs", "no .builders/target-costs; balance.sh --queue "
                             "would cost every target at 1s")
    seen = {"build": set(), "cache": set(), "netmb": set()}
    for n, line in enumerate(read(".builders/target-costs").splitlines(), 1):
        line = line.split("#")[0].strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) != 3 or fields[0] not in seen:
            fail("costs", f"target-costs line {n} is not "
                          f"`build|cache|netmb <name> <number>`: {line!r}")
            continue
        try:
            float(fields[2])
        except ValueError:
            fail("costs", f"target-costs line {n} value is not a number: "
                          f"{line!r}")
            continue
        seen[fields[0]].add(fields[1])

    bake = read("rocm-bake.hcl")
    m = re.search(r'group\s+"wheels"\s*\{(.*?)\}', bake, re.S)
    wheels = set(re.findall(r'"([a-z0-9-]+)"', m.group(1))) if m else set()
    # `build` must cover everything balance.sh can schedule, not just
    # the wheels. It defaults TARGETS to bake's `default` group, which
    # includes four image targets — and all four were missing until
    # 2026-10-30. cost_of returned 1 for each, so `pytorch`, the most
    # expensive target in the graph, sorted last and was handed the
    # weakest node. A missing row and a one-second target look
    # identical to awk, which is exactly why this has to be asserted.
    m = re.search(r'group\s+"default"\s*\{(.*?)\}', bake, re.S)
    schedulable = set(re.findall(r'"([a-z0-9-]+)"', m.group(1))) if m else set()
    missing = schedulable - seen["build"]
    if missing:
        fail("costs", f"no `build` line for {sorted(missing)}; cost_of "
                      f"falls back to 1s, so LPT sorts them last and "
                      f"earliest-finish hands them the weakest free node")
    extra = seen["build"] - schedulable
    if extra:
        fail("costs", f"`build` lines for targets not in bake's default "
                      f"group: {sorted(extra)}")

    # `cache` stays scoped to the wheels. The network term needs a
    # measured export size and only the wheels have one; inventing
    # figures for the image targets to satisfy a checker would be
    # worse than letting cost_of fall back to the build term, which is
    # what it does when the cache row is absent.
    missing = wheels - seen["cache"]
    if missing:
        fail("costs", f"no `cache` line for {sorted(missing)}; their "
                      f"exports would be costed as free and cache-heavy "
                      f"targets would pile onto whichever node is slowest")
    extra = seen["cache"] - wheels
    if extra:
        fail("costs", f"`cache` lines for targets not in bake's wheels "
                      f"group: {sorted(extra)}")

    # The per-node `netmb` rows moved to the manifests; target-costs
    # must not carry them any more, or there would be two answers and
    # awk would take whichever file it was pointed at.
    if seen["netmb"]:
        fail("costs", f"target-costs still has netmb rows for "
                      f"{sorted(seen['netmb'])}; each node's upload "
                      f"throughput is `link_mbps:` in the fleet manifest now")


# ── 8. BUILDKIT_BUILD_NAME uniqueness ─────────────────────────────
def check_build_names():
    """Two targets must never share a build record name.

    buildx history is keyed by that name, so a shared one gives both
    targets a single record. perftrace.py then fetches the same record
    for each and the report draws one target's timeline under both
    names, while build-status cannot say which of the two a row is.
    pytorch/pytorch-wheel and vllm/vllm-wheel did exactly this until
    2026-10-30 — on run 20261030T182519Z, trace-pytorch.json and
    trace-pytorch-wheel.json were byte-identical. It also made the
    `build pytorch` and `build vllm` rows in target-costs unmeasurable
    by direct observation.

    Shape matters too: history.py reads the arch from parts[-2] and the
    run id from parts[-1], so a name with fewer than four components
    silently degrades both columns to "-".
    """
    names = re.findall(r'BUILDKIT_BUILD_NAME\s*=\s*"([^"]+)"',
                       read("rocm-bake.hcl"))
    if not names:
        return fail("buildnames", "no BUILDKIT_BUILD_NAME in rocm-bake.hcl")

    seen = {}
    for raw in names:
        parts = raw.split("/")
        if len(parts) != 4:
            fail("buildnames",
                 f"{raw!r} is not <repo>/<image>/<arch>/<run-id>; "
                 f"history.py would lose its arch and run-id columns")
            continue
        key = (parts[1], parts[2])
        if key in seen:
            fail("buildnames",
                 f"two targets share the build record name "
                 f"{'/'.join(parts[:3])}/...; buildx history keys on it, "
                 f"so their traces and history rows are indistinguishable")
        seen[key] = raw


# ── 5 & 6. perf target set ↔ bake groups ↔ make rules ─────────────
def check_stages():
    """The schedulers must name their work by group, not by hand.

    balance.sh used to carry the dependency order as STAGE_1..STAGE_5
    and perfrun.sh its own three-stage copy of the wheels list. Both
    were duplicates of rocm-bake.hcl, and both could drift from it
    silently — which is how a gfx1250 run came to schedule vllm-wheel
    with no pytorch image in the graph at all.

    There is no longer a list to compare, so this asserts the
    indirection itself: each scheduler asks depgraph.py for a bake
    group rather than spelling one out.
    """
    bake = read("rocm-bake.hcl")
    m = re.search(r'group\s+"wheels"\s*\{(.*?)\}', bake, re.S)
    if not m:
        return fail("stages", "no `wheels` group in rocm-bake.hcl")
    wheels = set(re.findall(r'"([a-z0-9-]+)"', m.group(1)))

    run = read(".builders/perfrun.sh")
    if "depgraph.py\" --group wheels" not in run and \
            "depgraph.py --group wheels" not in run:
        fail("stages",
             "perfrun.sh no longer derives its targets from bake's "
             "`wheels` group; a hand-written list can drift from it")
    # pytorch is not a wheel, so the group alone would omit the image
    # every wheel builds FROM — and the most expensive target measured.
    if not re.search(r'PERF_TARGETS=.*\bpytorch\b', run):
        fail("stages",
             "perfrun.sh dropped `pytorch` from PERF_TARGETS; perf runs "
             "would measure only the wheels and could schedule them "
             "against an image no run builds")

    bal = read(".builders/balance.sh")
    if "--group default" not in bal:
        fail("stages",
             "balance.sh no longer defaults TARGETS to bake's `default` "
             "group")
    if re.search(r'^STAGE_[0-9]', bal, re.M):
        fail("stages",
             "balance.sh has STAGE_* definitions again; ordering belongs "
             "to the bake graph, read by depgraph.py")

    # bench.sh dispatches through `make build-<mk_name>`; every target
    # a scheduler can be asked for needs that rule to exist.
    bench = read(".builders/bench.sh")
    mapping = dict(re.findall(r"^\s*([a-z0-9-]+)\)\s*echo\s+([a-z0-9-]+)\s*;;",
                              bench, re.M))
    makefile = read("Makefile")
    for target in sorted(wheels | {"pytorch", "pytorch-base"}):
        rule = mapping.get(target, target)
        if not re.search(rf"^build-{re.escape(rule)}:", makefile, re.M):
            fail("stages",
                 f"no `build-{rule}:` rule for bake target {target!r} — "
                 f"bench.sh cold {target} would fail")


# ── 7. versioncheck's wheel repos ↔ bake's `wheels` group ────────
def check_version_wheel_repos():
    """versioncheck.py names a wheel repository that does not exist.

    A third copy of the artifact list, after the `wheels` group and
    WHEEL_REPOS — one builds them, one reports what is published, one
    reports which upstream version each came from. check-defaults.py
    already ties the first two together; this is the third, and it has
    the failure mode every check in this file guards against: a rename
    on the bake side leaves versioncheck's published column silently
    empty, and the table still renders perfectly.

    A subset test, not equality. UCX is compiled inside the nixl wheel
    and ships no artifact of its own, and several components are not
    wheels at all, so `wheel_repo=None` is the common case by design.
    """
    bake = read("rocm-bake.hcl")
    m = re.search(r'^group\s+"wheels"\s*\{(.*?)\n\}', bake, re.M | re.S)
    if not m:
        return fail("version-wheels", "no `wheels` group in rocm-bake.hcl")
    wheels = set(re.findall(r'"([A-Za-z0-9_-]+)"', m.group(1)))
    named = set(re.findall(r'wheel_repo="([a-z0-9-]+)"',
                           read(".builders/versioncheck.py")))
    stray = sorted(named - wheels)
    if stray:
        fail("version-wheels",
             f"versioncheck.py names wheel repos that are not in the "
             f"`wheels` group: {', '.join(stray)}.\n"
             f"    Its published column would be silently empty for "
             f"them.\n"
             f"    The group has: {', '.join(sorted(wheels))}")


# ── 9. the manifests ↔ everything that reads them ────────────────
def check_manifests():
    """Every committed manifest must load, and say enough to schedule.

    fleet.py validates structure on load — a node with no host, a
    capability that is a typo, a registry pointed at a node that does
    not host one. What it cannot judge is whether a manifest is
    *useful*, which is what this adds: a build node with no
    `link_mbps:` is costed as having an infinitely fast link, so
    balance.sh charges its cache export nothing and a 6 GB export can
    land on the slowest wire in the fleet. That is precisely the
    regression the netmb term was added to fix, and it would be
    silent.

    Also: the default manifest and rocm-bake.hcl must agree on where
    the registry and the compiler cache are. The Makefile takes those
    from the manifest and exports them, so a bare `docker buildx bake`
    driven without make is the one caller left reading the hcl
    defaults — and it would quietly publish somewhere else.
    """
    fleet = load("fleet", ".builders/fleet.py")
    manifests = sorted((ROOT / "manifests").glob("*.yml"))
    if not manifests:
        return fail("manifests", "no manifests/*.yml")

    for path in manifests:
        try:
            data = fleet.load(str(path))
        except fleet.FleetError as exc:
            fail("manifests", f"{path.name} does not load: {exc}")
            continue
        for name in fleet.nodes(data, "build"):
            node = fleet.node_map(data)[name]
            if "link_mbps" not in node:
                fail("manifests",
                     f"{path.name}: build node {name!r} has no link_mbps; "
                     f"its cache exports would be costed as free")

    bake = read("rocm-bake.hcl")

    def bake_default(var):
        m = re.search(rf'variable\s+"{var}"\s*\{{\s*default\s*=\s*"([^"]*)"',
                      bake)
        return m.group(1) if m else None

    default = fleet.load(fleet.DEFAULT_FLEET)
    pairs = [
        ("REGISTRY", fleet.registry(default)),
        ("SCCACHE_WEBDAV_HOST", fleet.cache_host(default)),
        ("SCCACHE_WEBDAV_PORT", str(default["cache"]["port"])),
    ]
    for var, want in pairs:
        got = bake_default(var)
        if got != want:
            fail("manifests",
                 f"rocm-bake.hcl's {var} default is {got!r} but "
                 f"manifests/{fleet.DEFAULT_FLEET}.yml says {want!r}; a bake "
                 f"run without make would use the first")


# ── 10. the buildkit pin agrees across both builder creators ─────
BUILDKIT_PIN_RE = re.compile(
    r'BUILDKIT_IMAGE="\$\{BUILDKIT_IMAGE:-([^}"]+)\}"')

BUILDKIT_PIN_FILES = (".builders/nightly.sh", ".builders/builder-create.sh")


def check_buildkit_pin():
    """The fleet and the AWS lane run different buildkit versions.

    Two scripts create builders -- nightly.sh for the ephemeral
    CodeBuild one, builder-create.sh for the fleet -- and each pins the
    buildkit image itself, because neither can reach the other's
    machines. Nothing makes them agree.

    The failure is quiet and expensive. buildx's default,
    moby/buildkit:buildx-stable-1, was v0.34.2 on 2026-11-16, which
    carries moby/buildkit#6418: with several cache-from manifests
    describing one stage, only the importer that answers first stays
    queryable and the rest of the stage rebuilds. Bumping one file and
    not the other leaves half the builds on the broken version, and the
    only symptom is a cache hit rate nobody is watching closely enough.

    A digest, not a tag: both must name the same immutable image, so a
    tag quietly re-pointed upstream cannot put the two out of step
    while still reading the same.
    """
    pins = {}
    for path in BUILDKIT_PIN_FILES:
        m = BUILDKIT_PIN_RE.search(read(path))
        if not m:
            return fail("buildkit-pin",
                        f"{path} has no BUILDKIT_IMAGE default; the "
                        f"builder it creates would take buildx's, which "
                        f"is the version moby/buildkit#6418 affects")
        pins[path] = m.group(1)
    if len(set(pins.values())) > 1:
        return fail("buildkit-pin",
                    "the two builder creators pin different buildkit "
                    "images:\n    " + "\n    ".join(
                        f"{p}: {v}" for p, v in pins.items()))
    if "@sha256:" not in next(iter(pins.values())):
        fail("buildkit-pin",
             f"the buildkit pin is a bare tag: {next(iter(pins.values()))}\n"
             f"    Tags are mutable; pin the digest so a moved tag "
             f"cannot reintroduce #6418 silently.")


# ── 11. the sccache checksum agrees across every Dockerfile ─────
SCCACHE_SHA_RE = re.compile(r'^ARG SCCACHE_SHA256=([0-9a-f]{64})$', re.M)


def check_sccache_sha():
    """One sccache tarball, five hardcoded hashes, and a version in bake.

    SCCACHE_VERSION lives in rocm-bake.hcl; the sha256 of the tarball
    that version names is an ARG in five Dockerfiles, which bake does
    not pass and version-scrub does not regenerate. Nothing tied the
    two together, and the weekly version check moves the version on its
    own.

    That combination already shipped: PR #62 bumped SCCACHE_VERSION
    0.19.0 -> 0.20.0 and left all five hashes on 0.19.0's tarball.
    Every ADD --checksum would have failed on mismatch -- loudly, but
    only once the fleet was occupied building, and in five files one at
    a time.

    This cannot verify the hash is right for the version without the
    network, which this check does not have. It asserts the cheaper
    half: all five agree. A bump that edits some and not others is the
    shape the failure took, and it is caught before a builder starts.
    The authoritative hash is published beside the asset:

        https://github.com/mozilla/sccache/releases/download/\
v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz.sha256
    """
    found = {}
    for path in sorted(ROOT.glob("docker/Dockerfile.*")):
        for m in SCCACHE_SHA_RE.finditer(read(path.relative_to(ROOT))):
            found.setdefault(m.group(1), []).append(path.name)
    if not found:
        return fail("sccache-sha",
                    "no ARG SCCACHE_SHA256 found in any Dockerfile; this "
                    "check is reading the wrong thing")
    if len(found) > 1:
        fail("sccache-sha",
             "the sccache tarball checksum differs between Dockerfiles:\n    "
             + "\n    ".join(f"{sha}: {', '.join(files)}"
                             for sha, files in sorted(found.items()))
             + "\n    One tarball has one hash. A partial bump of "
               "SCCACHE_VERSION is the usual cause.")


# ── 12. CACHE_REPOS ↔ every cache-to ref in the bake file ────────
def check_cache_repos():
    """The Makefile's cache repo list must name every cache bake writes.

    CACHE_REPOS already says "Keep in step with the cache-to refs in
    rocm-bake.hcl", and nothing made that true. It drifted three times:
    pytorch-src-cache was never added, and neither was vllm-emu-cache
    nor vllm-emu-capture-cache when the emulator lane landed.

    What a missing entry costs is small but entirely silent. `make
    image-sizes` and `image-data` report layer sizes per cache repo, so
    an absent one simply does not appear in a table whose whole job is
    showing where the cache got large; `make clean-cache` leaves its
    local images behind. Nothing errors, and the repo is still written
    to on every build.

    Only the direction that can be wrong is checked. A name in
    CACHE_REPOS that bake no longer writes is harmless -- it reports an
    empty repo and removes nothing -- and insisting on exact equality
    would fail the moment a target is retired, for no benefit.
    """
    bake = read("rocm-bake.hcl")
    refs = set(re.findall(r'cache_own\("([a-z0-9-]+)"', bake))
    refs |= set(re.findall(
        r'ref=\$\{REGISTRY\}/\$\{REGISTRY_NAME\}/([a-z0-9-]+):', bake))
    refs = {r for r in refs if r.endswith("-cache")}
    if not refs:
        return fail("cache-repos",
                    "no cache-to refs found in rocm-bake.hcl; this check "
                    "is reading the wrong thing")

    m = re.search(r'^CACHE_REPOS \?=(.*?)(?=\n[A-Z#\n])', read("Makefile"),
                  re.S | re.M)
    if not m:
        return fail("cache-repos", "no CACHE_REPOS in the Makefile")
    listed = set(m.group(1).replace("\\", "").split())

    missing = refs - listed
    if missing:
        fail("cache-repos",
             f"bake writes a layer cache to {sorted(missing)}, which "
             f"CACHE_REPOS does not name.\n"
             f"    Those repos are invisible to `make image-sizes` and "
             f"are left behind by `make clean-cache`.")


def check_cache_budget():
    """A manifest budget must reach the deployer, and the prune must bite.

    Three links, none of which fails loudly on its own. fleet.py has to
    export cache.budget_gb; deploy-webdav.sh has to read that variable;
    and the prune it installs has to be wired to a timer. Break any one
    and the store simply keeps growing -- which is the state this whole
    mechanism exists to end, and which looks identical to working until
    the disk is full months later.

    The failure is slow and silent, so it gets a contract rather than a
    comment. Checked here and not in the role because the role only
    copies the script over and runs it; by the time Ansible could
    notice, the budget has already been dropped on the floor.
    """
    fleet = read(".builders/fleet.py")
    if "FLEET_CACHE_BUDGET_GB" not in fleet:
        return fail("cache-budget",
                    "fleet.py does not export FLEET_CACHE_BUDGET_GB, so "
                    "cache.budget_gb in a manifest reaches nothing")

    dav = read(".builders/deploy-webdav.sh")
    if "FLEET_CACHE_BUDGET_GB" not in dav:
        return fail("cache-budget",
                    "deploy-webdav.sh never reads FLEET_CACHE_BUDGET_GB; "
                    "the manifest's budget would be ignored and the store "
                    "would grow unbounded")

    for unit in ("sccache-prune.service", "sccache-prune.timer"):
        if unit not in dav:
            fail("cache-budget",
                 f"deploy-webdav.sh installs no {unit}; a prune script "
                 f"nothing schedules never runs")

    if "systemctl enable --now sccache-prune.timer" not in dav:
        fail("cache-budget",
             "deploy-webdav.sh writes sccache-prune.timer but never "
             "enables it; the store keeps growing")

    # An LRU keyed on mtime would evict by compile date rather than by
    # last use, throwing away objects a current build still reads while
    # keeping a dead compiler generation that happens to be newer.
    if "-printf '%A@" not in dav:
        fail("cache-budget",
             "the prune in deploy-webdav.sh does not sort by atime "
             "(%A@); eviction would not be least-recently-used")


def nightly_jobs():
    """{job: body} for .github/workflows/nightly.yml, without a parser.

    Stdlib only, like the rest of this file: the lint job that runs it
    installs nothing, and pulling PyYAML in to read one key would make
    this check the reason the gate needs a dependency. A job is a
    two-space key at the top of `jobs:`; its body is everything
    indented past that until the next one.
    """
    text = read(".github/workflows/nightly.yml")
    body = text[text.index("\njobs:\n"):]
    jobs, name, lines = {}, None, []
    for line in body.splitlines():
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            if name:
                jobs[name] = "\n".join(lines)
            name, lines = m.group(1), []
        elif name is not None:
            lines.append(line)
    if name:
        jobs[name] = "\n".join(lines)
    return jobs


def needs_of(body):
    """The `needs:` of one job body, flow or block form, as a list."""
    m = re.search(r"^    needs:\s*(.*)$", body, re.M)
    if not m:
        return []
    value = m.group(1).strip()
    if value.startswith("["):
        return [v.strip() for v in value.strip("[]").split(",") if v.strip()]
    if value:
        return [value]
    return re.findall(r"^      - (\S+)$", body, re.M)


def check_nightly_chain():
    """nightly.yml names every architecture the Makefile builds, in a chain.

    The architectures are separate jobs linked by `needs`, not a
    matrix, and that is forced: a matrix announces every leg at once,
    four `workflow_job.queued` webhooks arrive at CodeBuild in the same
    second, and the account allows one build running plus one queued.
    The rest are refused with "Cannot have more than 1 builds in queue
    for the account" and never retried, so those architectures wait for
    a runner that is not coming. Measured 2026-11-21; the header of
    nightly-build.yml has it in full.

    The cost of a chain is that it cannot be generated from another
    job's output -- GitHub fixes the job graph before anything runs --
    so the names are written out, and nothing but this stops them
    drifting from ARCHES. An architecture missing from the chain is
    never built by the weekly and never published, silently: the
    `arches` job still lists it, and the publish matrix still has a leg
    for it, which then finds no wheels in ECR.
    """
    mk = re.search(r"^ARCHES\s*\?=\s*(.+)$", read("Makefile"), re.M)
    if not mk:
        return fail("nightly-chain", "no ARCHES in the Makefile")
    want = mk.group(1).split()

    jobs = nightly_jobs()
    chain = [n for n, b in jobs.items()
             if "uses: ./.github/workflows/nightly-build.yml" in b]
    if chain != want:
        return fail("nightly-chain",
                    f"nightly.yml builds {chain or '[]'}, the Makefile's "
                    f"ARCHES is {want}.\n    Add a link to the chain in "
                    f".github/workflows/nightly.yml, and name it in "
                    f"`needs` for `report` and `publish`.")

    # Each link waits on the one before it, which is the whole point.
    for n, arch in enumerate(chain):
        needs = needs_of(jobs[arch])
        if n and chain[n - 1] not in needs:
            fail("nightly-chain",
                 f"{arch} does not wait for {chain[n - 1]}: needs={needs}.\n"
                 f"    Two architectures would then ask CodeBuild for a "
                 f"runner at once, and one request would be refused.")
        if re.search(r"^    strategy:", jobs[arch], re.M):
            fail("nightly-chain",
                 f"{arch} has a `strategy`; a matrix announces its legs "
                 f"together, which is what the chain exists to avoid")

    for job in ("report", "publish"):
        missing = [a for a in chain if a not in needs_of(jobs.get(job, ""))]
        if missing:
            fail("nightly-chain",
                 f"`{job}` does not name {missing} in `needs`, so it "
                 f"would run before "
                 + ("they are" if len(missing) > 1 else "it is") + " built")


def _instructions(dockerfile):
    """Yield each Dockerfile instruction with its continuations joined."""
    cur = []
    for line in dockerfile.splitlines():
        cur.append(line)
        if not line.rstrip().endswith("\\"):
            yield "\n".join(cur)
            cur = []
    if cur:
        yield "\n".join(cur)


def check_max_jobs_shared():
    """No Dockerfile hand-rolls its own compile-job derivation.

    There were nine copies of that arithmetic, one per compiling
    Dockerfile, and they had drifted into nine variants: two names for
    the same variable, three subtracting a memory reserve and six not,
    one guarding against a zero divisor and eight not, two clamping to
    a ceiling and seven not.

    That is not a tidiness complaint. The variant without a reserve
    chose 45 concurrent compiles on a 48-core 91GB runner on
    2026-11-25 and took the host down -- `tail` could not allocate,
    the shell could not fork, and four nightlies died leaving no
    artifact and no log. The bug was present in seven files and fixed
    in one, which is exactly what nine copies buys you.

    So there is one copy, docker/max-jobs.sh, and this fails the build
    if a tenth appears. Two things are checked: nobody re-derives the
    count inline, and every file that calls the script also mounts it
    -- a call without the mount is a build that fails late, inside a
    RUN, rather than here.
    """
    hand_rolled = re.compile(r"awk[^\n]*MemAvailable[^\n]*per\b|jobs=\$\(nproc\)")
    mount = "source=docker/max-jobs.sh"

    for path in sorted(Path(ROOT, "docker").glob("Dockerfile.*")):
        rel = path.relative_to(ROOT)
        body = read(rel)

        for n, line in enumerate(body.splitlines(), 1):
            if hand_rolled.search(line):
                fail("max-jobs",
                     f"{rel}:{n} derives a job count inline.\n"
                     f"    Call docker/max-jobs.sh instead; it is the one "
                     f"copy, and its header says why.")

        # Per RUN, not per file: a call needs the mount on its own
        # instruction, and counting substrings over the whole file
        # gets this wrong -- the mount names the path twice and the
        # comments name it again.
        for instr in _instructions(body):
            if "sh /max-jobs.sh" in instr and mount not in instr:
                first = instr.split("\n", 1)[0][:60]
                fail("max-jobs",
                     f"{rel}: a RUN calls max-jobs.sh without mounting "
                     f"it.\n    {first}...\n"
                     f"    Add `--mount=type=bind,{mount},"
                     f"target=/max-jobs.sh` to that RUN.")


def check_flag_branches():
    """A boolean input's flag sits on the true branch of its expression.

    GitHub's `a && b || c` is not a ternary. && and || return an
    operand rather than a boolean, and the empty string is falsy, so
    `inputs.push && '' || '--no-push'` evaluates `true && ''` to '',
    which || discards for '--no-push'. The flag is then passed for
    every value of the input.

    Both forms read the same to a human and only one works, which is
    why this is checked rather than reviewed. Writing the flag on the
    true branch -- `!inputs.push && '--no-push' || ''` -- is safe
    because the flag is a non-empty string, so || is never reached
    when the condition holds.

    The 2026-11-24 outage was this: the run reported `push: true` in
    its own Inputs group, ran `--no-push`, exited green, and published
    nothing. `--skip-cold` carried the same inversion from the start,
    so a run asking for a cold build was always given a warm one.

    WHAT THIS DOES NOT CATCH. A silent `--no-push` has now happened
    twice by two mechanisms, and only the second has this shape. The
    first, over 2026-11-04..10, was `inputs.push == false` being true
    for a scheduled run, where the input is null rather than false --
    the flag was already on the true branch and the *condition* was
    wrong. Nothing structural distinguishes that from a correct
    condition, so catching it would mean evaluating the expression
    against each input value, which needs an evaluator for GitHub's
    expression language that this script has no business carrying.

    So this is a check for one known-shaped mistake, not a guarantee
    that the lane publishes. The guarantee, if one is wanted, is a
    post-run assertion that something reached the registry.
    """
    for path in sorted(Path(ROOT, ".github/workflows").glob("*.yml")):
        rel = path.relative_to(ROOT)
        for n, line in enumerate(read(rel).splitlines(), 1):
            m = re.search(
                r"\$\{\{\s*(?P<cond>[^}]*?)\s*&&\s*"
                r"(?P<a>'[^']*')\s*\|\|\s*(?P<b>'[^']*')\s*\}\}", line)
            if not m:
                continue
            # The dangerous shape is an empty true branch beside a
            # non-empty false branch: the true branch can never win.
            if m.group("a") == "''" and m.group("b") != "''":
                fail("flag-branches",
                     f"{rel}:{n} puts the empty string on the true "
                     f"branch, so {m.group('b')} is passed whatever "
                     f"`{m.group('cond')}` is.\n"
                     f"    Negate the condition and move the flag: "
                     f"${{{{ !({m.group('cond')}) && {m.group('b')} "
                     f"|| '' }}}}")


def main():
    report = load("perfreport", ".builders/perfreport.py")
    sample = load("perfsample", ".builders/perfsample.py")
    check_sccache_format(report)
    check_placement(report)
    check_sample_shape(report, sample)
    check_stages()
    check_build_names()
    check_costs()
    check_version_wheel_repos()
    check_manifests()
    check_buildkit_pin()
    check_sccache_sha()
    check_cache_repos()
    check_cache_budget()
    check_nightly_chain()
    check_flag_branches()
    check_max_jobs_shared()

    if FAIL:
        print("contract violations:", file=sys.stderr)
        for f in FAIL:
            print(f"  {f}", file=sys.stderr)
        return 1
    print("contracts ok: nginx log_format, balance placement, sample "
          "shape, perf stages, build-* rules, build-record names, "
          "target-costs, the fleet manifests, versioncheck's wheel "
          "repos, the buildkit pin, the sccache checksum, the cache "
          "repo list, the sccache store's budget and prune timer, "
          "the nightly's architecture chain, every "
          "workflow's flag branches and the shared compile-job "
          "derivation all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
