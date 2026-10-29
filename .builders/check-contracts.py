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
  5. perfrun's default stages cover exactly bake's `wheels` group.
  6. Every target in those stages has a build-* Makefile rule, via the
     same mk_name mapping bench.sh uses.
  7. target-costs covers every wheel and every default node, so no
     target is scheduled as though it were free.
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
    for kind in ("build", "cache"):
        missing = wheels - seen[kind]
        if missing:
            fail("costs", f"no `{kind}` line for {sorted(missing)}; those "
                          f"targets would be scheduled as if free")
        extra = seen[kind] - wheels
        if extra:
            fail("costs", f"`{kind}` lines for targets not in bake's wheels "
                          f"group: {sorted(extra)}")

    hit = re.search(r'NODES="\$\{NODES:-([^}]*)\}"', read(".builders/balance.sh"))
    nodes = set(hit.group(1).split()) if hit else set()
    missing = nodes - seen["netmb"]
    if missing:
        fail("costs", f"no `netmb` line for {sorted(missing)}; their exports "
                      f"would be costed as free and cache-heavy targets "
                      f"would pile onto whichever is slowest")


# ── 5 & 6. perfrun stages ↔ bake wheels group ↔ make rules ────────
def check_stages():
    bake = read("rocm-bake.hcl")
    m = re.search(r'group\s+"wheels"\s*\{(.*?)\}', bake, re.S)
    if not m:
        return fail("stages", "no `wheels` group in rocm-bake.hcl")
    wheels = set(re.findall(r'"([a-z0-9-]+)"', m.group(1)))

    run = read(".builders/perfrun.sh")
    staged = set()
    for var in ("PERF_STAGE_A", "PERF_STAGE_B", "PERF_STAGE_C"):
        hit = re.search(rf'\$\{{{var}:-([^}}]*)\}}', run)
        if hit:
            staged |= set(hit.group(1).split())
    if staged != wheels:
        fail("stages",
             f"perfrun stages {sorted(staged)} != bake wheels group "
             f"{sorted(wheels)}; a perf run would skip or invent a target")

    # bench.sh dispatches through `make build-<mk_name>`; every target
    # it can be asked for needs that rule to exist.
    bench = read(".builders/bench.sh")
    mapping = dict(re.findall(r"^\s*([a-z0-9-]+)\)\s*echo\s+([a-z0-9-]+)\s*;;",
                              bench, re.M))
    makefile = read("Makefile")
    for target in sorted(wheels):
        rule = mapping.get(target, target)
        if not re.search(rf"^build-{re.escape(rule)}:", makefile, re.M):
            fail("stages",
                 f"no `build-{rule}:` rule for bake target {target!r} — "
                 f"bench.sh cold {target} would fail")


def main():
    report = load("perfreport", ".builders/perfreport.py")
    sample = load("perfsample", ".builders/perfsample.py")
    check_sccache_format(report)
    check_placement(report)
    check_sample_shape(report, sample)
    check_stages()
    check_costs()

    if FAIL:
        print("contract violations:", file=sys.stderr)
        for f in FAIL:
            print(f"  {f}", file=sys.stderr)
        return 1
    print("contracts ok: nginx log_format, balance placement, sample shape, "
          "perf stages, build-* rules and target-costs all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
