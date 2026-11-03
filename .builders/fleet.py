#!/usr/bin/env python3
"""fleet.py - the one reader of manifests/<fleet>.yml.

Node names, addresses, roles and link speeds used to be literals spread
across eight files: three `builder-snoc-*` targets and THINK_HOST /
GAMING_HOST / GPU_HOST in the Makefile, NODES in balance.sh, the `netmb`
rows in target-costs, DEFAULT_NODES in perfsample.py, SERIES in
perfreport.py, the `snoc-` name filter in builder-health.py, and the
registry host plus search domain in buildkitd-strix.toml. Renaming a
node meant editing all eight; standing the same fleet up elsewhere was
not expressible at all.

They all read this module now, each in the form it can consume:

    fleet.py --make                  KEY=VALUE for the Makefile
    fleet.py --nodes [--capability X]  space-separated builder names
    fleet.py --host <node>           the address to ssh/scrape
    fleet.py --endpoint <node>       local, or ssh://<host>
    fleet.py --netmb                 `netmb <node> <MB/s>` rows
    fleet.py --buildkitd <node>      that node's buildkitd.toml
    fleet.py --table                 what `make list-nodes` prints
    fleet.py --inventory             Ansible dynamic inventory JSON
    fleet.py --json                  the resolved manifest
    fleet.py --check                 validate, print nothing on success

Python callers import it instead:

    fleet = load()                   # or load(Path(...))
    fleet["nodes"], node_map(fleet), series(fleet)

Which manifest: FLEET_MANIFEST if set, else manifests/$FLEET.yml, else
manifests/snoc.yml. Everything is resolved relative to the repository
root, not the caller's cwd, so a script run from anywhere agrees.
"""

import json
import os
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_DIR = ROOT / "manifests"
DEFAULT_FLEET = "snoc"

# Every capability a node may declare. A typo in a manifest is
# otherwise indistinguishable from a node that simply does not have
# that role, and the failure surfaces much later as "no node with
# capability gpu" on a fleet that plainly has one.
CAPABILITIES = {"build", "gpu", "registry", "cache", "metrics", "runner"}

# Ansible group per capability. Spelled out rather than pluralised: the
# obvious `cap + "s"` gives "builds" and "registrys", which read as
# nouns about builds rather than about machines.
GROUP_OF = {
    "build": "builders",
    "gpu": "gpu_nodes",
    "registry": "registry_nodes",
    "cache": "cache_nodes",
    "metrics": "metrics_nodes",
    "runner": "runner_nodes",
}

# The `runner:` block says which repository the runners serve and what
# to install — fleet topology, which belongs in the manifest.
#
# It deliberately does not carry the GitHub App's id, installation id
# or key path. Those are a credential, they differ per operator, and a
# committed placeholder would be both a lie and something CI has to
# pretend to validate. gh-app-token.py reads them from the environment
# of the control host instead; see docs/operations/runners.md.
RUNNER_KEYS = ("repo",)

RUNNER_DEFAULTS = {
    "version": "2.338.2",
    "work_dir": "/var/lib/actions-runner",
    "install_dir": "/opt/actions-runner",
}

REQUIRED_NODE_KEYS = ("name", "host")

# Defaults for keys a manifest may leave out. Only for values where
# "unset" has an obvious meaning; anything load-bearing is required.
BUILDKIT_DEFAULTS = {
    "max_parallelism": 10,
    "gc_keep_storage": "100GB",
    "step_log_max_size": 104857600,
    "step_log_max_speed": 10485760,
}


class FleetError(Exception):
    """A manifest that cannot be used. Always carries what to fix."""


def manifest_path(name=None):
    """Resolve which manifest to read, without reading it."""
    if name:
        return Path(name) if "/" in str(name) else MANIFEST_DIR / f"{name}.yml"
    env = os.environ.get("FLEET_MANIFEST")
    if env:
        return Path(env)
    return MANIFEST_DIR / f"{os.environ.get('FLEET', DEFAULT_FLEET)}.yml"


def load(name=None):
    """Read, validate and normalise a manifest."""
    try:
        import yaml
    except ImportError as exc:                      # pragma: no cover
        raise FleetError(
            "PyYAML is not installed; it is the only dependency this "
            "repository needs outside Docker. apt-get install python3-yaml, "
            "or pip install pyyaml") from exc

    path = manifest_path(name)
    if not path.exists():
        have = sorted(p.stem for p in MANIFEST_DIR.glob("*.yml"))
        raise FleetError(
            f"no such manifest: {path}\n"
            f"  available: {', '.join(have) or '(none)'}\n"
            f"  select one with FLEET=<name> or FLEET_MANIFEST=<path>")
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        raise FleetError(f"{path}: {exc}") from exc
    data["_path"] = str(path)
    return validate(data)


def validate(data):
    """Reject a manifest that would fail somewhere less obvious."""
    where = data.get("_path", "<manifest>")

    def bad(msg):
        raise FleetError(f"{where}: {msg}")

    if not isinstance(data, dict):
        bad("top level is not a mapping")
    nodes = data.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        bad("no `nodes:` list")

    seen = set()
    for i, n in enumerate(nodes):
        if not isinstance(n, dict):
            bad(f"nodes[{i}] is not a mapping")
        for key in REQUIRED_NODE_KEYS:
            if not n.get(key):
                bad(f"nodes[{i}] has no `{key}:`")
        if n["name"] in seen:
            bad(f"duplicate node name {n['name']!r}")
        seen.add(n["name"])
        n.setdefault("connection", "ssh")
        if n["connection"] not in ("local", "ssh"):
            bad(f"{n['name']}: connection must be local or ssh, "
                f"not {n['connection']!r}")
        caps = n.setdefault("capabilities", ["build"])
        unknown = set(caps) - CAPABILITIES
        if unknown:
            bad(f"{n['name']}: unknown capabilities {sorted(unknown)}; "
                f"known: {sorted(CAPABILITIES)}")
        # No link figure is not an error — balance.sh falls back to the
        # build term rather than inventing a speed — but a
        # non-numeric one is, because awk would read it as zero and
        # charge the node an infinite upload.
        if "link_mbps" in n:
            try:
                float(n["link_mbps"])
            except (TypeError, ValueError):
                bad(f"{n['name']}: link_mbps {n['link_mbps']!r} is not a number")

    # Exactly one local node. buildx creates a builder against the
    # local Docker daemon for it, and perf-run reads journald and the
    # nginx log from "here"; two of them would silently mean the wrong
    # machine.
    local = [n["name"] for n in nodes if n["connection"] == "local"]
    if len(local) > 1:
        bad(f"more than one node has connection: local ({', '.join(local)})")

    by_name = {n["name"]: n for n in nodes}

    # Role holders must exist and must claim the capability. A
    # registry pointed at a node that does not run one fails as a
    # connection refused in the middle of a build.
    for role, cap in (("registry", "registry"), ("cache", "cache")):
        block = data.get(role)
        if not isinstance(block, dict) or not block.get("node"):
            bad(f"no `{role}: node:`")
        host = block["node"]
        if host not in by_name:
            bad(f"{role}.node {host!r} is not a node in this manifest")
        if cap not in by_name[host].get("capabilities", []):
            bad(f"{role}.node {host!r} does not declare the {cap!r} capability")

    gpu = data.get("gpu_node")
    if gpu:
        if gpu not in by_name:
            bad(f"gpu_node {gpu!r} is not a node in this manifest")
        if "gpu" not in by_name[gpu].get("capabilities", []):
            bad(f"gpu_node {gpu!r} does not declare the 'gpu' capability")

    builders = [n["name"] for n in nodes if "build" in n["capabilities"]]
    if not builders:
        bad("no node declares the 'build' capability")
    for key in ("default_builder", "bench_node"):
        if key == "default_builder":
            value = data.setdefault(key, builders[0])
        else:
            value = data.get(key)
            if value is None:
                continue
        if value not in by_name:
            bad(f"{key} {value!r} is not a node in this manifest")
        if "build" not in by_name[value]["capabilities"]:
            bad(f"{key} {value!r} does not declare the 'build' capability")

    # A node declared `runner` with no `runner:` block registers
    # against nothing. The job it was meant to take then queues until
    # the workflow times out, which reports as a slow runner rather
    # than a missing one.
    if [n for n in nodes if "runner" in n["capabilities"]]:
        block = data.setdefault("runner", {})
        if not isinstance(block, dict):
            bad("`runner:` is not a mapping")
        for key in RUNNER_KEYS:
            if not block.get(key):
                bad(f"a node declares the 'runner' capability, so "
                    f"`runner:` needs `{key}:`")
        if "/" not in str(block["repo"]):
            bad(f"runner.repo {block['repo']!r} is not owner/name")
        for key, value in RUNNER_DEFAULTS.items():
            block.setdefault(key, value)

    data.setdefault("pool_builder", f"{data.get('name', 'fleet')}-pool")
    bk = data.setdefault("buildkit", {})
    for key, value in BUILDKIT_DEFAULTS.items():
        bk.setdefault(key, value)
    data.setdefault("network", {})
    return data


# ── accessors ────────────────────────────────────────────────────

def node_map(fleet):
    return {n["name"]: n for n in fleet["nodes"]}


def nodes(fleet, capability=None):
    """Node names, manifest order. Order is the fleet's own ranking —
    balance.sh re-sorts by live score, but anything that just needs a
    list (cache-check, the Ansible inventory) presents them this way."""
    return [n["name"] for n in fleet["nodes"]
            if capability is None or capability in n["capabilities"]]


def address(fleet, name):
    return node_map(fleet)[name]["host"]


def endpoint(fleet, name):
    """What `docker buildx create` should be given for this node."""
    n = node_map(fleet)[name]
    return "local" if n["connection"] == "local" else f"ssh://{n['host']}"


def runner_labels(fleet, node):
    """The labels this node's runner registers with.

    A `runs-on:` list that names a label no runner carries does not
    fail — the job sits queued until the workflow times out, which
    reads as a slow fleet rather than a missing one. So this is the one
    definition, check-contracts.py asserts the workflows stay inside
    it, and the Ansible role passes it to `config.sh --labels`.

    `self-hosted` is implicit for every self-hosted runner; it is
    listed anyway because the workflows spell it and the contract check
    compares the two lists literally.
    """
    out = ["self-hosted", "rocm-bake", fleet.get("name", "")]
    out += [c for c in ("build", "gpu") if c in node["capabilities"]]
    if node.get("arch"):
        out.append(node["arch"])
    return [x for x in dict.fromkeys(out) if x]


def registry(fleet):
    r = fleet["registry"]
    return f"{address(fleet, r['node'])}:{r['port']}"


def cache_host(fleet):
    return address(fleet, fleet["cache"]["node"])


def gpu_host(fleet):
    """The address `make gpu-test` and the serving stack reach for.

    Empty when the fleet has no GPU node — an AWS build fleet does not,
    EC2 having no AMD accelerator instance. The callers print that as a
    reason rather than failing on an empty hostname.
    """
    name = fleet.get("gpu_node")
    return address(fleet, name) if name else ""


# Slots of the validated categorical palette, light and dark. A
# manifest may give a node its own `colour:` pair; these are what the
# rest get, in manifest order. Colour follows the node, never its rank,
# so a target that moves between nodes keeps the node's colour.
PALETTE = (
    ("#2a78d6", "#3987e5"),
    ("#eb6834", "#d95926"),
    ("#1baf7a", "#199e70"),
    ("#b0952a", "#c9a93a"),
    ("#2f9fb0", "#3bb5c7"),
    ("#8a5fb8", "#9d74c9"),
)


def series(fleet):
    """builder -> (light, dark), for every node the report may plot."""
    out = {}
    for i, n in enumerate(fleet["nodes"]):
        colour = n.get("colour")
        out[n["name"]] = (tuple(colour) if colour
                          else PALETTE[i % len(PALETTE)])
    return out


def default_nodes(fleet):
    """builder -> exporter host, for the perf sampler."""
    return {n["name"]: n["host"] for n in fleet["nodes"]
            if "metrics" in n["capabilities"]}


# ── renderers ────────────────────────────────────────────────────

def make_vars(fleet):
    """KEY=VALUE lines the Makefile reads in one pass at parse time.

    Same shape as BAKE_DEFAULTS, and read by the same `filter`/`patsubst`
    idiom, so there is one convention for "a value that comes from a
    file" rather than two.

    Lists are comma-separated, not space-separated. $(shell) collapses
    the newlines between these lines into spaces, so a value containing
    a space becomes several words and $(filter NAME=%) returns only the
    first of them — the node list would silently be one node long. The
    Makefile substitutes the commas back.
    """
    out = [
        ("FLEET_NAME", fleet.get("name", "")),
        ("FLEET_MANIFEST_PATH", fleet["_path"]),
        ("FLEET_NODES", ",".join(nodes(fleet, "build"))),
        ("FLEET_ALL_NODES", ",".join(nodes(fleet))),
        ("FLEET_DEFAULT_BUILDER", fleet["default_builder"]),
        ("FLEET_POOL_BUILDER", fleet["pool_builder"]),
        ("FLEET_REGISTRY", registry(fleet)),
        ("FLEET_CACHE_HOST", cache_host(fleet)),
        ("FLEET_CACHE_PORT", str(fleet["cache"]["port"])),
        ("FLEET_CACHE_DIR", fleet["cache"].get("dir", "")),
        ("FLEET_CACHE_BIND", fleet["cache"].get("bind", "tailscale")),
        ("FLEET_BENCH_NODE", fleet.get("bench_node", fleet["default_builder"])),
        ("FLEET_GPU_HOST", gpu_host(fleet)),
        ("FLEET_GPU_NODE", fleet.get("gpu_node", "")),
        ("FLEET_NO_PROXY", ",".join(fleet["network"].get("no_proxy", []))),
    ]
    lines = [f"{k}={v}" for k, v in out]
    # Per-node lookups, as `node=value` word lists. A make variable
    # name cannot safely carry a node name (they contain dashes and
    # would collide with a target), so these are looked up with
    # $(call fleet_host,<node>) instead.
    lines.append("FLEET_HOSTS=" + ",".join(
        f"{n}={address(fleet, n)}" for n in nodes(fleet)))
    lines.append("FLEET_ENDPOINTS=" + ",".join(
        f"{n}={endpoint(fleet, n)}" for n in nodes(fleet)))
    # Build nodes only, for the recipes that walk the fleet in a shell
    # loop. $(call ...) cannot be used inside one — make expands the
    # call before the shell has a loop variable to look up — so those
    # read name=endpoint pairs directly.
    lines.append("FLEET_BUILD_ENDPOINTS=" + ",".join(
        f"{n}={endpoint(fleet, n)}" for n in nodes(fleet, "build")))
    return "\n".join(lines)


def netmb_rows(fleet):
    """The `netmb` rows balance.sh charges a cache export against.

    These live in the manifest rather than in target-costs because they
    describe the fleet, not a target: the build and cache rows in that
    file are measured per target and are the same wherever it runs.
    """
    rows = []
    for n in fleet["nodes"]:
        if "link_mbps" in n:
            rows.append(f"netmb {n['name']} {n['link_mbps']}")
    return "\n".join(rows)


def buildkitd(fleet, name):
    """That node's buildkitd.toml, from .builders/buildkitd.toml.in."""
    n = node_map(fleet)[name]
    tmpl = (ROOT / ".builders" / "buildkitd.toml.in").read_text()

    reg = registry(fleet)
    blocks = [
        f'[registry."{reg}"]\n  http = true\n  insecure = true\n',
    ]
    for upstream in fleet["registry"].get("mirrors", []):
        blocks.append(f'[registry."{upstream}"]\n  mirrors = ["{reg}"]\n')

    nameservers = fleet["network"].get("nameservers", [])
    domain = fleet.get("domain", "")
    if nameservers:
        dns = "[dns]\n  nameservers = " + json.dumps(nameservers)
        if domain:
            dns += f'\n  searchDomains = ["{domain}"]'
        dns += "\n"
    else:
        dns = ("# No [dns] block: this manifest declares no nameservers, so "
               "build\n# steps use buildkit's default resolver.\n")

    bk = fleet["buildkit"]
    subs = {
        "@NODE@": name,
        "@FLEET@": fleet.get("name", ""),
        "@ARCH@": n.get("arch", "unknown"),
        "@PLATFORM@": n.get("platform", "unknown"),
        "@DNS@": dns,
        "@REGISTRIES@": "\n".join(blocks),
        "@MAX_PARALLELISM@": str(bk["max_parallelism"]),
        "@GC_KEEP_STORAGE@": str(bk["gc_keep_storage"]),
    }
    out = tmpl
    for key, value in subs.items():
        out = out.replace(key, value)
    left = [k for k in subs if k in out]
    if left:
        raise FleetError(f"buildkitd.toml.in: unsubstituted {left}")

    # Parse what we just produced. buildkitd's own complaint about a
    # bad config is a line and column number from `docker buildx
    # create`, long after the file that caused it has scrolled away —
    # and the way this first went wrong was a *comment* in the
    # template naming its own placeholders, which the substitution
    # duly replaced with a second copy of two whole tables.
    try:
        tomllib.loads(out)
    except tomllib.TOMLDecodeError as exc:
        raise FleetError(
            f"buildkitd.toml.in renders invalid TOML for {name}: {exc}") from exc
    return out


def table(fleet):
    """What `make list-nodes` prints.

    The first question when a build lands somewhere surprising is which
    manifest is in effect — FLEET is easy to have exported and
    forgotten — so the path leads, before any node is contacted.
    """
    out = [f"fleet {fleet.get('name', '?')}  ({fleet['_path']})"]
    gpu = gpu_host(fleet) or "(none — build-only fleet)"
    out.append(f"  registry {registry(fleet)} · "
               f"cache {cache_host(fleet)}:{fleet['cache']['port']} · "
               f"gpu {gpu}")
    out.append(f"  default builder {fleet['default_builder']} · "
               f"pool sentinel {fleet['pool_builder']}")
    out.append("")
    for n in fleet["nodes"]:
        out.append("  %-14s %-32s %-9s %-6s %8s MB/s  %s" % (
            n["name"], n["host"], n.get("arch", "-"), n["connection"],
            n.get("link_mbps", "-"), ",".join(n["capabilities"])))
    return "\n".join(out)


def inventory(fleet):
    """Ansible dynamic inventory.

    Groups are capabilities, so a play targets `builders` or `cache`
    rather than naming machines — which is the same move this whole
    file is: say what a node is for, not which one it is.
    """
    meta = {}
    groups = {g: {"hosts": []} for g in GROUP_OF.values()}
    groups["all_nodes"] = {"hosts": []}
    for n in fleet["nodes"]:
        host = n["name"]
        groups["all_nodes"]["hosts"].append(host)
        for cap in n["capabilities"]:
            groups[GROUP_OF[cap]]["hosts"].append(host)
        meta[host] = {
            "ansible_host": n["host"],
            "ansible_connection": ("local" if n["connection"] == "local"
                                   else "ssh"),
            "fleet_node": host,
            "fleet_name": fleet.get("name", ""),
            "fleet_manifest_path": fleet["_path"],
            "fleet_arch": n.get("arch", ""),
            "fleet_platform": n.get("platform", ""),
            "fleet_capabilities": n["capabilities"],
            "fleet_link_mbps": n.get("link_mbps"),
            "fleet_registry": registry(fleet),
            "fleet_registry_managed": fleet["registry"].get("managed", False),
            "fleet_registry_port": fleet["registry"]["port"],
            "fleet_cache_host": cache_host(fleet),
            "fleet_cache_port": fleet["cache"]["port"],
            "fleet_cache_dir": fleet["cache"].get("dir", ""),
            "fleet_cache_bind": fleet["cache"].get("bind", "tailscale"),
            "fleet_no_proxy": ",".join(fleet["network"].get("no_proxy", [])),
            "fleet_domain": fleet.get("domain", ""),
        }
        # Absent on a fleet with no runner nodes, so the role's `when:`
        # and check.yml both have something falsy to test rather than
        # erroring on an undefined variable.
        if "runner" in n["capabilities"]:
            r = fleet["runner"]
            meta[host].update({
                "fleet_runner_repo": r["repo"],
                "fleet_runner_version": r["version"],
                "fleet_runner_work_dir": r["work_dir"],
                "fleet_runner_install_dir": r["install_dir"],
                "fleet_runner_labels": runner_labels(fleet, n),
            })
    out = {g: v for g, v in groups.items() if v["hosts"]}
    out["_meta"] = {"hostvars": meta}
    return json.dumps(out, indent=2, sort_keys=True)


# ── cli ──────────────────────────────────────────────────────────

def main(argv):
    args = list(argv)

    def opt(flag):
        if flag in args:
            i = args.index(flag)
            return args[i + 1] if i + 1 < len(args) else ""
        return None

    try:
        fleet = load(opt("--manifest"))
    except FleetError as exc:
        print(f"fleet: {exc}", file=sys.stderr)
        return 1
    except IndexError:
        print("fleet: --manifest needs a value", file=sys.stderr)
        return 2

    if "--check" in args:
        return 0
    if "--make" in args:
        print(make_vars(fleet))
    elif "--nodes" in args:
        print(" ".join(nodes(fleet, opt("--capability"))))
    elif "--netmb" in args:
        print(netmb_rows(fleet))
    elif "--host" in args:
        name = opt("--host")
        if name not in node_map(fleet):
            print(f"fleet: no node {name!r}", file=sys.stderr)
            return 1
        print(address(fleet, name))
    elif "--endpoint" in args:
        name = opt("--endpoint")
        if name not in node_map(fleet):
            print(f"fleet: no node {name!r}", file=sys.stderr)
            return 1
        print(endpoint(fleet, name))
    elif "--buildkitd" in args:
        name = opt("--buildkitd")
        if name not in node_map(fleet):
            print(f"fleet: no node {name!r}", file=sys.stderr)
            return 1
        sys.stdout.write(buildkitd(fleet, name))
    elif "--table" in args:
        print(table(fleet))
    elif "--inventory" in args:
        print(inventory(fleet))
    elif "--json" in args:
        print(json.dumps({k: v for k, v in fleet.items()
                          if not k.startswith("_")},
                         indent=2, sort_keys=True))
    else:
        print(__doc__.strip())
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except FleetError as exc:
        print(f"fleet: {exc}", file=sys.stderr)
        sys.exit(1)
