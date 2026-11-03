# Self-hosted Actions runners

Every one of this repository's CI jobs runs on a GitHub-hosted runner
today, and no node registers a self-hosted one. This page describes
the machinery for when one does.

**SNOC deliberately registers none.** Those machines are driven by
hand — `make push-all`, `make perf-run` — and a GitHub Actions job
executing on them is not wanted: the runner user is in the `docker`
group, which is a short path to root, and the nodes hold the registry,
the compiler cache and the tailnet. `manifests/snoc.yml` declares no
`runner` capability and no `runner:` block, so `runner_nodes` is empty
and every play and check over it matches nothing.

The intended home is the AWS profile, where a runner is a rented
instance rather than a desk.

## What a runner is, here

One more thing a node can be declared to be:

```yaml
nodes:
  - name: aws-build-1
    capabilities: [build, metrics, runner]
```

plus a `runner:` block naming the repository. `fleet.py` hard-fails if
a node claims the capability without one — a runner registered against
nothing takes no jobs, and the jobs meant for it queue rather than
error.

`ansible/roles/github_runner` then installs the runner, registers it
and runs it as a systemd service. It is grouped, configured and checked
exactly like every other capability — `runner_nodes` is a group the
same way `cache_nodes` is.

A runner is only useful on a node that can reach the registry and the
compiler cache, which on any profile means a node inside the fleet.

## Labels

Set by [`fleet.runner_labels()`](../architecture/fleet.md), which is
the single definition:

```text
self-hosted, rocm-bake, <fleet>, build, gpu, <arch>
```

so a node on the `aws` fleet registers `self-hosted, rocm-bake, aws,
build`, and the fleet name is what keeps a job aimed at one profile
from landing on another.

`check-contracts.py` asserts that every `runs-on: [self-hosted, …]` in
`.github/workflows/` asks only for labels some runner node registers.
This matters more than it looks: a job whose labels nothing carries
does not fail. GitHub queues it, and keeps queueing it, until the
workflow times out hours later and reports as a slow run. Nothing else
would have told you the label was a typo.

## Fork pull requests, and why an `if:` is not the boundary

A self-hosted runner executes whatever the workflow tells it to, on a
machine with the registry and the compiler cache in reach. A pull
request from a fork is code from outside the repository. Running one
on the fleet is remote code execution on the build machines.

The obvious guard is a job-level condition:

```yaml
# NOT sufficient on its own
if: github.event.pull_request.head.repo.full_name == github.repository
```

That is worth having, and it is not a boundary. `ci.yml` triggers on
`pull_request`, not `pull_request_target`, so the workflow file that
runs for a fork PR is **the fork's copy** — and `.github/workflows/**`
is inside that file's own `paths:` filter. A fork can therefore edit
the condition out in the same pull request that exploits it. The gate
protects against accident, not intent.

This repository is public, which makes the distinction load-bearing.
The controls that actually hold are outside the workflow file:

1. **Require approval for all outside collaborators**, not just
   first-time contributors — Settings → Actions → "Approval for
   running fork pull request workflows". The default lets a second PR
   from the same author run unapproved.
2. **Scope the runner's labels** so that only the jobs meant for it can
   land on it. A fleet-wide `self-hosted` is not a target; `[self-hosted,
   rocm-bake, aws]` is.
3. **Prefer scheduled and dispatch triggers** for anything self-hosted.
   A nightly on `schedule:` runs the default branch's workflow file,
   which no fork can rewrite. This is the reason the Dockerfile checks
   belong in the nightly rather than in the PR gate.

GitHub's own guidance is blunter: do not use self-hosted runners on
public repositories. Treat anything registered here as a machine that
may at some point run a stranger's code, and size its blast radius
accordingly.

## The GitHub App

A runner registers with a token that lasts one hour, so something has
to mint one at apply time. The options were a classic PAT with `repo`
scope living in a vars file forever, or an App. The App wins: its
permission is scoped to Administration on this one repository, its key
never leaves the control host, and every token derived from it expires.

Once, to create it:

1. **Settings → Developer settings → GitHub Apps → New GitHub App.**
   Name it something like `rocm-bake-fleet`. Uncheck Webhook → Active;
   nothing here listens for events.
2. Under **Repository permissions**, set **Administration** to
   **Read & write**. Nothing else.
3. Create it, then **Generate a private key**. A `.pem` downloads —
   this is the only copy.
4. **Install App** → select only `sbates130272/rocm-bake`.
5. Note the **App ID** from the App's settings page, and the
   installation id from the URL of the installation's settings page
   (`.../installations/<id>`).

Then on the control host — the machine you run `make` from, not a
build node:

```bash
mkdir -p ~/.config/rocm-bake
mv ~/Downloads/rocm-bake-fleet.*.private-key.pem \
   ~/.config/rocm-bake/runner-app.pem
chmod 600 ~/.config/rocm-bake/runner-app.pem

# Put these with your other shell secrets, not in the repository.
export ROCM_BAKE_RUNNER_APP_ID=<app id>
export ROCM_BAKE_RUNNER_INSTALLATION_ID=<installation id>
export ROCM_BAKE_RUNNER_KEY=~/.config/rocm-bake/runner-app.pem
```

Check the chain works before involving Ansible:

```bash
python3 -I .builders/gh-app-token.py --registration-token
```

That prints a token and nothing else. It signs an RS256 JWT with
`openssl`, exchanges it for a one-hour installation token, and
exchanges that for the registration token — the three steps GitHub
documents, in about sixty lines, with no dependency outside the
standard library.

## Registering

On a profile whose manifest declares `runner` nodes — not `snoc`:

```bash
FLEET=aws make fleet-runners ANSIBLE_FLAGS=--check   # what would change
FLEET=aws make fleet-runners
FLEET=aws make runner-status                         # what GitHub thinks
FLEET=aws make fleet-check                           # the service, node-side
```

On `snoc` these are no-ops: `runner_nodes` is empty, the play matches
nothing, and `make runner-status` says so.

Then turn the consuming job on. Any self-hosted job should be dormant
until a repository variable says otherwise:

```bash
gh variable set FLEET_RUNNERS --body true
```

This exists because of the queueing behaviour above. With no runner
registered — the state this repository is in by default, and the state
it returns to whenever the fleet is down — an ungated job would make
every triggering push hang until the workflow timed out. Unset it when
taking the fleet offline for any length of time:

```bash
gh variable delete FLEET_RUNNERS
```

`fleet-runners` is `site.yml --tags runner`. Running the whole of
`site.yml` would work too, but it would reconfigure Docker, the
registry and the cache store on the way past, which is not what
"rotate a runner" should mean.

The role is idempotent: it re-registers only when the node is not
already registered under its own name, so a re-run on a healthy fleet
changes nothing and will not drop a runner that is mid-job.

## Upgrading the runner

The runner self-updates in place when GitHub asks it to, so the pinned
version is a floor. To move it, read the new checksum off the release
and record both:

```bash
gh api repos/actions/runner/releases/latest --jq .tag_name
gh api repos/actions/runner/releases/latest --jq .body \
  | grep 'SHA linux-x64'
```

Version into `runner.version` in the manifest, checksum into
`github_runner_sha256_by_version` in the role's defaults. The role
refuses to run without a checksum for the version it was asked for:
the tarball is unpacked by a user in the `docker` group, which is a
short path to root on a build node.

## Retiring a node

Drop `runner` from its capabilities in the manifest, then remove the
registration so GitHub stops scheduling to a machine that will not
answer:

```bash
gh api -X DELETE repos/sbates130272/rocm-bake/actions/runners/<id>
```

`make runner-status` prints the ids. Removing the capability alone
leaves the service running; the node keeps taking jobs until it is
stopped.
