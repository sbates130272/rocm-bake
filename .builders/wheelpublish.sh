#!/usr/bin/env bash
# Publish one architecture's wheels: binaries to a GitHub release, the
# PEP 503 index to gh-pages.
#
# Usage:  wheelpublish.sh --arch gfx950 [--wheels DIR] [--index DIR]
#                         [--rocm 10.1.0-full] [--repo owner/name]
#                         [--dry-run] [--no-push]
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
# The release is a plain tag, not a repository tag object anyone has to
# push: `gh release create` makes it from the current commit if it does
# not exist. Re-running replaces same-named assets and then prunes any
# .whl the current build did not produce, so a republished arch leaves
# no stale wheel behind -- see the note above the prune step for why
# --clobber alone is not enough.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}" || exit 1

ARCH=""
WHEELS=""
INDEX=""
ROCM="${ROCM_VERSION:-10.1.0-full}"
PYVER="${PYTHON_VERSION:-3.14}"
REPO=""
DRY=0
PUSH=1

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
        --repo)    REPO="${2:-}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --no-push) PUSH=0; shift ;;
        -h|--help) usage 0 ;;
        *) echo "wheelpublish: unknown argument $1" >&2; usage 2 ;;
    esac
done

[ -n "${ARCH}" ] || { echo "wheelpublish: --arch is required" >&2; exit 2; }
WHEELS="${WHEELS:-dist/wheels/${ARCH}}"
INDEX="${INDEX:-dist/index/${ARCH}}"

say() { printf '%s\n' "$*" >&2; }
run() { if [ "${DRY}" = 1 ]; then say "   would: $*"; else "$@"; fi; }

[ -d "${WHEELS}" ] || {
    say "wheelpublish: ${WHEELS} does not exist — run 'make wheel-index' first"
    exit 1
}
shopt -s nullglob
WHLS=("${WHEELS}"/*.whl)
shopt -u nullglob
[ "${#WHLS[@]}" -gt 0 ] || { say "wheelpublish: no .whl in ${WHEELS}"; exit 1; }

# The repository the release lands in. Derived rather than hardcoded so
# a fork publishes to itself; `gh` resolves it from the remote.
if [ -z "${REPO}" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
[ -n "${REPO}" ] || { say "wheelpublish: cannot determine repo; pass --repo"; exit 1; }

# The ROCm version without the `-full` flavour suffix: the flavour is a
# property of the base image we build from, not of the wheels, and it
# does not belong in a public tag.
TAG="wheels-${ROCM%%-*}-${ARCH}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

say "== ${ARCH}"
say "   repo     ${REPO}"
say "   tag      ${TAG}"
say "   wheels   ${#WHLS[@]} file(s), $(du -shc "${WHLS[@]}" 2>/dev/null | tail -1 | cut -f1)"

# ── 1. the index, pointed at the release ────────────────────────────
# Regenerated here rather than reused from `make wheel-index`, because
# that one points at local paths. Same script, different --wheel-url.
say "   index    regenerating with --wheel-url ${BASE}/"
run python3 -I "${HERE}/wheelindex.py" "${WHEELS}" \
    --arch "${ARCH}" --out "${INDEX}" \
    --version "${ROCM}" --python "${PYVER}" \
    --wheel-url "${BASE}/"

# ── 2. the release ──────────────────────────────────────────────────
# The notes are rebuilt on every publish, not only at creation. They
# quote versions and describe what the filenames do and do not say, and
# both of those move: written once on 2026-11-05 and never revisited,
# all four releases still claimed "architecture-specific despite their
# filenames" after the filenames had gained a ROCm marker, and still
# said "Built for ROCm 10.1.0-full" -- the image flavour, which the tag
# itself strips and which means nothing to someone installing a wheel.
SITE="https://${REPO%%/*}.github.io/${REPO##*/}"
NOTES="PEP 503 index: ${SITE}/data/wheels/${ARCH}/

    pip install --index-url ${SITE}/data/wheels/${ARCH}/ \\
        --extra-index-url https://pypi.org/simple \\
        \"rocm-torch[device-${ARCH}]\"

Built for ROCm ${ROCM%%-*}, Python ${PYVER}, ${ARCH}.

The version strings say which ROCm these were built against; nothing in
a filename says which GPU. torch for gfx950 and for gfx1201 are the
same filename and differ by about 40MB of device code, so install
through the index — its path and the \`rocm-torch\` metapackage are what
carry the architecture — rather than downloading an asset by hand.

The extra index is not optional: ordinary dependencies resolve from
PyPI. Our wheels win over same-named PyPI projects because the
metapackage pins exact versions carrying a local segment (\`+rocm…\`)
that upstream cannot match."

if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    say "   release  ${TAG} exists — replacing assets, refreshing notes"
    run gh release edit "${TAG}" --repo "${REPO}" \
        --title "ROCm ${ROCM%%-*} wheels for ${ARCH}" \
        --notes "${NOTES}"
else
    say "   release  creating ${TAG}"
    run gh release create "${TAG}" --repo "${REPO}" \
        --title "ROCm ${ROCM%%-*} wheels for ${ARCH}" \
        --notes "${NOTES}"
fi

# The generated metapackage goes up too, because its href now points
# at the release like every other wheel. It must not stay on gh-pages:
# its filename carries a PEP 440 local segment
# (rocm_torch-10.1.0+gfx950.13b9737a-py3-none-any.whl) and GitHub Pages
# the entire site build on a "+" in a filename, reporting only "Page
# build failed". Measured 2026-11-05.
shopt -s nullglob
META=("${INDEX}"/rocm-torch/*.whl)
shopt -u nullglob

# --clobber: re-running must replace an asset, not fail on it, or a
# republished arch leaves the index pointing at a stale binary whose
# sha256 no longer matches and every install fails verification.
say "   upload   ${#WHLS[@]} wheel(s) + ${#META[@]} metapackage"
run gh release upload "${TAG}" --repo "${REPO}" --clobber \
    "${WHLS[@]}" ${META[@]+"${META[@]}"}

# ...but --clobber only matches by FILENAME, so it replaces nothing when
# a wheel's version changes. The old asset simply stays, and the release
# accumulates a generation per rebuild.
#
# Not hypothetical. Before this was added, wheels-10.1.0-gfx950 held
# both
#
#     amd_aiter-0.1.29.dev0+gf1965cd26.d20261104-...whl
#     amd_aiter-0.1.29.dev0+gf1965cd26.d20261105-...whl
#
# because setuptools_scm stamps the build date and the date moved. The
# index only ever points at the current set, so the strays are
# unreferenced -- but they are still public, still downloadable at a
# stable URL, and indistinguishable from the real thing to anyone who
# picks an asset off the release page by hand.
#
# So: after uploading, delete every .whl asset that is not in the set
# just uploaded. Only .whl, and only after a successful upload, so a
# half-finished publish cannot strand the release empty.
# grep -vxF against the wanted list, NOT sort + comm. comm requires its
# inputs in the collation order it compares with, and `sort -u` under a
# UTF-8 locale does not provide it for these names: punctuation is
# weighted differently, so comm reports
#
#     comm: file 1 is not in sorted order
#
# and stops partway through. Measured on the real gfx950 asset list,
# that deleted the stale amd_aiter wheel and then silently left three
# generations of the rocm_torch metapackage behind. The failure mode in
# the other direction is worse: an order comm disagrees with can emit a
# name that IS current, and this loop deletes what it is handed.
# grep -vxF needs no ordering at all, and matches whole lines literally.
WANT=$(for f in "${WHLS[@]}" ${META[@]+"${META[@]}"}; do basename "${f}"; done)

# The query runs in --dry-run too, and deliberately. Deleting assets is
# the one irreversible thing this script does, so the dry run has to be
# able to answer "what exactly would go?" -- a summary count cannot be
# checked against anything. `gh release view` is read-only; only the
# delete below is gated on DRY.
HAVE=$(gh release view "${TAG}" --repo "${REPO}" \
           --json assets --jq '.assets[].name' 2>/dev/null \
       | grep -E '\.whl$' || true)
STALE=$(printf '%s\n' "${HAVE}" \
        | grep -vxF -f <(printf '%s\n' "${WANT}") || true)
if [ -z "${STALE}" ]; then
    say "   prune    no stale assets"
else
    printf '%s\n' "${STALE}" | while read -r asset; do
        [ -n "${asset}" ] || continue
        if [ "${DRY}" = 1 ]; then
            say "   prune    would remove stale asset ${asset}"
        else
            say "   prune    removing stale asset ${asset}"
            gh release delete-asset "${TAG}" "${asset}" \
                --repo "${REPO}" --yes
        fi
    done
fi

# ── 3. the index to gh-pages ────────────────────────────────────────
if [ "${PUSH}" = 0 ]; then
    say "   pages    skipped (--no-push); index is in ${INDEX}"
    exit 0
fi

GHP="dist/gh-pages"
say "   pages    publishing index to data/wheels/${ARCH}/"
if [ "${DRY}" = 1 ]; then
    say "   would: ghpages.sh ${GHP} && copy ${INDEX} -> data/wheels/${ARCH}/"
    exit 0
fi

"${HERE}/ghpages.sh" "${GHP}" >/dev/null
DEST="${GHP}/data/wheels/${ARCH}"
rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"
cp -r "${INDEX}" "${DEST}"
# Everything published to Pages must be .html -- see the note above the
# metapackage upload. The wheel is already a release asset by now, and
# the index points at it there.
find "${DEST}" -name '*.whl' -delete

# The landing page that lists every arch published so far. Regenerated
# from what is on disk, so it reflects this publish and every previous
# one without keeping a list of architectures anywhere. Without it
# data/wheels/ is a 404 and an index is reachable only by typing an
# arch name you already know.
python3 -I "${HERE}/wheelsite.py" "${GHP}/data/wheels" --repo "${REPO}"

cd "${GHP}"
git add "data/wheels"
if git diff --cached --quiet; then
    say "   pages    no change"
else
    # gpgsign=false alongside the bot identity, and not merely for
    # convenience. This commit is generated data attributed to
    # github-actions[bot]; signing it with a human key asserts
    # authorship that is not true. The same commit made by nightly.yml
    # on a runner is unsigned for the same reason.
    #
    # It also removes a real failure mode. With commit.gpgsign=true set
    # globally, publishing dies on
    #
    #     gpg: signing failed: No such file or directory
    #     PINENTRY_LAUNCHED ... not a tty
    #
    # whenever the agent's passphrase cache has expired -- after the
    # release assets are already uploaded, leaving the wheels public
    # and the index missing. Observed 2026-11-06 on gfx1151.
    git -c user.name='github-actions[bot]' \
        -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        -c commit.gpgsign=false \
        commit -q -m "data: wheel index for ${ARCH} (${TAG})"
    # HEAD:gh-pages, not the branch name: this worktree is detached, so
    # pushing the branch name would push the local ref rather than what
    # was just committed. Same reason nightly.yml does it this way.
    git push -q origin HEAD:gh-pages
    say "   pages    pushed"
fi
cd "${ROOT}"

say ""
say "   https://${REPO%%/*}.github.io/${REPO##*/}/data/wheels/${ARCH}/"
