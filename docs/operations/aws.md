# A fleet on AWS

What to rent, and why, if the fleet runs on EC2 instead of three
machines on a tailnet. The shape is committed as
[`manifests/aws.yml`](https://github.com/sbates130272/rocm-bake/blob/main/manifests/aws.yml);
nothing here provisions anything.

```bash
FLEET=aws make list-nodes
FLEET=aws make fleet-apply     # once the instances exist and resolve
FLEET=aws make push-all BUILDER=aws-pool
```

!!! warning "This fleet cannot run what it builds"
    EC2 has no AMD Instinct or Radeon instance. Every node here is a
    cross-compiler, which is what the SNOC fleet already is — no node
    there has a `gfx950` card either. But `make gpu-test` and the
    serving stack have nowhere to land, so `manifests/aws.yml` declares
    no `gpu_node:` and those targets say so and stop. Keep a GPU host
    on-premises, or point `GPU_HOST=` at one for a single run.

## The shape

| | Instance | Why |
| --- | --- | --- |
| 3 × builder | `m8a.16xlarge` — 64 vCPU, 256 GiB | 4 GiB per vCPU, see below |
| 1 × services | `m8i.2xlarge` — 8 vCPU, 32 GiB | Zot and the WebDAV store; not a builder |

All four in **one availability zone, one cluster placement group**.
Not for latency: for the cache exports, which are the term that
dominates scheduling on the fleet this replaces.

### Why 4 GiB per vCPU, and not 2

`MAX_JOBS` is not configured, it is derived, once, inside the build:

```sh
cores=$(nproc)
jobs=$(awk '/^MemAvailable:/ {print int($2/1024/1024/2)}' /proc/meminfo)
[ "${jobs}" -le "${cores}" ] || jobs=${cores}
```

2 GiB per job is measured for `cc1plus` — triton died at 32 jobs on a
30 GB node. So a node needs **2 GiB of _available_ memory per core** to
use all of them, and available is not total: the page cache, the
BuildKit container and the sccache server are all in the way.

That rules out the compute-optimised families. `c8a.24xlarge` is 96
vCPU and 192 GiB — exactly 2 GiB per vCPU on paper, which in practice
derives a `MAX_JOBS` somewhere in the eighties and leaves a dozen cores
idle through the longest step of the build. You would be paying for
cores the build then declines to use.

`m8a.16xlarge` is 64 physical cores (no SMT on this family) at 4 GiB
each. `MAX_JOBS` lands at 64, and there is room left for the layer
export that follows.

### Why three builders and not one big one

The graph is thirteen targets with real dependencies, and
`balance.sh` packs them longest-first across nodes. One enormous
instance would serialise everything behind `pytorch`; three medium ones
run `triton-wheel`, `cupy-wheel` and `nixl-wheel` alongside it. The
scheduler already refuses to run two targets over the same Dockerfile
at once — `pytorch` and `pytorch-wheel` are two stages over one builder
— so the parallelism it can actually exploit is about three wide.

Three is also what makes the measured per-target costs transfer: the
fleet this replaces has three nodes, and `target-costs` was measured on
it.

### Storage

| | |
| --- | --- |
| Builder root | 400 GiB gp3, 500 MiB/s, 6000 IOPS |
| Services root | 100 GiB gp3 (default throughput) |
| Services store | 1 TiB gp3, 1000 MiB/s, 16 000 IOPS |

Builders hold the BuildKit content store, capped at `gc_keep_storage:
250GB` in `manifests/aws.yml` — raised from the 100 GB the SNOC nodes
use, because the thing worth never doing twice is pulling the 8.67 GB
ROCm base layer. 400 GiB leaves room for that cap plus the images
themselves.

The services volume holds both Zot and the compiler cache, and its
throughput is the fleet's shared ceiling: every builder reads objects
from it during a compile and writes a multi-gigabyte layer export after
one. 1000 MiB/s is gp3's maximum; past that the answer is `io2` Block
Express or a local-NVMe instance family.

**Instance store is the wrong trade here.** It is faster and it is
free, but it does not survive a stop, and the compiler cache being
durable is a design property of this fleet —
[`deploy-webdav.sh`](https://github.com/sbates130272/rocm-bake/blob/main/.builders/deploy-webdav.sh)
says so in its first paragraph. A cache that evaporates on an instance
stop turns every Monday morning into a cold build.

### Networking

One cluster placement group, so inter-node bandwidth is tens of Gbps
rather than the 90 MB/s and 3.7 MB/s the SNOC fleet lives with.

This changes the scheduler's behaviour, and it is the most interesting
consequence of moving:

```text
cost_of(target, node) = build_seconds + cache_bytes / link_mbps
```

On SNOC the second term decides placement — `triton-wheel`'s 6 GB
export is ~1 minute on the node hosting the store and ~28 minutes over
WiFi. Inside a placement group every `link_mbps` is the same, the term
cancels, and placement collapses to plain LPT on build time. The
manifest still carries `link_mbps: 1500` on each builder so the
arithmetic has a figure; it simply stops discriminating.

Keep every node in **one AZ**. Cross-AZ traffic is billed per GB in
both directions, and a cold fleet run moves tens of gigabytes of cache
exports between nodes and the store.

## What this should cost in time

Projections, not measurements. They come from the per-target figures in
[`target-costs`](https://github.com/sbates130272/rocm-bake/blob/main/.builders/target-costs),
measured on `snoc-think` (32 cores, 122 GB), scaled by core count. The
honest error bar is wide: PyTorch's build is not perfectly parallel,
and the gain from 32 to 64 cores is somewhere between 1.4× and 1.9×,
not 2×.

| Scenario | SNOC today | This fleet | What bounds it |
| --- | --- | --- | --- |
| **frozen** | base image egresses | +8–10 min, once | Docker Hub to the Zot pull-through |
| **cold** | `pytorch` at 2336 s is the critical path | ~20–27 min | cores on one builder |
| **warm** | export and import, not compile | ~6–10 min | the services volume's throughput |
| **hot** | nothing recompiles | ~1–2 min | layer-cache metadata round trips |

Two things to take from that table. The cold case is bounded by a
single target on a single node, so a fourth builder buys nothing — the
money goes into cores per builder, up to the point where PyTorch's own
parallelism runs out. And the warm case is bounded by the services
volume, which is why it is provisioned at gp3's ceiling rather than its
default 125 MiB/s.

### Where the money goes

On-demand, the three builders are ~95% of the bill, and they are idle
between builds. Two levers:

- **Stop them.** The manifest is a description, not a lease. `make
  fleet-check` will report them unreachable, and `balance.sh` scores an
  unreachable node at zero and schedules around it — so a fleet with
  one builder running still builds, more slowly.
- **Spot for builders, on-demand for services.** A reclaimed builder
  fails its current target; `balance.sh` reports the failure, lets the
  other nodes finish, and the shared compiler cache means the retry
  recompiles far less than the first attempt did. Never put the
  services node on spot: losing it loses the registry and the cache
  both.

## Two things worth changing if this becomes the main fleet

Both are real work, not configuration, which is why
`manifests/aws.yml` does neither.

**S3 instead of WebDAV.** sccache speaks S3 natively, and on AWS it is
the better store: durable, no instance to run, no volume throughput
ceiling. The fleet uses WebDAV because `dl.min.io` is blocked by the
corporate proxy on the network SNOC lives on and nginx with the DAV
modules is a normal apt install. Moving would mean
`SCCACHE_WEBDAV_*` becoming `SCCACHE_S3_*` across
[`rocm-bake.hcl`](https://github.com/sbates130272/rocm-bake/blob/main/rocm-bake.hcl)
and the Dockerfiles, an instance profile per builder, and
`perfreport.py` losing the nginx access log it currently reads
per-object write sizes from.

**ECR instead of Zot.** Removes a service to run, and its pull-through
cache replaces Zot's `sync` extension. The cost is the OCI artifact
layer cache: BuildKit's `type=registry` cache export works against ECR,
but the two-tier arch-scoped `*-cache` repository scheme this repo uses
would need revisiting against ECR's repository and lifecycle policies.

## Runners, and why Lambda is not the builder

An AWS fleet that only exists while CI is running is the obvious next
thought, and the obvious implementation — a Lambda that runs the job —
does not work. The limits are hard, and every one of them is breached
by a wide margin:

| Lambda limit | | A `pytorch-wheel` build |
| --- | --- | --- |
| 900 s per invocation | vs | hours |
| 10,240 MB memory | vs | 4 GiB per core across 48+ cores |
| 10,240 MB `/tmp` | vs | tens of GB of sources and objects |
| no Docker daemon | vs | BuildKit needs one |

The 15-minute ceiling cannot be raised by request. Lambda Managed
Instances reach 90 minutes for asynchronous and event-source
invocations, which is still an order of magnitude short, and the
memory, storage and daemon problems remain regardless.

Persistent storage does not rescue it. Lambda can mount EFS, and the
10 GB `/tmp` is not the real ceiling — but storage was never the
binding constraint. The timeout, the memory and the absent daemon are,
and none of them moves.

Two things that sound like escapes and are not: Lambda *layers* are
not Docker layers (five maximum, 250 MB unzipped in total), and
Lambda's container-image support means Lambda *running* an image, not
*building* one.

### What runs the nightly instead

The classic answer is a Lambda control plane: a `workflow_job` webhook
to API Gateway, `RunInstances` against a launch template, an
`--ephemeral` runner, a terminate on completion, and a sweep for
instances whose job never arrived. That works, and
[`philips-labs/terraform-aws-github-runner`](https://github.com/philips-labs/terraform-aws-github-runner)
implements it properly.

This repository uses **CodeBuild** instead, which reaches the same
place with far less to own — one project and a webhook, no Lambda, no
launch template, and no builder AMI to keep in step with
`ansible/roles/`. See [CI runners](runners.md) for the project, the
`runs-on` label and the security boundary.

The one trap worth repeating: CodeBuild also offers a **Lambda compute
mode**, and it inherits every restriction in the table above — AWS
documents it as supporting no Docker builds or runs, no privileged
mode, no caching and nothing over 15 minutes. The nightly needs EC2
compute mode.

### Where the parallelism is, and is not

A matrix can ask for as many CodeBuild machines as you like. The build
graph can use about one of them.

`balance.sh` resolves the targets into nine waves. Using the measured
per-target figures in
[`target-costs`](https://github.com/sbates130272/rocm-bake/blob/main/.builders/target-costs),
the total work is 9089 s and the sum of the wave maxima is 8835 s — a
parallelism headroom of roughly **1.03×**. The chain runs
`pytorch-base` → `triton-wheel` → `pytorch-wheel` → `pytorch` → … →
`vllm-wheel` → `vllm`, with two 2336 s targets in the middle of it.
This is the same conclusion the cost table reaches from the other
direction: a fourth builder buys nothing.

Fanning targets out also costs. On one machine, `pytorch`'s inputs are
already in the local BuildKit store when it starts; across machines
that edge becomes a registry pull, and the cache rows in `target-costs`
total ~17.6 GB per run.

So the matrix axis is **architecture**, not target. `gfx950`,
`gfx1201` and `gfx1250` share no edges and no ordering, and `arches-%`
runs them sequentially today — so that is where splitting the work
actually buys something.

!!! note "Two caveats on those numbers"
    They are measured on `snoc-think` (32 cores), not on CodeBuild —
    absolute times will differ, the shape will not. And `pytorch-wheel`
    and `pytorch` are both recorded at 2336 s, as are `vllm-wheel` and
    `vllm` at 1409 s, which looks like one compile attributed to two
    target names. If so the true critical path is shorter than 8835 s
    and the graph is *more* serial, not less.

## Bringing it up

1. Launch four instances in one AZ and one cluster placement group,
   with the volumes above, and make them resolvable as the names in
   `manifests/aws.yml` — a Route 53 private zone, or join them to the
   same tailnet as everything else, which is the smaller change.
2. Install Docker 27+ and add the connecting user to the `docker`
   group. The `docker` role verifies this and refuses to guess at a
   distribution's packaging.
3. Make them reachable as `ssh <host>` from the control host, exactly
   as buildx needs anyway.
4. Then:

```bash
FLEET=aws make fleet-apply ANSIBLE_FLAGS=--check   # what would change
FLEET=aws make fleet-apply
FLEET=aws make fleet-check                         # the acceptance test
FLEET=aws make list-nodes
FLEET=aws .builders/balance.sh --dry-run           # the plan, no build
FLEET=aws make push-all BUILDER=aws-pool
```

Step 4's first command is worth running twice — once before the
instances exist, to see the inventory resolve and the plays match
nothing, and once after.

!!! note "Instance families move"
    `m8a` and `c8a` are 5th Gen EPYC (Turin) and are not in every
    region. Check what the region actually offers before committing to
    a name:

    ```bash
    aws ec2 describe-instance-types \
      --filters Name=instance-type,Values='m8a.*' \
      --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]' \
      --output table
    ```

    The requirement is the shape, not the name: ≥ 48 physical cores,
    ≥ 4 GiB per core, ≥ 25 Gbps, and a volume that can sustain
    500 MiB/s.
