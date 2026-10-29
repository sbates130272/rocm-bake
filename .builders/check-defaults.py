#!/usr/bin/env python3
"""check-defaults.py - fail if the Makefile re-declares a bake.hcl default.

bake.hcl is the single source for every value a build reads. The
Makefile is allowed to *read* those values, through its bake_default
function, but not to carry its own copy: for a long time it did, and the
two agreed only because nobody had yet changed one. A `make build-vllm`
and a bare `docker buildx bake vllm` would then have produced different
images from the same tree, with nothing to say so.

Four checks, all cheap enough to gate every pull request:

  1. No name is defined in both files with a literal value. A Makefile
     assignment whose right-hand side calls bake_default is a read, not
     a definition, and is what this is asking for.

  2. Every bake_default call names a variable that exists in bake.hcl.
     A typo, or a variable that got renamed on the bake side, otherwise
     resolves to the empty string in silence — which is worse than
     drift, because the build then runs with no value at all.

  3. Every `$(call bake,X)` names a target or group bake.hcl defines.
     `make build-cupy-wheel` against a renamed target fails inside bake
     with its own error, long after the Makefile looked fine.

  4. WHEEL_REPOS matches bake's `wheels` group. Both list the same
     artifacts for different purposes — one builds them, one reports
     what is published — and the Makefile carried a comment asking
     whoever changed one to change the other. That is the kind of
     instruction a check should enforce rather than a human remember.

Exceptions live in ALLOWED below, each with the reason it is not drift.
Adding to that list is a deliberate act visible in review, which is the
point of keeping it here rather than making the check cleverer.

Usage: .builders/check-defaults.py [--quiet]
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Names the Makefile may define even though bake.hcl also declares them.
# These are not duplicated defaults: the Makefile computes a value bake
# cannot, and exports it so bake reads it from the environment.
ALLOWED = {
    "VCS_REF": "computed from git describe/HEAD; bake has no repo access",
    "BUILD_DATE": "computed from the HEAD commit timestamp",
    "SCCACHE_WEBDAV_ENDPOINT": (
        "composed from the host resolved to an address; bake's own "
        "default is the name form, correct outside a build container"
    ),
}


def bake_variables(text):
    """Names declared as `variable "X" {` in bake.hcl."""
    return set(re.findall(r'^variable\s+"([A-Za-z0-9_]+)"', text, re.M))


def bake_targets(text):
    """Names bake can be asked to build: targets and groups alike.

    The Makefile's `bake` macro takes either, and "" for the default
    group, so both belong in the same set as far as callers care.
    """
    return (set(re.findall(r'^target\s+"([A-Za-z0-9_-]+)"', text, re.M))
            | set(re.findall(r'^group\s+"([A-Za-z0-9_-]+)"', text, re.M)))


def bake_group_members(text, group):
    """The target list of one `group "X" { targets = [...] }` block."""
    m = re.search(r'^group\s+"%s"\s*\{(.*?)\n\}' % re.escape(group),
                  text, re.M | re.S)
    if not m:
        return None
    return set(re.findall(r'"([A-Za-z0-9_-]+)"', m.group(1)))


def makefile_value(text, name):
    """A top-level assignment's right-hand side, continuations joined.

    WHEEL_REPOS spans two lines with a trailing backslash, so reading
    only the first would silently compare half a list.
    """
    m = re.search(r'^%s\s*[?:+]?=((?:[^\n\\]|\\\n)*)' % re.escape(name),
                  text, re.M)
    if not m:
        return None
    return m.group(1).replace("\\\n", " ")


def makefile_assignments(text):
    """Top-level NAME = / := / ?= assignments, as {name: (lineno, rhs)}.

    Recipe lines start with a tab and are skipped by the ^ anchor plus
    the leading-character class; conditionals and `export NAME` lines do
    not match either, which is what we want — `export` alone does not
    define a value.
    """
    out = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*[?:+]?=(.*)$", line)
        if m and m.group(1) not in out:
            out[m.group(1)] = (lineno, m.group(2).strip())
    return out


def main():
    quiet = "--quiet" in sys.argv
    bake_text = (ROOT / "bake.hcl").read_text()
    mk_text = (ROOT / "Makefile").read_text()

    variables = bake_variables(bake_text)
    assignments = makefile_assignments(mk_text)
    errors = []

    # 1. The Makefile must not re-declare a bake variable.
    for name in sorted(variables & set(assignments)):
        lineno, rhs = assignments[name]
        if "bake_default" in rhs:
            continue
        if name in ALLOWED:
            continue
        errors.append(
            f"Makefile:{lineno}: {name} is declared in bake.hcl but given a "
            f"value here ({rhs!r}).\n"
            f"    Read it instead:  {name} := $(or $({name}),"
            f"$(call bake_default,{name}))\n"
            f"    If the Makefile genuinely has to compute it, add {name} to "
            f"ALLOWED in {Path(__file__).name} with the reason."
        )

    # 2. Every bake_default call must name a variable bake.hcl declares.
    call_re = r"\$\(call\s+bake_default\s*,\s*([A-Za-z0-9_]+)\s*\)"
    for m in re.finditer(call_re, mk_text):
        name = m.group(1)
        if name not in variables:
            lineno = mk_text[: m.start()].count("\n") + 1
            errors.append(
                f"Makefile:{lineno}: bake_default({name}) — no such variable "
                f"in bake.hcl, so this expands to nothing."
            )

    # 3. Every bake target the Makefile invokes must exist.
    targets = bake_targets(bake_text)
    for m in re.finditer(r"\$\(call\s+bake,\s*([A-Za-z0-9_-]+)", mk_text):
        name = m.group(1)
        if name not in targets:
            lineno = mk_text[: m.start()].count("\n") + 1
            errors.append(
                f"Makefile:{lineno}: $(call bake,{name}) — no such target or "
                f"group in bake.hcl.\n"
                f"    bake.hcl has: {', '.join(sorted(targets))}"
            )

    # 4. WHEEL_REPOS and bake's `wheels` group must list the same things.
    wheels = bake_group_members(bake_text, "wheels")
    repos_raw = makefile_value(mk_text, "WHEEL_REPOS")
    if wheels is not None and repos_raw is not None:
        repos = set(repos_raw.split())
        if repos != wheels:
            lineno = mk_text[: mk_text.index("WHEEL_REPOS")].count("\n") + 1
            only_mk = sorted(repos - wheels)
            only_bake = sorted(wheels - repos)
            detail = ""
            if only_mk:
                detail += f"\n    only in WHEEL_REPOS: {', '.join(only_mk)}"
            if only_bake:
                detail += f"\n    only in the wheels group: {', '.join(only_bake)}"
            errors.append(
                f"Makefile:{lineno}: WHEEL_REPOS does not match the `wheels` "
                f"group in bake.hcl.{detail}\n"
                f"    `make zot-wheels` would report on a different set than "
                f"`make push-wheels` builds."
            )

    if errors:
        print("defaults check failed:\n", file=sys.stderr)
        for e in errors:
            print(f"  {e}\n", file=sys.stderr)
        return 1

    if not quiet:
        shared = sorted(variables & set(assignments))
        print(
            f"defaults ok: {len(variables)} variables in bake.hcl, "
            f"{len(shared)} read by the Makefile "
            f"({len([s for s in shared if s in ALLOWED])} allowed exceptions); "
            f"{len(targets)} bake targets/groups, all Makefile references "
            f"resolve; WHEEL_REPOS matches the wheels group"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
