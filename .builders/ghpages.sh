#!/usr/bin/env bash
# Put a clean gh-pages worktree on disk, ready to be written into.
#
# Three publishers want this and had three copies of it: bench-publish,
# perf-publish and image-publish. They differ only in what they copy in
# afterwards, so the thirty lines of worktree bookkeeping in front of
# that are shared — and the copies had already started to drift.
#
# A detached worktree under dist/, not a clone and not a branch switch.
# A switch would move the tree out from under whatever else is running
# here, and this repo is frequently mid-build.
#
# Usage:  ghpages.sh <dir> [branch]
# Prints the directory on success; everything else goes to stderr so a
# caller can use the output directly.
set -euo pipefail

DIR="${1:?usage: ghpages.sh <dir> [branch]}"
BRANCH="${2:-gh-pages}"

say() { printf '%s\n' "$*" >&2; }

# Best-effort: the branch may not exist yet, and the next check reports
# that far better than a fetch failure would.
git fetch origin "+${BRANCH}:refs/remotes/origin/${BRANCH}" 2>/dev/null || true

if [ ! -d "${DIR}" ]; then
    if ! git rev-parse --verify -q "origin/${BRANCH}" >/dev/null; then
        say "${BRANCH} does not exist on origin yet."
        say "Run the Docs workflow once to create it, then re-run this."
        exit 1
    fi
    git worktree add "${DIR}" "origin/${BRANCH}" --detach >&2
    git -C "${DIR}" checkout -B "${BRANCH}" "origin/${BRANCH}" >&2
fi

# Always re-fetch and reset: the worktree may be days old, and
# publishing onto a stale base is how one publisher's data reverts
# another's.
git -C "${DIR}" fetch origin "+${BRANCH}:refs/remotes/origin/${BRANCH}" >&2
git -C "${DIR}" reset --hard "origin/${BRANCH}" >&2

printf '%s\n' "${DIR}"
