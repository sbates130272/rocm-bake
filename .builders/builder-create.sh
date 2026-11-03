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

exists() {
    docker buildx ls --format '{{.Name}}' 2>/dev/null | grep -qx "$1"
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

# network=host, the raised step-log limits and linux/amd64 are the same
# on every node and every driver; see buildkitd.toml.in for why the
# first is not optional.
common_opts() {
    local cfg="$1"
    printf '%s\n' \
        --driver docker-container \
        --driver-opt network=host \
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
