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
  7. target-costs covers every wheel and every default node, so no
     target is scheduled as though it were free.
  8. versioncheck.py's wheel_repo names are real artifacts, i.e. they
     are in bake's `wheels` group.
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

    hit = re.search(r'NODES="\$\{NODES:-([^}]*)\}"', read(".builders/balance.sh"))
    nodes = set(hit.group(1).split()) if hit else set()
    missing = nodes - seen["netmb"]
    if missing:
        fail("costs", f"no `netmb` line for {sorted(missing)}; their exports "
                      f"would be costed as free and cache-heavy targets "
                      f"would pile onto whichever is slowest")


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

    if FAIL:
        print("contract violations:", file=sys.stderr)
        for f in FAIL:
            print(f"  {f}", file=sys.stderr)
        return 1
    print("contracts ok: nginx log_format, balance placement, sample shape, "
          "perf stages, build-* rules, build-record names, target-costs and versioncheck's "
          "wheel repos all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
