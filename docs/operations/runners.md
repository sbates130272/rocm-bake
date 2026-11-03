# Self-hosted Actions runners

Most of this repository's CI runs on GitHub-hosted runners and should
stay there. A handful of checks cannot: they resolve their base image
from the fleet's Zot over the tailnet, and a GitHub-hosted runner gets

```text
failed to do request: Head "https://snoc-strix...:8080/v2/...":
dial tcp: lookup snoc-strix.fold-leaffish.ts.net: no such host
```

Those checks were deleted rather than skipped when CI moved off the
fleet. The `fleet` job in `ci.yml` is where they live now, and this
page is how the runner it targets gets registered.

## What a runner is, here

One more thing a node can be declared to be:

```yaml
nodes:
  - name: snoc-strix
    capabilities: [build, gpu, registry, cache, metrics, runner]
```

`ansible/roles/github_runner` then installs the runner, registers it
and runs it as a systemd service. It is grouped, configured and checked
exactly like every other capability — `runner_nodes` is a group the
same way `cache_nodes` is.

The node is deliberately the one that hosts the registry and the cache.
A runner is only useful here if it can reach both, and that node
reaches them over loopback.

## Labels

Set by [`fleet.runner_labels()`](../architecture/fleet.md), which is
the single definition:

```text
self-hosted, rocm-bake, <fleet>, build, gpu, <arch>
```

so `snoc-strix` registers as `self-hosted, rocm-bake, snoc, build, gpu,
gfx1151`.

`check-contracts.py` asserts that every `runs-on: [self-hosted, …]` in
`.github/workflows/` asks only for labels some runner node registers.
This matters more than it looks: a job whose labels nothing carries
does not fail. GitHub queues it, and keeps queueing it, until the
workflow times out hours later and reports as a slow run. Nothing else
would have told you the label was a typo.

## Fork pull requests do not run here

A self-hosted runner executes whatever the workflow tells it to, on a
machine with the tailnet, the registry and the compiler cache in reach.
A pull request from a fork is code from someone outside the repository.
Running one on the fleet is remote code execution on the build
machines, and no amount of review-before-approve makes it safe, because
the approval gate is per-PR and the attack is a later push to the same
branch.

So the `fleet` job carries:

```yaml
if: >-
  github.event_name != 'pull_request' ||
  github.event.pull_request.head.repo.full_name == github.repository
```

Fork PRs skip it and still get every GitHub-hosted job, including
hadolint over all nine Dockerfiles. This is also why it is a separate
job rather than more steps inside `targets` — the boundary is a job
boundary, where it can be read at a glance.

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

```bash
make fleet-runners ANSIBLE_FLAGS=--check   # what would change
make fleet-runners
make runner-status                         # what GitHub thinks
make fleet-check                           # the service, node-side
```

Then turn the job on. It is dormant until a repository variable says
otherwise:

```bash
gh variable set FLEET_RUNNERS --body true
```

This exists because of the queueing behaviour above. With no runner
registered — the state this repository is in by default, and the state
it returns to whenever the fleet is down for a while — an ungated job
would make every push to `main` hang until the workflow timed out.
Unset it when taking the fleet offline for any length of time:

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
