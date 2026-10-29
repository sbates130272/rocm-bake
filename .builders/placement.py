#!/usr/bin/env python3
"""Print "<target> <node>" for each target in a run, from balance.log.

One parser, called from the shell. The balancer emits two formats —
"<target> -> <node>" in stage mode, "<node>: starting <target>" in
queue mode — and the regex for the first was copied into three places
before the second existed. All three then silently matched nothing
under --queue: perfrun captured no traces, perfserve captured no
traces, and perfreport attributed every target to "unknown". None of
them errored.

So the parser lives in perfreport.py, is covered by check-contracts.py,
and this is how shell callers reach it.

Usage: placement.py <run-dir>
"""
import importlib.util
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(
        "perfreport", here / "perfreport.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for target, node in sorted(mod.read_placement(Path(sys.argv[1])).items()):
        print(f"{target} {node}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
