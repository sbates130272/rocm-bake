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
"""
import importlib.util
import re
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
def check_placement():
    src = read(".builders/balance.sh")
    m = re.search(r'echo\s+"(\s+\$target -> \$node[^"]*)"', src)
    if not m:
        return fail("placement",
                    "balance.sh no longer echoes `   $target -> $node`")
    line = (m.group(1).replace("$target", "pytorch-wheel")
                      .replace("$node", "snoc-think"))
    # The same pattern perfreport uses to attribute targets to builders.
    hit = re.search(r"^\s+(\S+) -> (\S+)\s", line)
    if not hit or hit.groups() != ("pytorch-wheel", "snoc-think"):
        fail("placement",
             f"perfreport's placement regex does not parse balance.sh's "
             f"line:\n    {line!r}")


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
              "net_rx_bps", "interval_seconds"}
    missing = needed - emitted
    if missing:
        fail("sample-shape",
             f"perfreport reads fields perfsample never writes: "
             f"{sorted(missing)}")


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
    check_placement()
    check_sample_shape(report, sample)
    check_stages()

    if FAIL:
        print("contract violations:", file=sys.stderr)
        for f in FAIL:
            print(f"  {f}", file=sys.stderr)
        return 1
    print("contracts ok: nginx log_format, balance placement, sample shape, "
          "perf stages and build-* rules all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
