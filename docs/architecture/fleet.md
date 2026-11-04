# The fleet

A build here needs more than a Dockerfile: it needs machines, a
registry to hand results between them, a compiler cache they all
share, and a scheduler that knows which of them is fast. All of that
used to be written into the tools that use it. `snoc-strix`,
`snoc-think` and `snoc-gaming` appeared as literals in eight files —
the Makefile's builder targets, `balance.sh`'s node list, the `netmb`
rows in `target-costs`, the sampler's exporter map, the report's
colour table, the health check's name filter, and the registry host
and search domain in `buildkitd-strix.toml`. Adding a node meant
editing all eight. Standing the same fleet up somewhere else was not
expressible at all.

One file describes the fleet now.

```yaml
# manifests/snoc.yml
name: snoc
domain: fold-leaffish.ts.net
default_builder: snoc-strix
gpu_node: snoc-think

registry: {node: snoc-strix, port: 8080, managed: false}
cache:    {node: snoc-strix, port: 8081, dir: /var/cache/sccache-webdav}

nodes:
  - name: snoc-think
    host: snoc-thinkstation
    connection: ssh
    arch: gfx1201
    capabilities: [build, gpu, metrics]
    link_mbps: 90
```

```bash
make list-nodes                # which manifest is in effect, and what it says
FLEET=<profile> make list-nodes  # a second manifest, if there is one
```

## What a node declares

| | |
| --- | --- |
| `host` | the address to reach it at. Not the same as `name`: the builder is `snoc-think`, the machine is `snoc-thinkstation`, and there is no `snoc-think` on the tailnet |
| `connection` | `local` or `ssh`. Exactly one node may be `local` |
| `arch` | the card it has — which is **not** the same claim as the `gpu` capability |
| `capabilities` | what it is for, below |
| `link_mbps` | upload throughput to the compiler-cache store |
| `colour` | its series colour in the perf report, optional |

Capabilities are the vocabulary everything else speaks:

| | |
| --- | --- |
| `build` | takes bake targets |
| `gpu` | runs `make gpu-test` and the serving stack |
| `registry` | hosts Zot |
| `cache` | hosts the WebDAV compiler-cache store |
| `metrics` | runs node_exporter on `:9100`, sampled during a perf run |

`arch` versus the `gpu` capability is worth dwelling on, because the
distinction is the one that makes a cloud fleet possible at all.
Compiling for `gfx950` does not need a `gfx950` card — the SNOC fleet
has none and cross-compiles for it every day. A card is needed only to
*run* the result. So `snoc-gaming` has a `gfx1201` and does not get GPU
work, and a cloud builder has no card at all and still builds
everything. A manifest that declares no GPU node says so and stops:

```text
fleet <name> declares no gpu node, so there is nowhere to run this.
Either set GPU_HOST=<host> for a one-off, or give a node the 'gpu'
capability and name it in gpu_node:.
```

That message is the point. Before, `GPU_HOST` was a hostname with a
default, and a fleet without one produced `ssh ''`.

## Who reads it

[`.builders/fleet.py`](https://github.com/sbates130272/rocm-bake/blob/main/.builders/fleet.py)
is the only YAML reader in the repository. Everything else takes the
shape it can consume:

```text
manifests/<fleet>.yml
        │
        └── fleet.py ──┬── --make        → Makefile (node list, registry,
                       │                   cache, GPU host, no_proxy)
                       ├── --nodes       → balance.sh's NODES
                       ├── --netmb       → balance.sh's link-cost term
                       ├── --endpoint    → bench.sh, builder-create.sh
                       ├── --buildkitd   → each builder's buildkitd.toml
                       ├── --inventory   → ansible/inventory/fleet.py
                       └── load()        → perfsample.py, perfreport.py,
                                           builder-health.py
```

The Makefile reads it in one pass at parse time, the same way it reads
`rocm-bake.hcl`:

```make
FLEET_VARS := $(shell python3 -I .builders/fleet.py --make)
fleet_var   = $(patsubst $(1)=%,%,$(filter $(1)=%,$(FLEET_VARS)))
BUILDER    ?= $(call fleet_var,FLEET_DEFAULT_BUILDER)
```

The builder targets follow from the node list rather than being
written out, so a fourth node needs no Makefile edit:

```make
builder-setup: $(addprefix builder-,$(FLEET_NODES))
builder-%:
	@.builders/builder-create.sh $*
```

## Where the boundary with rocm-bake.hcl is

`rocm-bake.hcl` says **what** is built; the manifest says **where**.
Versions, refs, build args and the target graph are bake's. The
registry, the compiler-cache store and which machines exist are the
manifest's — because a second fleet is a second set of those, and
a `FLEET=... make push-all` publishing to the SNOC registry would be the
worst available failure: silent, and onto someone else's machine.

`rocm-bake.hcl` keeps its own `REGISTRY` and `SCCACHE_WEBDAV_*`
defaults for a bare `docker buildx bake` driven without make, and
`check-contracts.py` fails the build if those stop agreeing with the
default manifest.

## The scheduler reads it too

`balance.sh` charges a target's cache export against the node's link,
because the SNOC fleet's uplinks differ by a factor of 25 — 3000 MB/s
for the node hosting the store, 90 wired, 3.7 over WiFi. Scheduling on
build time alone once sent `triton-wheel`'s 6 GB export to the node
behind WiFi, where the upload took ~28 minutes against the ~4 minutes
it took to build.

Those figures are `link_mbps:` in the manifest now, not `netmb` rows in
`target-costs`: they describe the fleet, not a target. The build and
cache costs stay in `target-costs`, because those are the same wherever
the target runs.

A consequence worth knowing: on a fleet whose nodes sit in one AWS
placement group, every `link_mbps` is the same, the network term
cancels, and placement collapses to plain LPT on build time.

## Ansible

The manifest describes the fleet; Ansible makes a machine match it.
Same file, same reader — `ansible/inventory/fleet.py` is a dynamic
inventory over it, and the groups are the capabilities, so a play says
what a node is for rather than naming machines.

```bash
make fleet-apply                      # converge every node
make fleet-apply ANSIBLE_FLAGS=--check
make fleet-check                      # read-only acceptance test
```

| Role | Hosts | What it owns |
| --- | --- | --- |
| `common` | all | base packages, `no_proxy`, tailnet status |
| `docker` | `builders` | daemon config for the fleet registry, version floor |
| `registry` | `registry_nodes` | Zot — installed when `registry.managed`, verified otherwise |
| `sccache_store` | `cache_nodes` | the nginx WebDAV store |
| `node_exporter` | `metrics_nodes` | the exporter and its textfile collector |
| `gpu` | `gpu_nodes` | `/dev/kfd`, the render gid |
| `buildkit` | localhost | the buildx builders, created from here |

Two deliberate restraints. The `registry` role refuses to start a Zot
that the manifest says it does not manage — on SNOC other services
pull through that registry and it is deployed outside this repository.
And the `sccache_store` role copies
[`deploy-webdav.sh`](https://github.com/sbates130272/rocm-bake/blob/main/.builders/deploy-webdav.sh)
to the node and runs it rather than templating the nginx config,
because `check-contracts.py` asserts that script's `log_format` still
parses with the regex `perfreport.py` reads it back with. A second copy
in a Jinja template would be a second thing to keep in step, and the
one that drifted would be the one nothing checks.

`make fleet-check` supersedes `make cache-check`, which asked one of
these questions of a hardcoded list of two hostnames. It asks each node
whether it can reach the registry, read the cache, **write** to the
cache, and export metrics — the write being the one that matters, since
a node that can only read compiles everything it is given and shares
none of it, which looks exactly like a slow node rather than a broken
one.

## Adding a node

1. Add it to `manifests/<fleet>.yml` with its capabilities and a
   measured `link_mbps`.
2. `make list-nodes` — it should appear.
3. `make fleet-apply --limit <node>`.
4. `make builder-<node>`.
5. `.builders/balance.sh --dry-run` — it should be in the plan.

Nothing else needs editing. That is the whole claim.
