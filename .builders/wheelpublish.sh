#!/usr/bin/env bash
# Publish one architecture's wheels: binaries to a GitHub release, the
# PEP 503 index to gh-pages.
#
# Usage:  wheelpublish.sh --arch gfx950 [--wheels DIR] [--index DIR]
#                         [--rocm VERSION] [--build YYYYMMDD[.N]]
#                         [--repo owner/name]
#                         [--title TEXT] [--notes-file FILE]
#                         [--dry-run] [--no-push]
#         wheelpublish.sh --reindex [--repo owner/name] [--dry-run]
#
# --reindex publishes no build. It rebuilds every index on gh-pages
# from the releases; see wheelsite.py.
# --rocm defaults to $ROCM_VERSION, then to rocm-bake.hcl's default.
# --build defaults to today's date, UTC.
#
# WHY TWO PLACES. The wheels are 300-500MB each -- amd_aiter for gfx950
# is 494MB -- and GitHub refuses a file over 100MB in git. gh-pages can
# therefore carry the index, which is a few KB of HTML, but never the
# wheels. Release assets take 2GB each and do not count against the
# repository, so the binaries go there and the index points at them.
# wheelindex.py already supports exactly this: --wheel-url sets the href
# prefix, and every link already carries a #sha256= fragment, so an
# offsite asset is still verified by pip.
#
# WHY ONE RELEASE PER ARCH. Every wheel this repo builds has an
# arch-independent filename -- torch-2.15.0a0+git31a77fc.rocm10.1.0-
# cp314-cp314-linux_x86_64.whl is the same string for gfx950 and
# gfx1201, and the two files differ by 40MB. The version says which
# ROCm; nothing in it says which GPU. That is the whole reason
# wheelindex.py puts the arch in the path. Assets within one release
# share a namespace, so two arches in one release would collide and the
# second upload would either fail or silently replace the first. A
# release per arch keeps the filenames distinct by keeping them apart.
#
# WHY ONE RELEASE PER BUILD, AND NOTHING EVER REPLACED. The tag is
# wheels-<rocm>-<arch>-<build>, and a published asset is never
# overwritten or deleted. This script used to do both: one release per
# (rocm, arch), `gh release upload --clobber` over it, then a prune of
# whatever the new build had not produced. That made a public URL mean
# different bytes on different days. A pip cache keyed on the URL, a
# lockfile holding its sha256, and anyone who installed last week and
# wants the same thing again were all broken by a republish, and a
# weekly build would have made that weekly. It also had a window, seen
# by wheels-probe.yml, in which a live index pointed at an asset that
# had been removed to be re-uploaded.
#
# So a build that differs from the last one is a new release beside
# it, and the index (wheelsite.py) lists both. A build that does NOT
# differ publishes nothing: the weekly lane rebuilds whether or not
# anything moved, and a gigabyte of identical assets a week is not a
# record of anything.
#
# The releases cut before this, tagged wheels-<rocm>-<arch> with no
# build, are left exactly as they are and stay in the index.
#
# The release is a plain tag, not a repository tag object anyone has to
# push: `gh release create --target` makes it at the commit this is
# running from.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}" || exit 1

ARCH=""
WHEELS=""
INDEX=""
# Same awk as the Makefile's BAKE_DEFAULTS and bench.sh's bake_default:
# rocm-bake.hcl is the single source, so no copy of the version here.
bake_default() {
    awk -v want="$1" '
        /^variable[ \t]*"/ {
            n = $0; sub(/^variable[ \t]*"/, "", n); sub(/".*/, "", n) }
        n == want && /default[ \t]*=[ \t]*"/ {
            v = $0; sub(/^.*default[ \t]*=[ \t]*"/, "", v); sub(/".*/, "", v)
            print v; exit }' rocm-bake.hcl
}
ROCM="${ROCM_VERSION:-$(bake_default ROCM_VERSION)}"
PYVER="${PYTHON_VERSION:-3.14}"
BUILD=""
REPO=""
TITLE=""
NOTES_FILE=""
DRY=0
PUSH=1
REINDEX=0

# The header block, however long it is. A hardcoded range silently
# truncates --help mid-sentence the first time the comment grows, which
# is exactly what happened when the prune note was added.
usage() {
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)    ARCH="${2:-}"; shift 2 ;;
        --wheels)  WHEELS="${2:-}"; shift 2 ;;
        --index)   INDEX="${2:-}"; shift 2 ;;
        --rocm)    ROCM="${2:-}"; shift 2 ;;
        --build)   BUILD="${2:-}"; shift 2 ;;
        --repo)    REPO="${2:-}"; shift 2 ;;
        --title)   TITLE="${2:-}"; shift 2 ;;
        --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --no-push) PUSH=0; shift ;;
        --reindex) REINDEX=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "wheelpublish: unknown argument $1" >&2; usage 2 ;;
    esac
done

say() { printf '%s\n' "$*" >&2; }
run() { if [ "${DRY}" = 1 ]; then say "   would: $*"; else "$@"; fi; }

# The repository the release lands in. Derived rather than hardcoded so
# a fork publishes to itself; `gh` resolves it from the remote.
if [ -z "${REPO}" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
[ -n "${REPO}" ] || { say "wheelpublish: cannot determine repo; pass --repo"; exit 1; }

# ── the index, onto gh-pages ────────────────────────────────────────
# pages <commit message> [<manifest.json> <tag>]
#
# Files a build's manifest, when given one, and rebuilds every index
# from all of them -- which is what keeps the older builds and the
# older ROCm versions listed. See wheelsite.py.
#
# --from-releases on every publish, not only when something looks
# wrong: it costs one API call when nothing is missing, and it is what
# puts back a build that a docs deploy racing an earlier publish threw
# away. docs.yml force-pushes the branch, so that loss is silent.
GHP="dist/gh-pages"
pages() {
    local attempt
    # Three attempts, each from a fresh copy of the branch. Other
    # things push here -- docs.yml on any docs change, the nightly's
    # report -- and a push that loses that race is rejected as a
    # non-fast-forward. By then the release is uploaded, so stopping
    # would leave a public build the index does not list. Rebuilding
    # on the new tip is always correct, because the index is a pure
    # function of the manifests and the releases.
    for attempt in 1 2 3; do
        "${HERE}/ghpages.sh" "${GHP}" >/dev/null
        mkdir -p "${GHP}/data/wheels/builds"
        [ -z "${2:-}" ] || cp "$2" "${GHP}/data/wheels/builds/$3.json"
        python3 -I "${HERE}/wheelsite.py" "${GHP}/data/wheels" \
            --repo "${REPO}" --from-releases >&2

        git -C "${GHP}" add "data/wheels"
        if [ "${DRY}" = 1 ]; then
            # Everything above is local: a worktree and files in it.
            # Show what a real run would commit, then put it back.
            { git -C "${GHP}" diff --cached --name-status -- data/wheels/builds
              git -C "${GHP}" diff --cached --shortstat
            } | sed 's/^/   would: /' >&2
            git -C "${GHP}" reset -q --hard
            return 0
        fi
        if git -C "${GHP}" diff --cached --quiet; then
            say "   pages    no change"
            return 0
        fi
        # gpgsign=false alongside the bot identity, and not merely for
        # convenience. This commit is generated data attributed to
        # github-actions[bot]; signing it with a human key asserts
        # authorship that is not true. The same commit made by
        # nightly.yml on a runner is unsigned for the same reason.
        #
        # It also removes a real failure mode. With commit.gpgsign=true
        # set globally, publishing dies on
        #
        #     gpg: signing failed: No such file or directory
        #     PINENTRY_LAUNCHED ... not a tty
        #
        # whenever the agent's passphrase cache has expired -- after the
        # release assets are already uploaded, leaving the wheels public
        # and the index missing. Observed 2026-11-06 on gfx1151.
        git -C "${GHP}" -c user.name='github-actions[bot]' \
            -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
            -c commit.gpgsign=false \
            commit -q -m "$1"
        # HEAD:gh-pages, not the branch name: this worktree is detached,
        # so pushing the branch name would push the local ref rather
        # than what was just committed. Same reason nightly.yml does it
        # this way.
        if git -C "${GHP}" push -q origin HEAD:gh-pages; then
            say "   pages    pushed"
            return 0
        fi
        say "   pages    push rejected (attempt ${attempt} of 3) — rebuilding on the new gh-pages"
    done
    say "wheelpublish: could not push the index. The release is uploaded;"
    say "   run 'make wheels-reindex' to list it."
    return 1
}

# --reindex: no build to publish, only the index to rebuild. This is
# how the builds published before manifests existed got back into the
# index, and what to run if gh-pages is ever lost.
if [ "${REINDEX}" = 1 ]; then
    say "== reindex ${REPO}"
    pages "data: rebuild the wheel indexes from the releases"
    exit 0
fi

[ -n "${ARCH}" ] || { echo "wheelpublish: --arch is required" >&2; exit 2; }
[ -n "${ROCM}" ] || { echo "wheelpublish: no ROCm version; pass --rocm or set ROCM_VERSION" >&2; exit 2; }
WHEELS="${WHEELS:-dist/wheels/${ARCH}}"
INDEX="${INDEX:-dist/index/${ARCH}}"
# The assets that are neither a wheel nor an index page: one
# <wheel>.metadata per wheel and the build's manifest.json. Beside the
# index rather than inside it, because wheelindex.py removes any
# directory under the index root that is not a project.
RELEASE="${INDEX%/}.release"

[ -d "${WHEELS}" ] || {
    say "wheelpublish: ${WHEELS} does not exist — run 'make wheel-index' first"
    exit 1
}
shopt -s nullglob
WHLS=("${WHEELS}"/*.whl)
shopt -u nullglob
[ "${#WHLS[@]}" -gt 0 ] || { say "wheelpublish: no .whl in ${WHEELS}"; exit 1; }


# The ROCm version without the `-full` flavour suffix: the flavour is a
# property of the base image we build from, not of the wheels, and it
# does not belong in a public tag.
RV="${ROCM%%-*}"
PREFIX="wheels-${RV}-${ARCH}"
SITE="https://${REPO%%/*}.github.io/${REPO##*/}"
RDIR="rocm$(printf '%s' "${RV}" | cut -d. -f1-2)"
BUILD_RE='[0-9]{8}(\.[0-9]+)?'
if [ -n "${BUILD}" ] && ! printf '%s' "${BUILD}" | grep -qxE "${BUILD_RE}"; then
    say "wheelpublish: --build ${BUILD} is not YYYYMMDD or YYYYMMDD.N"
    exit 2
fi

# "sha256 name" for every asset of a release, after one marker line;
# nothing at all if there is no such release. `gh api`, not `gh release
# view --json assets`: the digest is a field of the REST asset object,
# and it is the one thing every decision below is made on.
#
# The output is captured and only printed on success, and that is the
# whole point of the function. On an HTTP error `gh api` writes the
# response BODY to stdout as well as exiting non-zero, so `2>/dev/null
# || true` handed {"message":"Not Found",...} to the caller as if it
# were an asset list. The first publish to run on CodeBuild therefore
# found that a release which did not exist "exists and holds different
# wheels", and refused. A test stub that exits quietly hid it.
#
# Only a 404 means "no such release". Anything else -- a bad token, a
# rate limit, no network -- stops the publish: guessing "absent" there
# is how an existing build would come to be published twice.
#
# An asset that is not fully uploaded is printed with "-" for its
# digest. A transfer that fails can leave an empty asset behind in
# GitHub's "starter" state: it is listed, it blocks an upload under the
# same name, and it has no bytes to compare. See unfinished() below.
#
# The marker line is what says the release exists when it has no
# assets yet, which is the state a publish that died between `release
# create` and its first upload leaves behind. It matches none of the
# patterns the callers look for.
remote_assets() {
    local out
    if out="$(gh api "repos/${REPO}/releases/tags/$1" \
                --jq '.assets[] | "\(if .state == "uploaded" and .digest then .digest | ltrimstr("sha256:") else "-" end) \(.name)"' 2>&1)"; then
        printf 'release @\n%s\n' "${out}"
        return 0
    fi
    case "${out}" in *"HTTP 404"*) return 0 ;; esac
    say "wheelpublish: cannot read release $1: $(printf '%s' "${out}" | tail -1)"
    return 1
}
# Stop if the release this run is about to add to holds an asset that
# never finished uploading. It cannot be verified and cannot be
# uploaded over, and treating it as present is how a release would be
# marked complete around an empty file -- for good, since nothing here
# replaces an asset. Deleting it is the one deletion that is safe: it
# was never a published file.
unfinished() {
    local bad
    bad="$(printf '%s\n' "$2" | awk '$1 == "-" { print $2 }')"
    [ -n "${bad}" ] || return 0
    say "wheelpublish: $1 holds asset(s) that never finished uploading:"
    printf '%s\n' "${bad}" | while read -r name; do
        say "       gh release delete-asset $1 '${name}' --repo ${REPO} --yes"
    done
    say "   Remove them with the command(s) above and run this again."
    exit 1
}

# The first tag for a day that no release holds: <day>, then <day>.1,
# <day>.2 ... Leaves it in TAG. The lookup is a plain assignment inside
# the loop, not the loop's condition, so a failed one stops the script.
free_tag() {
    local n=0 held
    TAG="${PREFIX}-$1"
    while :; do
        held="$(remote_assets "${TAG}")"
        [ -n "${held}" ] || break
        n=$((n + 1))
        TAG="${PREFIX}-$1.${n}"
    done
}

local_sums() {
    for f in "$@"; do
        printf '%s %s\n' "$(sha256sum "${f}" | cut -d' ' -f1)" "$(basename "${f}")"
    done
}
# The built wheels only. The metapackage is generated here, from them,
# and its version carries the build number -- so it differs between two
# builds that are otherwise byte-identical and says nothing about
# whether anything was rebuilt.
built() { grep -E '\.whl$' | grep -vE ' rocm_torch-' | LC_ALL=C sort; }

say "== ${ARCH}"
say "   repo     ${REPO}"
say "   wheels   ${#WHLS[@]} file(s), $(du -shc "${WHLS[@]}" 2>/dev/null | tail -1 | cut -f1)"

# ── 0. which release ────────────────────────────────────────────────
# The newest dated build of this ROCm and arch, or the one --build
# names, is the only release this run may touch, and only in two
# cases.
#
# It is COMPLETE and holds exactly these wheels: nothing was rebuilt,
# so there is nothing to publish. The run still goes on to gh-pages,
# where it is a no-op unless the index lost that build.
#
# It is INCOMPLETE and holds nothing these wheels contradict: a publish
# that died partway. The upload below sends what is missing.
#
# manifest.json is what marks a release complete, which is why it is
# uploaded last and on its own. Anything else is a different build and
# gets its own release.
MINE="$(local_sums "${WHLS[@]}" | built)"
if [ -n "${BUILD}" ]; then
    PRIOR="${PREFIX}-${BUILD}"
else
    # Captured first and filtered second. As one pipeline ending in
    # `|| true`, a listing that failed -- a rate limit, a 5xx -- read
    # as "no dated build yet", and an unchanged set of wheels would
    # then go out as a second release beside the identical first.
    if ! TAGS="$(gh api --paginate "repos/${REPO}/releases?per_page=100" \
                   --jq '.[].tag_name' 2>&1)"; then
        say "wheelpublish: cannot list releases: $(printf '%s' "${TAGS}" | tail -1)"
        exit 1
    fi
    PRIOR="$(printf '%s\n' "${TAGS}" \
             | grep -xE "${PREFIX}-${BUILD_RE}" | sort -V | tail -1 || true)"
fi
# Plain assignments, never `[ ... ] || X=$(...)`: errexit is ignored on
# the right of ||, and a failed lookup has to stop the script.
THEIRS=""
if [ -n "${PRIOR}" ]; then
    THEIRS="$(remote_assets "${PRIOR}")"
fi
THEIR_WHEELS="$(printf '%s\n' "${THEIRS}" | built || true)"
COMPLETE=0
! printf '%s\n' "${THEIRS}" | grep -q ' manifest\.json$' || COMPLETE=1

if [ "${COMPLETE}" = 1 ] && [ "${THEIR_WHEELS}" = "${MINE}" ]; then
    TAG="${PRIOR}"
    say "   tag      ${TAG} already holds these wheels — nothing new to upload"
    # Straight to the index, and nothing regenerated on the way. The
    # metapackage, the sidecars and the manifest are functions of more
    # than the wheels -- of wheelindex.py itself, for one -- so
    # regenerating them after a code change yields files that differ
    # from the published ones. Comparing those would fail a run that
    # has just established there is nothing to publish, and it is the
    # run that matters: the retry after a publish died in the gh-pages
    # step and a fix was merged. The release's own manifest is the one
    # that describes it; wheelsite.py fetches it if the index lacks it.
    if [ "${PUSH}" = 0 ]; then
        say "   pages    skipped (--no-push)"
    elif [ "${DRY}" = 1 ]; then
        say "   would: make sure the index on gh-pages lists ${TAG}"
    else
        say "   pages    making sure the index lists ${TAG}"
        pages "data: wheel index for ${TAG}"
    fi
    exit 0
elif [ -n "${THEIRS}" ] && [ "${COMPLETE}" = 0 ] \
     && [ -z "$(printf '%s\n' "${THEIR_WHEELS}" \
                | grep -vxF -f <(printf '%s\n' "${MINE}") || true)" ]; then
    TAG="${PRIOR}"
    say "   tag      ${TAG} is incomplete — resuming it"
    unfinished "${TAG}" "${THEIRS}"
elif [ -n "${BUILD}" ]; then
    TAG="${PREFIX}-${BUILD}"
    THEIRS="$(remote_assets "${TAG}")"
    if [ -n "${THEIRS}" ]; then
        # The tag that was asked for, holding other wheels. Refused
        # rather than merged: adding to it would leave a release that
        # is neither build, and replacing its assets is the thing this
        # script no longer does.
        free_tag "${BUILD%%.*}"
        say "wheelpublish: ${PREFIX}-${BUILD} exists and holds different wheels."
        say "   A published build is never changed. Publish this one beside it:"
        say "       --build ${TAG#"${PREFIX}-"}"
        exit 1
    fi
    say "   tag      ${TAG} (new build)"
else
    # No build was named, so take the first tag free today. A second
    # differing build on one day is ordinary -- a publish that died
    # partway, a fix, and a rebuild whose wheels are not byte-identical
    # -- and the workflows pass no --build, so refusing here would
    # leave an hour's build unpublishable until the date changed.
    free_tag "$(date -u +%Y%m%d)"
    THEIRS=""
    say "   tag      ${TAG} (new build)"
fi
BUILD="${TAG#"${PREFIX}-"}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

# ── 1. the index, pointed at the release ────────────────────────────
# Regenerated here rather than reused from `make wheel-index`, because
# that one points at local paths. Same script, different --wheel-url.
#
# Not behind `run`: it writes only under dist/, and a dry run that did
# not generate it could not say which assets the real one would send.
say "   index    regenerating with --wheel-url ${BASE}/"
python3 -I "${HERE}/wheelindex.py" "${WHEELS}" \
    --arch "${ARCH}" --out "${INDEX}" \
    --version "${ROCM}" --python "${PYVER}" \
    --build "${BUILD}" --release-dir "${RELEASE}" \
    --wheel-url "${BASE}/" >&2

# ── 2. the release ──────────────────────────────────────────────────
# Written once, when the release is created, and not refreshed: the
# notes describe this build, and this build does not change.
NOTES="PEP 503 index: ${SITE}/data/wheels/${RDIR}/${ARCH}/

This build, exactly:

    pip install --index-url ${SITE}/data/wheels/${RDIR}/${ARCH}/ \\
        --extra-index-url https://pypi.org/simple \\
        \"rocm-torch[device-${ARCH}]==${RV}.${BUILD}\"

Drop the \`==${RV}.${BUILD}\` for the newest build on ROCm ${RV%.*}. For
the newest ROCm published for ${ARCH}, use ${SITE}/data/wheels/${ARCH}/
instead.

Built for ROCm ${RV}, Python ${PYVER}, ${ARCH}. Build ${BUILD}.

The version strings say which ROCm these were built against; nothing in
a filename says which GPU. torch for gfx950 and for gfx1201 are the
same filename and differ by about 40MB of device code, so install
through the index — its path and the \`rocm-torch\` metapackage are what
carry the architecture — rather than downloading an asset by hand.

The extra index is not optional: ordinary dependencies resolve from
PyPI. Our wheels win over same-named PyPI projects because the
metapackage pins exact versions carrying a local segment (\`+rocm…\`)
that upstream cannot match.

The assets of this release are never replaced. A rebuild is a new
release, and both stay in the index."

# The generated notes describe a per-card ROCm release: "Built for
# ROCm X, Python Y, <arch>", device code hidden behind identical
# filenames, a one-line install. None of that is true of the emulator
# lane, which publishes through this same script under the pseudo-arch
# `emu` — its wheels are py3-none-any, contain no ROCm at all, and need
# a torch installed first because the index deliberately pins none. A
# release page carrying the generic install line would hand its reader
# a vLLM that cannot import. So a lane whose release is not a per-card
# ROCm build supplies its own title and notes.
if [ -n "${NOTES_FILE}" ]; then
    [ -r "${NOTES_FILE}" ] || { say "wheelpublish: cannot read ${NOTES_FILE}"; exit 1; }
    NOTES="$(cat "${NOTES_FILE}")"
fi
TITLE="${TITLE:-ROCm ${RV} wheels for ${ARCH}, build ${BUILD}}"

if [ -n "${THEIRS}" ]; then
    say "   release  ${TAG} exists — left as it is"
else
    say "   release  creating ${TAG}"
    # --target, or the tag lands on whatever the default branch's head
    # is when this runs: with --repo, gh does not look at the checkout.
    # The publish follows an hour of build, so a merge in between would
    # tag a commit these wheels were not built from, permanently. The
    # commit must exist on the remote; run from an unpushed HEAD this
    # fails rather than quietly tagging main.
    run gh release create "${TAG}" --repo "${REPO}" \
        --target "${GITHUB_SHA:-$(git rev-parse HEAD)}" \
        --title "${TITLE}" \
        --notes "${NOTES}"
fi

# The generated metapackage goes up too, because its href points at
# the release like every other wheel. It must not stay on gh-pages:
# its filename carries a PEP 440 local segment
# (rocm_torch-10.1.0+gfx950.13b9737a-py3-none-any.whl) and GitHub Pages
# the entire site build on a "+" in a filename, reporting only "Page
# build failed". Measured 2026-11-05. The .metadata sidecars carry the
# same "+" and go to the release for the same reason, which is also
# where PEP 658 wants them: at the wheel's own URL plus ".metadata".
shopt -s nullglob
META=("${INDEX}"/rocm-torch/*.whl)
EXTRA=("${RELEASE}"/*.metadata "${RELEASE}"/manifest.json)
shopt -u nullglob

# Upload what the release does not have, and only that. No --clobber:
# an asset that is already there under this name is either the same
# bytes, in which case there is nothing to do, or it is not, in which
# case stopping is the only safe answer. Checked before anything is
# sent, so a mismatch cannot leave the release half-updated.
SEND=()
LAST=()
for f in "${WHLS[@]}" ${META[@]+"${META[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}; do
    name="$(basename "${f}")"
    have="$(printf '%s\n' "${THEIRS}" | awk -v n="${name}" '$2 == n { print $1; exit }')"
    if [ -z "${have}" ]; then
        if [ "${name}" = manifest.json ]; then LAST+=("${f}"); else SEND+=("${f}"); fi
    elif [ "${have}" != "$(sha256sum "${f}" | cut -d' ' -f1)" ]; then
        say "wheelpublish: ${TAG} already has ${name} with different contents."
        say "   Nothing was uploaded. A published asset is never replaced."
        exit 1
    fi
done
say "   upload   $(( ${#SEND[@]} + ${#LAST[@]} )) new asset(s) of ${#WHLS[@]} wheel(s) + ${#META[@]} metapackage + ${#EXTRA[@]} metadata"
if [ "${#SEND[@]}" -gt 0 ]; then
    run gh release upload "${TAG}" --repo "${REPO}" "${SEND[@]}"
fi
if [ "${#LAST[@]}" -gt 0 ]; then
    run gh release upload "${TAG}" --repo "${REPO}" "${LAST[@]}"
fi

# ── 3. the index to gh-pages ────────────────────────────────────────
if [ "${PUSH}" = 0 ]; then
    say "   pages    skipped (--no-push); index is in ${INDEX}"
    exit 0
fi
if [ "${DRY}" = 1 ]; then
    # Not pages(): this build's release does not exist, so the index
    # it would produce points at assets that are not there.
    say "   would: add builds/${TAG}.json and regenerate data/wheels on gh-pages"
    exit 0
fi

say "   pages    publishing data/wheels/${RDIR}/${ARCH}/"
pages "data: wheel index for ${TAG}" "${RELEASE}/manifest.json" "${TAG}"

say ""
say "   ${SITE}/data/wheels/${RDIR}/${ARCH}/"
say "   ${SITE}/data/wheels/${ARCH}/   (newest ROCm for ${ARCH})"
