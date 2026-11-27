#!/usr/bin/env bash
# Start a UMBP pool on a GPU host and check that it is serving.
#
# WHY THIS IS NOT `docker run` AND A GREP FOR "up". The same reason
# `make serve-test` exists rather than trusting /health: a container
# that stays up has proved nothing. umbp_standalone_server's whole job
# is to publish a gRPC socket that workers connect to, so the check
# that means something is that the socket exists and accepts a
# connection -- and, for the master, that it is listening on its port.
#
# WHAT IS CHECKED, in order, each fatal:
#
#   1. `check`  - both binaries are in the image and resolve their
#                 shared libraries. Cheap, no devices, and it
#                 distinguishes a BUILD_UMBP=OFF wheel from a working
#                 one before anything harder is attempted.
#   2. master   - umbp_master starts and listens on UMBP_MASTER_LISTEN.
#   3. pool     - umbp_standalone_server starts, stays up, and creates
#                 its .grpc.sock and the sibling .fd.sock that carries
#                 the one-time file-descriptor handoff.
#   4. connect  - something can actually open that socket.
#
# WHAT IS NOT CHECKED. No memory is allocated from the pool and no
# worker is attached, because that needs a MORI client workload this
# repo does not have yet. This proves the service stands up on this
# hardware; it does not prove MORI's kernels are correct on it. On RDNA
# that distinction matters -- see docs/architecture/mori.md.
set -euo pipefail

HOST=""
IMAGE=""
RUN_FLAGS=""
PORT="${UMBP_MASTER_PORT:-15558}"
NAME_PREFIX="mori-test-$$"

while [ $# -gt 0 ]; do
    case "$1" in
        --host)      HOST="$2"; shift 2 ;;
        --image)     IMAGE="$2"; shift 2 ;;
        --run-flags) RUN_FLAGS="$2"; shift 2 ;;
        --port)      PORT="$2"; shift 2 ;;
        *) echo "mori-test: unknown argument $1" >&2; exit 2 ;;
    esac
done

[ -n "${HOST}" ]  || { echo "mori-test: --host is required" >&2; exit 2; }
[ -n "${IMAGE}" ] || { echo "mori-test: --image is required" >&2; exit 2; }

export DOCKER_HOST="ssh://${HOST}"

MASTER="${NAME_PREFIX}-master"
POOL="${NAME_PREFIX}-pool"

# Containers are removed whatever happens, including a failed check and
# a Ctrl-C. Without this a failed run leaves a GPU-holding container on
# the host for the next person to find.
cleanup() {
    rc=$?
    echo
    echo "== cleanup"
    for c in "${MASTER}" "${POOL}"; do
        if docker ps -a --format '{{.Names}}' | grep -qx "${c}"; then
            echo "   logs from ${c}:"
            docker logs "${c}" 2>&1 | sed 's/^/     /' | tail -20 || true
            docker rm -f "${c}" >/dev/null 2>&1 || true
        fi
    done
    exit "${rc}"
}
trap cleanup EXIT INT TERM

echo "== host:  ${HOST}"
echo "== image: ${IMAGE}"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
    echo "mori-test: ${IMAGE} is not in ${HOST}'s docker daemon." >&2
    echo "  Run \`make mori-load\` first; nothing here pulls." >&2
    exit 1
}

# ── 1. the image's own report ────────────────────────────────────
echo
echo "== 1. binaries present and resolvable"
# shellcheck disable=SC2086
docker run --rm ${RUN_FLAGS} "${IMAGE}" check

# ── 2. the master ────────────────────────────────────────────────
echo
echo "== 2. umbp_master listens on ${PORT}"
# shellcheck disable=SC2086
docker run -d --name "${MASTER}" ${RUN_FLAGS} \
    -e "UMBP_MASTER_LISTEN=0.0.0.0:${PORT}" \
    "${IMAGE}" master >/dev/null

listening=0
for _ in $(seq 1 30); do
    if ! docker ps --format '{{.Names}}' | grep -qx "${MASTER}"; then
        echo "   umbp_master exited; its log follows in cleanup" >&2
        exit 1
    fi
    # ss from inside the container's own netns, so this needs nothing
    # installed on the host and works whether or not the port is
    # published.
    if docker exec "${MASTER}" sh -c \
            "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null" \
            | awk -v p="${PORT}" '
                NR>1 { split($2,a,":"); if (strtonum("0x" a[2]) == p) found=1 }
                END { exit found?0:1 }'; then
        listening=1; break
    fi
    sleep 1
done
[ "${listening}" = 1 ] || {
    echo "   nothing is listening on ${PORT} after 30s" >&2
    exit 1
}
echo "   listening on ${PORT}"

# ── 3. the standalone pool ───────────────────────────────────────
echo
echo "== 3. umbp_standalone_server publishes its socket"
# shellcheck disable=SC2086
docker run -d --name "${POOL}" ${RUN_FLAGS} \
    "${IMAGE}" standalone >/dev/null

sock=""
for _ in $(seq 1 30); do
    if ! docker ps --format '{{.Names}}' | grep -qx "${POOL}"; then
        echo "   umbp_standalone_server exited; its log follows in cleanup" >&2
        exit 1
    fi
    sock=$(docker exec "${POOL}" sh -c \
        'ls /run/umbp/standalone/*.grpc.sock 2>/dev/null | head -1' || true)
    [ -n "${sock}" ] && break
    sleep 1
done
[ -n "${sock}" ] || {
    echo "   no .grpc.sock under /run/umbp/standalone after 30s" >&2
    exit 1
}
echo "   gRPC socket:  ${sock}"

# The fd-handoff socket's path is derived mechanically from the gRPC
# one. Its absence means the server came up only halfway: workers would
# find the control plane and then fail the descriptor handoff.
fdsock="${sock%.grpc.sock}.fd.sock"
docker exec "${POOL}" test -S "${fdsock}" || {
    echo "   ${fdsock} is missing: the fd handoff would fail" >&2
    exit 1
}
echo "   fd socket:    ${fdsock}"

# ── 4. the socket accepts a connection ───────────────────────────
echo
echo "== 4. the socket accepts a connection"
docker exec "${POOL}" python -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect('${sock}')
except OSError as e:
    sys.exit('could not connect to ${sock}: %s' % e)
s.close()
print('   connected to', '${sock}')
"

echo
echo "== PASS: the pool stands up and serves on ${HOST}"
echo "   Not proved: that MORI's kernels are correct on this GPU."
echo "   Nothing has allocated from the pool or attached a worker."
