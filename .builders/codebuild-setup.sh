#!/usr/bin/env bash
# Stand up the AWS side of the nightly: ECR repositories, an IAM role,
# the CodeBuild runner project and its webhook.
#
# Idempotent. Every step checks for what it is about to create and
# skips it, so re-running after a partial failure is safe and is the
# intended way to fix one.
#
# It does NOT create the GitHub connection. That needs an OAuth
# handshake in the console — AWS says so explicitly — so make it first
# and pass its ARN:
#
#   aws codeconnections create-connection \
#     --provider-type GitHub --connection-name rocm-bake --region us-west-2
#   # finish it in the console, then:
#   aws codeconnections list-connections --region us-west-2
#
# Usage:
#   codebuild-setup.sh --connection-arn <arn> [--dry-run]
#   codebuild-setup.sh --connection-arn <arn> --region eu-west-1
#
# See docs/operations/runners.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}" || exit 1

REGION="${AWS_REGION:-us-west-2}"
PROJECT="${CODEBUILD_PROJECT:-rocm-bake-nightly}"
ROLE_NAME="${ROLE_NAME:-rocm-bake-codebuild-role}"
REPO_SLUG="${REPO_SLUG:-sbates130272/rocm-bake}"
REGISTRY_NAME="${REGISTRY_NAME:-rocm-pytorch}"
# Account-suffixed because S3 bucket names are globally unique.
SCCACHE_BUCKET="${SCCACHE_BUCKET:-}"
CONNECTION_ARN=""
# Secrets Manager ARN holding Docker Hub credentials, for the pull
# through cache rule. Optional: without it the rule is skipped and the
# nightly keeps resolving Docker Hub directly, which works until the
# shared CodeBuild egress IP hits the anonymous rate limit.
DOCKERHUB_SECRET_ARN=""
DOCKERHUB_PREFIX="${DOCKERHUB_PREFIX:-dockerhub}"
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --connection-arn) CONNECTION_ARN="${2:-}"; shift 2 ;;
        --dockerhub-secret-arn) DOCKERHUB_SECRET_ARN="${2:-}"; shift 2 ;;
        --region)         REGION="${2:-}"; shift 2 ;;
        --project)        PROJECT="${2:-}"; shift 2 ;;
        --dry-run)        DRY=1; shift ;;
        -h|--help)        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "codebuild-setup: unknown argument $1" >&2; exit 1 ;;
    esac
done

[ -n "${CONNECTION_ARN}" ] || {
    echo "codebuild-setup: --connection-arn is required (see --help)" >&2
    exit 1
}

say() { printf '\n== %s\n' "$*"; }
run() {
    if [ "${DRY}" = 1 ]; then printf '   would run: %s\n' "$*"; return 0; fi
    "$@"
}

# As run(), but swallows the command's own stdout. For calls whose
# success is already reported by the line above them and whose JSON
# would otherwise land in the middle of the transcript. Errors still
# surface: only stdout is dropped.
run_quiet() {
    if [ "${DRY}" = 1 ]; then printf '   would run: %s\n' "$*"; return 0; fi
    "$@" >/dev/null
}

# Derive rather than ask. This also proves the caller's credentials
# work before anything is created.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
    echo "codebuild-setup: no working AWS credentials" >&2; exit 1; }
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
SCCACHE_BUCKET="${SCCACHE_BUCKET:-rocm-bake-sccache-${ACCOUNT_ID}}"

cat <<EOF
account     ${ACCOUNT_ID}
region      ${REGION}
project     ${PROJECT}
role        ${ROLE_NAME}
registry    ${ECR_REGISTRY}
sccache     s3://${SCCACHE_BUCKET}
connection  ${CONNECTION_ARN}
$([ "${DRY}" = 1 ] && echo 'mode        DRY RUN — nothing will be created')
EOF

# ── 1. the connection must already be usable ─────────────────────
say "Checking the GitHub connection"
CONN_STATUS=$(aws codeconnections get-connection --region "${REGION}" \
    --connection-arn "${CONNECTION_ARN}" \
    --query 'Connection.ConnectionStatus' --output text 2>/dev/null)
if [ "${CONN_STATUS}" != "AVAILABLE" ]; then
    echo "   connection is ${CONN_STATUS:-unreachable}, not AVAILABLE." >&2
    echo "   Finish it in the console: Developer Tools > Settings >" >&2
    echo "   Connections > (select it) > Update a pending connection." >&2
    exit 1
fi
echo "   AVAILABLE"

# ── 2. ECR repositories ──────────────────────────────────────────
# Names come from the tags and cache refs, NOT the target names: the
# two differ, and getting it wrong creates repositories nothing uses
# while missing the ones the push needs. See .builders/nightly.sh.
say "ECR repositories"
mapfile -t REPOS < <(
    docker buildx bake -f rocm-bake.hcl --print default 2>/dev/null \
    | python3 -I -c '
import json, re, sys
names = set()
for spec in json.load(sys.stdin).get("target", {}).values():
    for tag in spec.get("tags") or []:
        m = re.search(r"/([^/:]+)(?::|$)", tag)
        if m: names.add(m.group(1))
    for key in ("cache-to", "cache-from"):
        for e in spec.get(key) or []:
            ref = e.get("ref", "") if isinstance(e, dict) else str(e)
            m = re.search(r"/([^/:,]+)(?::|,|$)", ref)
            if m: names.add(m.group(1))
print("\n".join(sorted(n for n in names if n)))
')
[ "${#REPOS[@]}" -gt 0 ] || { echo "could not derive repo names" >&2; exit 1; }
echo "   ${#REPOS[@]} repositories derived from bake"

for name in "${REPOS[@]}"; do
    repo="${REGISTRY_NAME}/${name}"
    if aws ecr describe-repositories --region "${REGION}" \
        --repository-names "${repo}" >/dev/null 2>&1; then
        printf '   exists  %s\n' "${repo}"
        continue
    fi
    printf '   create  %s\n' "${repo}"
    run_quiet aws ecr create-repository --region "${REGION}" \
        --repository-name "${repo}" \
        --image-tag-mutability MUTABLE >/dev/null
done

# Cache repositories receive a mode=max export every run and grow
# without bound. Images are kept by count rather than age: a nightly
# that stops running should not quietly expire the last good image.
#
# THAT COMMENT USED TO BE A LIE, and it cost real money. The policy it
# described was `tagStatus: any, sinceImagePushed, 14 days` — age-based,
# and `any` means it expires the LIVE `latest-<arch>-nightly` tag along
# with everything else. The has-main-moved gate already skips unchanged
# nights (2026-11-08 and 11-09 both billed $0), so a quiet fortnight
# would have deleted the whole layer cache and the next build would
# have been cold with no error anywhere — the same shape as the
# write-only-cache bug: a failure that reports success.
#
# What actually grows is UNTAGGED manifests. Every push to
# `latest-<arch>-nightly` orphans the previous one, and BuildKit only
# ever reads the tagged ref, so an orphan is dead weight the moment it
# is created. Measured 2026-11-12: pytorch-cache held 16 manifests, 14
# of them untagged; billed ECR storage went 264 GB -> 738 GB in six
# days, +79 GB/day, a $74/month run rate climbing.
#
# So: bound the untagged generations by COUNT, and never touch a tag.
# Three rather than one because a run in flight may still be reading
# the generation it is about to replace, and because one bad export
# should leave something to fall back to.
say "ECR lifecycle policies on every repository"
LIFECYCLE=$(cat <<'EOF'
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep the 3 newest untagged cache generations; a tagged ref is never expired",
      "selection": {
        "tagStatus": "untagged",
        "countType": "imageCountMoreThan",
        "countNumber": 3
      },
      "action": { "type": "expire" }
    }
  ]
}
EOF
)

# Artifact repositories had NO policy at all. That was harmless while
# the nightly was silently running with --no-push, and stopped being
# harmless on 2026-11-12 when it started pushing again: tags here are
# mutable and reused (`latest`, `<version>-<rocm>-<arch>`), so every
# night orphans the previous image, permanently.
#
# Same shape as the cache rule and for the same reason — bound the
# orphans, never expire a tag. A tagged artifact is something a
# `wheels-publish` run or a `docker pull` may still want; an untagged
# one is a digest nothing can name.
ARTIFACT_LIFECYCLE=$(cat <<'EOF'
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep the 3 newest untagged artifact images; a tagged ref is never expired",
      "selection": {
        "tagStatus": "untagged",
        "countType": "imageCountMoreThan",
        "countNumber": 3
      },
      "action": { "type": "expire" }
    }
  ]
}
EOF
)

# Both loops run over every repo bake knows about, which is why this is
# also the fix for the two cache repositories that had no policy at all
# (atom-wheel-cache, torchvision-wheel-cache, 347 GB between them on
# 2026-11-12). They were added to the bake file after this script was
# last run, and nothing re-applies the policy on its own.
# The documents themselves, once, rather than inlined into 27
# near-identical "would run:" lines. A dry run exists to be read, and
# the thing worth reading here is the rule, not the repository list.
if [ "${DRY}" = 1 ]; then
    printf '   cache rule:    %s\n' \
        "$(printf '%s' "${LIFECYCLE}" | tr '\n' ' ' | tr -s ' ')"
    printf '   artifact rule: %s\n' \
        "$(printf '%s' "${ARTIFACT_LIFECYCLE}" | tr '\n' ' ' | tr -s ' ')"
fi
for name in "${REPOS[@]}"; do
    case "${name}" in
        *-cache) policy="${LIFECYCLE}";          kind=cache ;;
        *)       policy="${ARTIFACT_LIFECYCLE}"; kind=artifact ;;
    esac
    printf '   %-9s %s/%s\n' "${kind}" "${REGISTRY_NAME}" "${name}"
    # The line above is the dry run's preview, so skip run_quiet
    # rather than let it print the whole policy document 27 times.
    [ "${DRY}" = 1 ] && continue
    # NOT `>/dev/null 2>&1`. The `2>&1` that used to be here swallowed
    # every error AWS returned, leaving "(could not set lifecycle
    # policy)" as the only signal that anything was wrong and no
    # reason attached to it. Plain `>/dev/null` drops the JSON echo
    # and lets stderr through.
    aws ecr put-lifecycle-policy --region "${REGION}" \
        --repository-name "${REGISTRY_NAME}/${name}" \
        --lifecycle-policy-text "${policy}" >/dev/null \
        || echo "      (could not set lifecycle policy)"
done

# ── 2a. the Docker Hub pull through cache ────────────────────────
# CodeBuild egresses from a shared AWS IP and Docker Hub's anonymous
# limit is 100 pulls per 6 hours against that IP, shared with every
# other tenant on it. The 2026-11-12 gfx1151 run died two seconds in
# on `429 Too Many Requests` resolving ubuntu:26.04. A cold
# architecture exposed it because a warm one answers those from the
# layer cache.
#
# buildkitd-nightly.toml mirrors Docker Hub through mirror.gcr.io,
# which covers ubuntu and docker/dockerfile. It does NOT reliably
# cover rocm/dev-ubuntu-26.04 — mirror.gcr.io caches frequently
# accessed images and proxies the rest, and that one proxied through
# to another 429 when tested. The 8.67 GB ROCm SDK is precisely the
# image most worth caching, so it gets this instead.
#
# OPTIONAL, and skipped without --dockerhub-secret-arn. Docker Hub is
# one of the upstreams AWS requires credentials for; ECR Public, Quay
# and the Kubernetes registry are not. The secret must live in this
# account and region and its NAME must begin with
# `ecr-pullthroughcache/` — AWS rejects it otherwise. Creating it is
# the one step this script cannot do for you:
#
#   aws secretsmanager create-secret --region <region> \
#     --name ecr-pullthroughcache/dockerhub \
#     --secret-string '{"username":"<dockerhub-user>","accessToken":"<dockerhub-PAT>"}'
#
# A read-only PAT is enough; the rule only pulls.
say "Docker Hub pull through cache"
if [ -z "${DOCKERHUB_SECRET_ARN}" ]; then
    echo "   skipped — no --dockerhub-secret-arn"
    echo "   (the nightly will resolve Docker Hub directly and may hit its rate limit)"
elif aws ecr describe-pull-through-cache-rules --region "${REGION}" \
        --ecr-repository-prefixes "${DOCKERHUB_PREFIX}" >/dev/null 2>&1; then
    echo "   exists  ${DOCKERHUB_PREFIX}/ -> registry-1.docker.io"
else
    echo "   create  ${DOCKERHUB_PREFIX}/ -> registry-1.docker.io"
    run_quiet aws ecr create-pull-through-cache-rule --region "${REGION}" \
        --ecr-repository-prefix "${DOCKERHUB_PREFIX}" \
        --upstream-registry-url registry-1.docker.io \
        --credential-arn "${DOCKERHUB_SECRET_ARN}" \
        || echo "      (could not create the rule)"
fi
# Repositories are created by ECR on first pull, so there is nothing to
# pre-create here. Point the build at it with DOCKERHUB — see the
# variable's note in rocm-bake.hcl:
#
#   DOCKERHUB=${ECR_REGISTRY}/${DOCKERHUB_PREFIX}
#
# which the nightly workflow sets from the NIGHTLY_DOCKERHUB
# repository variable.

# ── 2b. the sccache bucket ───────────────────────────────────────
# Objects are content-addressed and numerous, so no versioning (it
# would double the object count for no benefit — a cache entry is
# never updated in place) and an expiry, since an object nothing has
# asked for in a month is not earning its storage.
say "sccache bucket"
if aws s3api head-bucket --bucket "${SCCACHE_BUCKET}" --region "${REGION}" \
    >/dev/null 2>&1; then
    echo "   exists  s3://${SCCACHE_BUCKET}"
else
    echo "   create  s3://${SCCACHE_BUCKET}"
    run_quiet aws s3api create-bucket --bucket "${SCCACHE_BUCKET}" --region "${REGION}" \
        --create-bucket-configuration "LocationConstraint=${REGION}" \
        || echo "      (create failed — the name may be taken globally)"
fi

echo "   blocking public access"
run_quiet aws s3api put-public-access-block --bucket "${SCCACHE_BUCKET}" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' \
    || echo "      (could not block public access)"

echo "   setting a 30-day expiry"
run_quiet aws s3api put-bucket-lifecycle-configuration --bucket "${SCCACHE_BUCKET}" \
    --lifecycle-configuration '{"Rules":[{"ID":"expire-cold-objects","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":30}}]}' \
    || echo "      (could not set the lifecycle policy)"

# ── 3. the service role ──────────────────────────────────────────
say "IAM service role"
TRUST=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "codebuild.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
      "ArnLike": { "aws:SourceArn": "arn:aws:codebuild:${REGION}:${ACCOUNT_ID}:project/*" }
    }
  }]
}
EOF
)

# ecr:GetAuthorizationToken and ecr:CreateRepository are on "*" on
# purpose. The first takes no resource at all; the second cannot be
# reliably constrained to a repository ARN — AWS's own examples scope
# it to "*" — and nightly.sh --ensure-ecr needs it. DescribeRepositories
# sits with pull/push because it is the existence probe, and denying it
# makes --ensure-ecr fall through to a create that also denies.
#
# EcrPullThroughCache carries the ORDINARY pull actions as well as the
# two pull-through ones, and that is not redundancy. AWS documents
# BatchImportUpstreamImage and CreateRepository as the permissions
# needed "in addition to the Amazon ECR API permissions needed to
# authenticate to a private registry and to push and pull images" —
# and the pull actions above are scoped to rocm-pytorch/*, which does
# not cover the pull-through prefix. Granting the import without the
# reads lets the role trigger the cache fill and then be denied the
# result: the 2026-11-12 gfx1151 run got
#
#   403 Forbidden on HEAD /v2/dockerhub/library/ubuntu/manifests/26.04
#
# having just fixed the 429 that preceded it. All five actions belong
# on the prefix.
#
# No comment keys inside the document itself: IAM rejects unknown keys
# in a statement, and a multi-line JSON string is invalid anyway.
POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": [
        "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/codebuild/${PROJECT}",
        "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/codebuild/${PROJECT}:*"
      ]
    },
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPullPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:DescribeRepositories",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${REGISTRY_NAME}/*"
    },
    {
      "Sid": "EcrCreateForEnsure",
      "Effect": "Allow",
      "Action": "ecr:CreateRepository",
      "Resource": "*"
    },
    {
      "Sid": "EcrPullThroughCache",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchImportUpstreamImage",
        "ecr:CreateRepository",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${DOCKERHUB_PREFIX}/*"
    },
    {
      "Sid": "SccacheObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::${SCCACHE_BUCKET}/*"
    },
    {
      "Sid": "SccacheListBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${SCCACHE_BUCKET}"
    },
    {
      "Sid": "UseTheGitHubConnection",
      "Effect": "Allow",
      "Action": ["codeconnections:GetConnection", "codeconnections:GetConnectionToken"],
      "Resource": "${CONNECTION_ARN}"
    }
  ]
}
EOF
)

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    echo "   role ${ROLE_NAME} exists — updating its policy"
else
    echo "   creating role ${ROLE_NAME}"
    run_quiet aws iam create-role --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST}" || exit 1
fi
# run_quiet, not `run ... >/dev/null`. The redirect form sends run()'s
# own "would run:" preview to /dev/null along with the command's
# output, so a dry run printed "policy attached" and showed nothing
# of the policy it would attach. run_quiet drops stdout on a live run
# and prints the preview on a dry one, which is the whole point.
run_quiet aws iam put-role-policy --role-name "${ROLE_NAME}" \
    --policy-name "${ROLE_NAME}-policy" \
    --policy-document "${POLICY}" || exit 1
[ "${DRY}" = 1 ] || echo "   policy attached"

# ── 4. the GitHub credential ─────────────────────────────────────
# Per account AND per region. The "token" for a connection is its ARN.
say "CodeBuild source credential"
if run_quiet aws codebuild import-source-credentials --region "${REGION}" \
    --auth-type CODECONNECTIONS --server-type GITHUB \
    --token "${CONNECTION_ARN}"; then
    [ "${DRY}" = 1 ] || echo "   imported"
else
    echo "   (already present, or import failed)"
fi

# ── 5. the runner project ────────────────────────────────────────
# The name must equal vars.CODEBUILD_PROJECT exactly: the workflow's
# label is codebuild-<project>-<run_id>-<run_attempt>, and a mismatch
# does not error — the job queues until the workflow times out.
#
# buildspec is deliberately empty. CodeBuild overrides it for runner
# builds with its own runner bootstrap unless buildspec-override:true
# is in the runs-on labels, which this repo does not use.
say "CodeBuild project ${PROJECT}"
if aws codebuild batch-get-projects --region "${REGION}" \
    --names "${PROJECT}" --query 'projects[0].name' --output text 2>/dev/null \
    | grep -q "^${PROJECT}$"; then
    # Not updated in place, and that is fine: computeType in the
    # --environment above is only the project DEFAULT, and every
    # workflow here overrides it per job with an `instance-size:`
    # label in runs-on. An existing project created when this script
    # said 2XLARGE therefore still runs xlarge jobs. Only a workflow
    # that omits the label would see the stale default.
    echo "   exists  (computeType is the per-job label's default only)"
else
    # Retried, because IAM is eventually consistent and CodeBuild
    # validates the service role at CreateProject. A role created
    # seconds earlier reliably fails the first attempt with
    # "CodeBuild is not authorized to perform: sts:AssumeRole on
    # service role", which reads like a broken trust policy and is
    # not — the same call succeeds unchanged a moment later.
    echo "   creating"
    create_project() {
    run aws codebuild create-project --region "${REGION}" \
        --name "${PROJECT}" \
        --source "{\"type\":\"GITHUB\",\"location\":\"https://github.com/${REPO_SLUG}\",\"buildspec\":\"\",\"reportBuildStatus\":false}" \
        --artifacts '{"type":"NO_ARTIFACTS"}' \
        --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/amazonlinux-x86_64-standard:5.0","computeType":"BUILD_GENERAL1_XLARGE","privilegedMode":true,"imagePullCredentialsType":"CODEBUILD"}' \
        --service-role "${ROLE_ARN}" \
        --timeout-in-minutes 480 \
        --queued-timeout-in-minutes 60 >/dev/null
    }
    for attempt in 1 2 3 4 5; do
        if create_project; then
            echo "   created (attempt ${attempt})"
            break
        fi
        [ "${attempt}" = 5 ] && {
            echo "   create-project failed five times — if the error named" >&2
            echo "   sts:AssumeRole, the role may still be propagating; re-run." >&2
            exit 1
        }
        echo "   attempt ${attempt} failed, waiting for IAM to propagate"
        sleep 10
    done
fi

say "Webhook (WORKFLOW_JOB_QUEUED)"
if aws codebuild batch-get-projects --region "${REGION}" --names "${PROJECT}" \
    --query 'projects[0].webhook.url' --output text 2>/dev/null | grep -q '^https'; then
    echo "   exists"
else
    echo "   creating"
    if run aws codebuild create-webhook --region "${REGION}" \
        --project-name "${PROJECT}" --build-type BUILD \
        --filter-groups '[[{"type":"EVENT","pattern":"WORKFLOW_JOB_QUEUED"}]]' \
        >/dev/null 2>&1; then
        echo "   created"
    else
        cat >&2 <<'HINT'
   FAILED.

   An OAuthProviderException naming "GitHub API limit reached or
   permission issue" almost always means the second thing: the AWS
   Connector for GitHub app has not been granted the Webhooks scope.
   Creating a webhook is not a permission the connection handshake
   asks for up front.

   Fix it at https://github.com/settings/installations
     -> AWS Connector for GitHub -> Configure
     -> accept the newly requested permissions
     -> confirm Webhooks: Read and write, and that this repository is
        in the selection

   Then re-run this script; everything above is already done and will
   be skipped.
HINT
        exit 1
    fi
fi

# ── 6. what to do next ───────────────────────────────────────────
cat <<EOF

== Done. Set the repository variables, NIGHTLY_ENABLED last:

  gh variable set CODEBUILD_PROJECT --repo ${REPO_SLUG} --body '${PROJECT}'
  gh variable set AWS_REGION        --repo ${REPO_SLUG} --body '${REGION}'
  gh variable set ECR_REGISTRY      --repo ${REPO_SLUG} --body '${ECR_REGISTRY}'
  gh variable set SCCACHE_BUCKET    --repo ${REPO_SLUG} --body '${SCCACHE_BUCKET}'
  gh variable set NIGHTLY_ARCHES    --repo ${REPO_SLUG} --body 'gfx1201'
  gh variable set NIGHTLY_ENABLED   --repo ${REPO_SLUG} --body 'true'

== Then calibrate on one cheap target before trusting the schedule:

  gh workflow run nightly.yml --repo ${REPO_SLUG} \\
    -f arches=gfx1201 -f targets=cupy-wheel -f push=false

  (No cold flag: the input is \`run_cold\` and it is opt-IN, defaulting
  to false, so omitting it is what skips the cold half. This used to
  say \`-f skip_cold=true\`, which \`gh\` rejects outright — that input
  was renamed when cold became something you ask for rather than
  something you suppress.)

== And read what it actually cost:

  aws codebuild list-builds-for-project --region ${REGION} \\
    --project-name ${PROJECT} --sort-order DESCENDING --max-items 1
EOF
