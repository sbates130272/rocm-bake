#!/bin/sh
# Entrypoint for the `mori` image: pick a UMBP role from argv[1].
#
# MORI's multi-process mode is two long-lived processes, and which one
# a container should be is a deployment decision, not a build decision.
# One image with a role argument is how that stays true:
#
#   docker run <img>                   # standalone, the default
#   docker run <img> standalone        # the node-local buffer pool
#   docker run <img> master            # the cross-node control plane
#   docker run <img> env               # print the resolved settings
#   docker run <img> check             # assert both binaries are there
#   docker run <img> python -c '...'   # anything else, verbatim
#
# WHY NOT TWO IMAGES. They would differ by one ENTRYPOINT line and
# share every layer, so the registry would carry two tags, two cache
# refs and two rows in every table here for one artifact — and a
# deployment would still have to decide which to pull, which is the
# same decision moved somewhere less visible.
#
# WHY THE BINARIES ARE NOT ON PATH. They ship *inside* the wheel, at
# mori/umbp_master and mori/umbp_standalone_server, because that is
# where UMBP_MASTER_BIN expects to find them when the Python package
# auto-starts a master. Symlinking them into /usr/local/bin would work
# and would also make the image lie about where they came from; asking
# the installed package is both honest and correct after a pip upgrade.
#
# WHAT THIS DOES NOT DO. It passes no flags of its own. UMBP is
# configured entirely by environment — see
# src/umbp/doc/runtime-env-vars.md upstream — so every argument after
# the role goes to the binary untouched, and the only values set here
# are defaults for variables that would otherwise be unset.
set -eu

# The installed package directory, which is where both binaries live.
# Resolved through the module rather than hardcoded to a site-packages
# path: the venv's python version is a build variable here.
mori_dir() {
    python -c 'import mori, os; print(os.path.dirname(mori.__file__))'
}

MORI_DIR="$(mori_dir)"
MASTER_BIN="${MORI_DIR}/umbp_master"
STANDALONE_BIN="${MORI_DIR}/umbp_standalone_server"

# UMBP_MASTER_BIN is read by the Python package when it auto-starts a
# master (UMBP_MASTER_AUTO_START). Exporting it here means a worker
# running inside this image finds the binary without being told where
# it is, and a container running `master` reports the same path it
# would spawn.
export UMBP_MASTER_BIN="${UMBP_MASTER_BIN:-${MASTER_BIN}}"

# host:port the master binds when it is the control plane for a
# multi-node pool. 15558 is the port upstream's own UMBP_MASTER_ADDRESS
# example uses; 0.0.0.0 rather than 127.0.0.1 because a container's
# loopback is not reachable from anywhere a peer could be.
#
# THIS IS THIS IMAGE'S KNOB, NOT UMBP'S. umbp_master does not read the
# environment for its listen address -- `strings` on the binary has no
# UMBP_MASTER_LISTEN in it at all. It takes the address as argv[1],
# which is why `umbp_master --help` does not print help: it tries to
# bind "--help" and dies with "Name or service not known". Measured
# 2026-11-26.
#
# The name is kept because it is upstream's, for the separate path
# where the Python package auto-starts a master (UMBP_MASTER_AUTO_START
# reads UMBP_MASTER_BIN and UMBP_MASTER_LISTEN). Here it is simply
# turned into argv[1] below, so both paths are configured the same way.
export UMBP_MASTER_LISTEN="${UMBP_MASTER_LISTEN:-0.0.0.0:15558}"

# The standalone server's own defaults, restated so that `env` below
# prints the values that will actually be used rather than blanks.
# Upstream's default address is
# unix:///run/umbp/standalone/<node_id>.grpc.sock, synthesised from a
# node id the server makes up when none is given — so this is left
# unset unless the caller sets it, and `env` says so.
export UMBP_SSD_DIR="${UMBP_SSD_DIR:-/tmp/umbp_ssd}"

missing() {
    echo "mori-entrypoint: $1 is not in this image." >&2
    echo "  The wheel was built with BUILD_UMBP off, or with a MORI" >&2
    echo "  release that no longer ships it. See docker/Dockerfile.mori." >&2
    exit 1
}

require_binaries() {
    [ -x "${MASTER_BIN}" ] || missing "umbp_master"
    [ -x "${STANDALONE_BIN}" ] || missing "umbp_standalone_server"
}

role="${1:-standalone}"
[ "$#" -eq 0 ] || shift

case "${role}" in
    standalone|server|normal)
        require_binaries
        # The gRPC socket and its sibling fd-handoff socket live here.
        # Created rather than assumed: a deployment that bind-mounts a
        # host directory over /run/umbp gets an empty one.
        mkdir -p /run/umbp/standalone "${UMBP_SSD_DIR}"
        echo "mori-entrypoint: ${STANDALONE_BIN}"
        exec "${STANDALONE_BIN}" "$@"
        ;;
    master)
        require_binaries
        # The listen address is argv[1] to the binary. Supplied only
        # when the caller gave no arguments of its own, so
        # `docker run <img> master 10.0.0.1:9999` still means what it
        # looks like. With neither, umbp_master binds whatever its
        # own default is -- which on this image did not include 15558,
        # and is how an apparently-healthy master serves nobody.
        if [ "$#" -eq 0 ]; then
            set -- "${UMBP_MASTER_LISTEN}"
        fi
        echo "mori-entrypoint: ${MASTER_BIN} $*"
        exec "${MASTER_BIN}" "$@"
        ;;
    check)
        require_binaries
        python -c 'import mori; print("mori", getattr(mori, "__version__", "unknown"))'
        echo "umbp_master:             ${MASTER_BIN}"
        echo "umbp_standalone_server:  ${STANDALONE_BIN}"
        # Locating the binaries is not the same as being able to run
        # them. These link ROCm's bundled zlib and libnuma, which sit
        # in a directory that is on no loader path by default -- so
        # the honest check is whether the dynamic linker can resolve
        # them, not whether the files exist. `exec` would be better
        # still, but both of these are servers that do not return.
        rc=0
        for bin in "${MASTER_BIN}" "${STANDALONE_BIN}"; do
            if ldd "${bin}" 2>&1 | grep -q 'not found'; then
                echo "unresolved libraries in $(basename "${bin}"):" >&2
                ldd "${bin}" 2>&1 | grep 'not found' >&2
                rc=1
            fi
        done
        [ "${rc}" -eq 0 ] || exit 1
        echo "both binaries resolve every shared library they need"
        ;;
    env)
        require_binaries
        echo "package:                 ${MORI_DIR}"
        echo "UMBP_MASTER_BIN:         ${UMBP_MASTER_BIN}"
        echo "UMBP_MASTER_LISTEN:      ${UMBP_MASTER_LISTEN}  (passed as argv[1] to umbp_master; the binary reads no env for this)"
        echo "UMBP_MASTER_ADDRESS:     ${UMBP_MASTER_ADDRESS:-<unset: embedded mode, no routing or registration>}"
        echo "UMBP_NODE_ADDRESS:       ${UMBP_NODE_ADDRESS:-<unset: synthesised>}"
        echo "UMBP_STANDALONE_ADDRESS: ${UMBP_STANDALONE_ADDRESS:-<unset: unix:///run/umbp/standalone/NODE.grpc.sock>}"
        echo "UMBP_DRAM_CAPACITY:      ${UMBP_DRAM_CAPACITY:-<unset: 4 GiB>}"
        echo "UMBP_SSD_CAPACITY:       ${UMBP_SSD_CAPACITY:-<unset: 32 GiB>}"
        echo "UMBP_SSD_DIR:            ${UMBP_SSD_DIR}"
        ;;
    *)
        # Not a role. Put the argument back and run the command as
        # given, so this image behaves like the base one for anything
        # that is not UMBP — `docker run <img> python -c ...`,
        # `docker run <img> bash`, a health probe, a debug shell.
        exec "${role}" "$@"
        ;;
esac
