#!/bin/sh
# max-jobs.sh - how many parallel compile jobs this node can afford.
#
#   usage: max-jobs.sh <per_job_gb> [reserve_gb] [ceiling]
#   prints the job count on stdout, and a one-line explanation on stderr
#
# Every Dockerfile that compiles used to carry its own copy of this
# arithmetic. Nine copies had drifted into nine variants: two names for
# the same variable, three of them subtracting a reserve and six not,
# one guarding against per<=0 and eight not, two clamping to a ceiling
# and seven not, and two different answers to "what if awk printed
# nothing". The bug that cost four nightlies existed in seven of them
# and was fixed in one. So there is one copy now, and
# check-contracts.py fails the build if a tenth appears.
#
# WHY THE RESERVE EXISTS. Dividing MemAvailable by a per-job figure
# prices one compiler process. It does not price the build. Linking,
# the largest translation units, and in HIP builds a burst of about
# 10GB arriving thirty seconds in, are all there whatever job count is
# chosen. Budgeting none of that is how a node thrashes rather than
# being OOM-killed: on 2026-11-25 Triton chose 45 jobs on a 48-core
# 91GB runner, and the host ran out of memory so completely that `tail`
# could not allocate and the shell could not fork. Four nightlies died
# that way before the cause was found, each leaving no artifact and no
# log to say why.
#
# WHY THE CEILING EXISTS. The reserve is subtractive, so a big enough
# machine still talks itself into an untested job count: at 91GB with
# a 12GB reserve and 2GB a job, the arithmetic still says 39. The
# ceiling is the bound that does not scale with the node.
#
# Callers pass their own numbers because the compiles differ -- aiter
# prices a job at 1GB, vllm-cpu at 3GB -- but the shape is shared.
set -eu

per="${1:?usage: max-jobs.sh <per_job_gb> [reserve_gb] [ceiling]}"
reserve="${2:-0}"
ceiling="${3:-0}"

# MEMINFO and NPROC exist so the tests can present a node this machine
# is not. Nothing in the build sets them.
meminfo="${MEMINFO:-/proc/meminfo}"
cores="${NPROC:-$(nproc 2>/dev/null || echo 1)}"
avail_gb="$(awk '/^MemAvailable:/ {printf "%.1f", $2/1048576}' "${meminfo}" 2>/dev/null || echo "")"

# per<=0 would divide by zero; an unreadable /proc/meminfo leaves
# avail empty. Both fall back to one job rather than to `cores`: a
# node whose memory cannot be read is exactly where guessing wide is
# worst, and the caller can always pin MAX_JOBS explicitly.
n="$(awk -v per="${per}" -v reserve="${reserve}" -v avail="${avail_gb}" '
    BEGIN {
        if (per <= 0 || avail == "") { print 1; exit }
        n = int((avail - reserve) / per)
        print (n < 1 ? 1 : n)
    }')"

[ "${n}" -le "${cores}" ] || n="${cores}"
if [ "${ceiling}" -gt 0 ] && [ "${n}" -gt "${ceiling}" ]; then
    n="${ceiling}"
fi

printf 'max-jobs: %s (%s cores, %sGB available, %sGB held back, %s a job, ceiling %s)\n' \
    "${n}" "${cores}" "${avail_gb:-unknown}" "${reserve}" "${per}" \
    "$([ "${ceiling}" -gt 0 ] && echo "${ceiling}" || echo none)" >&2
printf '%s\n' "${n}"
