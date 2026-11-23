#!/bin/bash
# builder-create.sh - create one buildx builder from the fleet manifest.
#
# This replaces three near-identical Makefile targets that differed only
# in a name and an endpoint, and could not describe a fourth node
# without a fourth copy. Everything it needs — the endpoint, the
# buildkitd config, the log limits — comes from manifests/<fleet>.yml
# through fleet.py.
#
# Usage:
#   ./builder-create.sh <node>      one node, by its manifest name
#   ./builder-create.sh --pool      every build node as one buildx pool
#
# Idempotent: an existing builder of that name is left alone. The
# buildkitd config is baked in at create time, so a manifest change does
# NOT reach a builder that already exists — recreate it:
#
#   docker buildx rm <node> && ./builder-create.sh <node>

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FLEET_PY, not FLEET. The Makefile exports FLEET as the manifest
# *name*, so a local variable of that name here is not local at all —
# it overwrites the exported one, and fleet.py then looks for a
# manifest called ".builders/fleet.py.yml".
FLEET_PY="${HERE}/fleet.py"
GEN="${HERE}/generated"

fleet() { python3 -I "${FLEET_PY}" "$@"; }

# One rendered config per node, written before the builder is created
# because --config reads it then and never again.
render() {
    local node="$1"
    mkdir -p "${GEN}"
    fleet --buildkitd "${node}" > "${GEN}/buildkitd-${node}.toml"
    echo "${GEN}/buildkitd-${node}.toml"
}

# `buildx inspect`, not `buildx ls --format '{{.Name}}'`. That listing
# prints NODE names as well as builder names, and the pool builder
# names each of its nodes after the node it holds -- so `snoc-strix`
# appears in it as a node of `snoc-pool` whether or not a builder by
# that name exists.
#
# The false positive only shows up when recreating a builder whose
# name is also a pool node, which is exactly what bumping the pinned
# buildkit image requires:
#
#     $ docker buildx rm snoc-strix && make builder-snoc-strix
#     snoc-strix removed
#     snoc-strix builder already exists          <- it does not
#     ERROR: failed to find instance "snoc-strix"
#
# create_one returned early on the stale match, then use_if_default
# tried to `buildx use` a builder that had just been deleted. The node
# was left with no builder at all. Measured 2026-11-16.
exists() {
    docker buildx inspect "$1" >/dev/null 2>&1
}

make_var() { fleet --make | sed -n "s/^$1=//p"; }

# The manifest's default builder also becomes buildx's own default, so
# a bare `docker buildx bake` outside make lands somewhere sensible
# rather than on the `default` docker driver, which has no shared cache
# and cannot export one.
use_if_default() {
    [ "$1" = "$(make_var FLEET_DEFAULT_BUILDER)" ] || return 0
    docker buildx use "$1"
    echo "$1 is now the default builder"
}

# The buildkit image every fleet builder runs, pinned by DIGEST and not
# just by tag. buildx's own default is moby/buildkit:buildx-stable-1,
# which resolved to v0.34.2 on 2026-11-16.
#
# WHY. v0.34.2 and earlier carry moby/buildkit#6418: when more than one
# cache-from manifest describes the same stage,
# combinedCacheManager.Query deduplicates the cache keys and keeps only
# the manager that answered first, so every other imported cache stops
# being queryable for the rest of the build. Which one wins is a race.
# pytorch-wheel imports seven refs on this fleet and all of them exist
# in Zot, so there are six live importers to lose.
#
# Measured on the AWS lane, which has the same bake file and the same
# problem: two runs of `--targets triton-wheel` on an identical tree
# both reported 14 of 41 build steps CACHED, the same eleven steps
# missing in the same order. The third run, identical but for this pin,
# reported 38 of 41 and finished in 7 seconds instead of 13 minutes --
# the only three misses being FROM pulls, which can never report
# CACHED. $1.05 to $0.01.
#
# Fixed upstream in moby/buildkit#7312, released in v0.35.0 on
# 2026-11-11. The v0.35.0 notes carry it as "Fix cache matching with
# missing blobs or alternative input keys. #7364 #7312".
#
# By digest because a tag is mutable and this is a correctness floor,
# not a preference: a silently-moved tag would reintroduce the bug with
# nothing in the log to say so. `make version-check` watches
# moby/buildkit for a newer release; bump both this and the copy in
# nightly.sh together, which check-contracts.py enforces.
#
# The image is baked in at create time, so an existing builder does NOT
# pick it up. Recreate: docker buildx rm <node> && make builder-<node>.
BUILDKIT_IMAGE="${BUILDKIT_IMAGE:-moby/buildkit:v0.35.1@sha256:baf6138eb8c37644800c7c913fba051e840ebb9ba13eaf92d92ef9a1712d0b4c}"

# network=host, the raised step-log limits and linux/amd64 are the same
# on every node and every driver; see buildkitd.toml.in for why the
# first is not optional.
common_opts() {
    local cfg="$1"
    printf '%s\n' \
        --driver docker-container \
        --driver-opt network=host \
        --driver-opt "image=${BUILDKIT_IMAGE}" \
        --config "${cfg}" \
        --platform linux/amd64
}

create_one() {
    local node="$1" endpoint cfg
    if exists "${node}"; then
        echo "${node} builder already exists"
        use_if_default "${node}"
        return 0
    fi
    endpoint=$(fleet --endpoint "${node}")
    cfg=$(render "${node}")
    echo "Creating ${node} builder (${endpoint})..."
    local -a opts
    mapfile -t opts < <(common_opts "${cfg}")
    # The local node takes no endpoint argument at all; buildx then
    # uses this host's Docker daemon.
    if [ "${endpoint}" = "local" ]; then
        docker buildx create --name "${node}" "${opts[@]}" \
            --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
            --driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760
    else
        docker buildx create --name "${node}" "${opts[@]}" \
            --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
            --driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
            "${endpoint}"
    fi
    use_if_default "${node}"
    echo "${node} builder active"
}

# The buildx pool. Nothing in this repository builds against it any
# more — BUILDER=<pool> routes through balance.sh instead, because
# buildx's own node selection ignores capacity — but it is kept
# creatable for a bare `docker buildx bake --builder <pool>`.
create_pool() {
    local pool node endpoint cfg first=1
    pool=$(make_var FLEET_POOL_BUILDER)
    if exists "${pool}"; then
        echo "${pool} builder already exists"
        docker buildx inspect "${pool}" --bootstrap
        return 0
    fi
    echo "Creating ${pool} builder..."
    for node in $(fleet --nodes --capability build); do
        endpoint=$(fleet --endpoint "${node}")
        cfg=$(render "${node}")
        local -a opts
        mapfile -t opts < <(common_opts "${cfg}")
        local -a append=()
        [ "${first}" = 1 ] || append=(--append)
        first=0
        if [ "${endpoint}" = "local" ]; then
            docker buildx create --name "${pool}" "${append[@]}" \
                --node "${node}" "${opts[@]}"
        else
            docker buildx create --name "${pool}" "${append[@]}" \
                --node "${node}" "${opts[@]}" "${endpoint}"
        fi
    done
    docker buildx inspect "${pool}" --bootstrap
}

case "${1:-}" in
    --pool) create_pool ;;
    "")     echo "usage: builder-create.sh <node>|--pool" >&2; exit 2 ;;
    *)
        # The pool is not a node, but `make builder-<pool>` is the
        # spelling that predates this script and still reads as the
        # obvious thing to type.
        if [ "$1" = "$(make_var FLEET_POOL_BUILDER)" ]; then
            create_pool
        else
            create_one "$1"
        fi
        ;;
esac
