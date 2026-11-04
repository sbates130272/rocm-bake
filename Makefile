# Makefile - convenience wrapper for rocm-pytorch builds

# ─── Defaults ────────────────────────────────────────────────────
# rocm-bake.hcl is the single source for every value a build reads. This
# file does not get to have an opinion about them: it used to carry its
# own copy of ten defaults, which agreed with rocm-bake.hcl only because
# nobody had changed one yet. A `make` target and a bare
# `docker buildx bake` would then have built different images from the
# same tree, and nothing would have said so.
#
# One awk pass over rocm-bake.hcl at parse time, rather than a $(shell) per
# lookup. Handles both spellings in that file — a `default = "..."` on
# its own line, and the single-line `variable "X" { default = "" }`
# form the SDE_* block uses. Values containing spaces would not survive
# the round trip through a word list; none have any, and a default that
# needs one belongs in a target's args rather than here.
#
# POSIX awk only — no 3-argument match(). Ubuntu ships mawk as /usr/bin/awk
# unless gawk is installed, and a gawk-only script here would work on
# this machine and fail on a runner.
BAKE_DEFAULTS := $(shell awk ' \
	/^variable[ \t]*"/ { \
		name = $$0; sub(/^variable[ \t]*"/, "", name); sub(/".*/, "", name) } \
	name != "" && /default[ \t]*=[ \t]*"/ { \
		v = $$0; sub(/^.*default[ \t]*=[ \t]*"/, "", v); sub(/".*/, "", v); \
		printf "%s=%s\n", name, v; name = "" }' rocm-bake.hcl)

# Empty when the variable has no default in rocm-bake.hcl, which for our
# purposes is indistinguishable from an empty default — both mean
# "bake decides".
bake_default = $(patsubst $(1)=%,%,$(filter $(1)=%,$(BAKE_DEFAULTS)))

# ─── The fleet ───────────────────────────────────────────────────
# Which machines exist, what each is for, and how fast its uplink is,
# from manifests/$(FLEET).yml. Same shape as BAKE_DEFAULTS above — one
# pass at parse time producing KEY=VALUE words — so there is one
# convention here for "a value that comes from a file" rather than two.
#
# FLEET selects the manifest; FLEET_MANIFEST takes a path directly.
# Both are read by fleet.py from the environment, hence the export.
FLEET ?= snoc
export FLEET
export FLEET_MANIFEST
FLEET_VARS := $(shell python3 -I .builders/fleet.py --make 2>/dev/null)
ifeq ($(FLEET_VARS),)
$(warning fleet: no usable manifest for FLEET=$(FLEET)$(if $(FLEET_MANIFEST), FLEET_MANIFEST=$(FLEET_MANIFEST)) — run `python3 .builders/fleet.py --check` for the reason)
endif
fleet_var = $(patsubst $(1)=%,%,$(filter $(1)=%,$(FLEET_VARS)))

# fleet.py comma-separates its lists; see make_vars there for why. One
# $(subst) turns a list back into make words.
COMMA := ,
fleet_list = $(subst $(COMMA), ,$(call fleet_var,$(1)))

# Per-node lookups. A node name cannot be a make variable name — they
# carry dashes and would collide with targets — so the manifest's
# node=value pairs are filtered the same way bake_default filters its.
FLEET_NODES     := $(call fleet_list,FLEET_NODES)
FLEET_ALL_NODES := $(call fleet_list,FLEET_ALL_NODES)
FLEET_HOSTS     := $(call fleet_list,FLEET_HOSTS)
FLEET_ENDPOINTS := $(call fleet_list,FLEET_ENDPOINTS)
FLEET_BUILD_ENDPOINTS := $(call fleet_list,FLEET_BUILD_ENDPOINTS)

fleet_host     = $(patsubst $(1)=%,%,$(filter $(1)=%,$(FLEET_HOSTS)))
fleet_endpoint = $(patsubst $(1)=%,%,$(filter $(1)=%,$(FLEET_ENDPOINTS)))

# $(or ...) rather than ?=: the value has to be expanded once here, not
# re-derived at every reference. An environment variable of the same
# name still wins (make imports it, so $(REGISTRY) is already set), and
# a command-line VAR=value overrides the assignment outright — so both
# override paths keep working.
# Where, not what. The manifest owns the fleet's addresses — the
# registry it publishes to and the compiler-cache store it reads —
# because a second fleet is a second set of them and `FLEET=aws make
# push-all` publishing to the SNOC registry would be the worst
# possible failure: silent, and to someone else's machine.
#
# rocm-bake.hcl keeps its own defaults for a bare `docker buildx bake`
# driven without make, and check-contracts.py asserts the default
# manifest still agrees with them. Exported, so bake reads the
# manifest's value from the environment.
REGISTRY          := $(or $(REGISTRY),$(call fleet_var,FLEET_REGISTRY),$(call bake_default,REGISTRY))
export REGISTRY
REGISTRY_NAME     := $(or $(REGISTRY_NAME),$(call bake_default,REGISTRY_NAME))
PYTORCH_VERSION   := $(or $(PYTORCH_VERSION),$(call bake_default,PYTORCH_VERSION))
ROCM_VERSION      := $(or $(ROCM_VERSION),$(call bake_default,ROCM_VERSION))
PYTHON_VERSION    := $(or $(PYTHON_VERSION),$(call bake_default,PYTHON_VERSION))
PYTORCH_ROCM_ARCH := $(or $(PYTORCH_ROCM_ARCH),$(call bake_default,PYTORCH_ROCM_ARCH))

# BUILDER and REPO are make's own: bake has no concept of which node a
# build lands on, nor of which Zot repository `make zot-tags` lists.
# The manifest names the default; a node is addressed by its builder
# name everywhere, and $(call fleet_host,<node>) resolves the machine
# behind it where something has to ssh there — the builder is named
# snoc-think but the machine is snoc-thinkstation, and there is no
# snoc-think on the tailnet.
BUILDER ?= $(call fleet_var,FLEET_DEFAULT_BUILDER)
REPO ?= $(REGISTRY_NAME)/base

# The tailnet must never go through the corporate proxy. HTTP_PROXY and
# HTTPS_PROXY are set in this environment but no_proxy is not, so every
# proxy-aware tool (curl in some modes, python urllib, Go binaries like
# zli and docker) tries to reach the fleet through ZScaler and fails.
# Set it here so make targets are correct regardless of the user's
# shell; add the same to your profile for interactive use. The list
# describes the fleet's network, so it comes from the manifest.
NO_PROXY_LIST := $(call fleet_var,FLEET_NO_PROXY)
export no_proxy := $(NO_PROXY_LIST)
export NO_PROXY := $(NO_PROXY_LIST)

# help lives at the bottom of this file, in its own section, so it is
# no longer the first target. Without this, `make` with no arguments
# would run whatever target happens to come first.
.DEFAULT_GOAL := help

# Colour for help and list-vars, empty when nothing can render it.
# `make help | less` otherwise prints literal ESC[1m through the whole
# page, because less needs -R to interpret them and a pipe cannot ask
# for it. Same for `make help > file`.
#
# MAKE_TERMOUT is how make answers "is my stdout a terminal": set to
# the device when it is, empty when it is not, and set before the
# makefile is read so these can be simple := assignments. A $(shell
# [ -t 1 ]) would not work — the shell's stdout is the pipe make reads
# the result from, never a terminal.
#
# Detection is only a default, because a pipe is not always a pipe to
# something colour-blind: `FORCE_COLOR=1 make help | less -R` is the
# case this exists for, and no amount of looking at fd 1 can tell it
# from `make help | grep`. NO_COLOR and FORCE_COLOR are the usual
# spellings (non-empty wins, either way), so a shell that already
# exports them for other tools gets this one too.
ifeq ($(MAKE_TERMOUT),)
USE_COLOR := $(if $(FORCE_COLOR)$(CLICOLOR_FORCE),1,)
else
USE_COLOR := 1
endif
ifdef NO_COLOR
USE_COLOR :=
endif

ifeq ($(USE_COLOR),)
C_BOLD :=
C_CYAN :=
C_OFF  :=
else
C_BOLD := \033[1m
C_CYAN := \033[36m
C_OFF  := \033[0m
endif

# Aliased so the recipe text does not contain the literal $(MAKE):
# make executes any line referencing $(MAKE) even under -n, which made
# `make -n watch` launch a full-screen watch instead of printing it.
# Where running builds record themselves, for `make build-stop`.
BUILD_PIDFILE ?= /tmp/.rocm-build.pids
export BUILD_PIDFILE

MAKE_BIN := $(MAKE)

# Shared compiler-cache store: nginx WebDAV over a directory tree, so
# it survives a reboot. Which node hosts it, and on which port, is the
# manifest's to say — same argument as REGISTRY above, and bake's own
# defaults are the fallback and the cross-check.
WEBDAV_HOST := $(or $(WEBDAV_HOST),$(call fleet_var,FLEET_CACHE_HOST),$(call bake_default,SCCACHE_WEBDAV_HOST))
WEBDAV_PORT := $(or $(WEBDAV_PORT),$(call fleet_var,FLEET_CACHE_PORT),$(call bake_default,SCCACHE_WEBDAV_PORT))
export SCCACHE_WEBDAV_HOST := $(WEBDAV_HOST)
export SCCACHE_WEBDAV_PORT := $(WEBDAV_PORT)
WEBDAV_URL  ?= http://$(WEBDAV_HOST):$(WEBDAV_PORT)

# Build containers address the store by IP, resolved here once, not by
# name. buildkitd is configured with MagicDNS plus two public
# resolvers; when MagicDNS is slow under load a tailnet lookup falls
# through to a public resolver, which answers NXDOMAIN, after which the
# search domain is appended and the query becomes nonsense:
#
#   DNS error: no records found for Query { name:
#     Name("snoc-strix.fold-leaffish.ts.net.fold-leaffish.ts.net.") }
#
# That hit both reads and writes — 79 of 361 compiles in one triton
# build — so objects were recompiled and then thrown away. The name
# stays the configuration surface; only the containers see an address.
WEBDAV_IP   ?= $(shell getent hosts $(WEBDAV_HOST) 2>/dev/null | awk '{print $$1; exit}')
SCCACHE_WEBDAV_ENDPOINT ?= http://$(or $(WEBDAV_IP),$(WEBDAV_HOST)):$(WEBDAV_PORT)
export SCCACHE_WEBDAV_ENDPOINT
WEBDAV_DIR  ?= $(call fleet_var,FLEET_CACHE_DIR)

# A sentinel, not a builder. BUILDER=$(POOL_BUILDER) means "let the
# balancer choose"; requests for it are routed through
# .builders/balance.sh, which runs each target against a concrete node.
# Nothing is ever built against a buildx pool now, so the pool builder
# need not exist — and if it does, its records never update, which is
# why watch skips it.
# Reclaim its containers with: docker buildx rm $(POOL_BUILDER)
POOL_BUILDER ?= $(call fleet_var,FLEET_POOL_BUILDER)

# Every build goes through the telemetry wrapper: it runs the bake, then
# records duration, layer-cache hit ratio and sccache counters, and exits
# with the bake's own status. TELEMETRY=0 for a bare bake.
# Provenance for the image tags and OCI labels. VCS_REF gets a -dirty
# suffix when the tree has uncommitted changes, so an image built from
# edited sources can never be mistaken for the commit it came from.
VCS_REF ?= $(shell git rev-parse --short HEAD 2>/dev/null)$(shell git diff --quiet 2>/dev/null || echo -dirty)
# The commit's own timestamp, not "now". OCI's `created` is meant to
# describe the artifact, and wall-clock time made every rebuild of the
# same commit produce a different image config — hence a different
# digest, invalidating every downstream FROM. Falls back to now outside
# a git tree.
BUILD_DATE ?= $(shell git log -1 --format=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
export VCS_REF
export BUILD_DATE

# Identifies a run in the build records: it is the last component of
# every target's BUILDKIT_BUILD_NAME, and the column `make build-status`
# and `make watch` print. The bake default is "dev", which made every
# build since the beginning of time look like the same run.
#
# `:=`, not `?=`. A recursively-expanded `?=` re-runs its $(shell) at
# every reference, so a timestamp would differ between two uses inside
# one build. VCS_REF above gets away with `?=` only because a commit
# hash is stable. $(or $(RUN_ID),...) keeps the override: make imports
# the environment, and a command-line RUN_ID=x beats the assignment.
#
# Safe to vary per build. RUN_ID reaches no layer: it appears only in
# BUILDKIT_BUILD_NAME, which is a reserved BuildKit frontend arg that
# no Dockerfile declares as an ARG, so it cannot enter any build
# environment or any cache key. That was worth checking before making
# it change on every invocation.
RUN_ID := $(or $(RUN_ID),$(shell date -u +%Y%m%dT%H%M%SZ)-$(VCS_REF))
export RUN_ID

# SOURCE_DATE_EPOCH used to be computed and exported from here, one
# value per image. It lives in rocm-bake.hcl now — see the SDE_EPOCH block
# there for why it is a constant rather than a date from git history.
# Overriding one image's epoch is still possible, and still per image:
#
#   make build-pytorch BAKE_EXTRA='--set pytorch.args.SOURCE_DATE_EPOCH=...'
#
# or SDE_PYTORCH=... in the environment, which bake reads directly.

TELEMETRY ?= 1
ifeq ($(TELEMETRY),0)
BAKE = docker buildx bake -f rocm-bake.hcl
else
BAKE = ./telemetry/build.sh
endif

# Bake without the telemetry wrapper, for the recipes that want to read
# bake's own output rather than run a build. build.sh prints timings and
# sccache stats around the build, so $(BAKE) --print is not parseable
# JSON — it fed jq a progress line and failed with a parse error.
BAKE_PRINT = docker buildx bake -f rocm-bake.hcl

.PHONY: help zot-check zot-catalog zot-tags zot-wheels zot-wheelhouse zot-logs \
        image-sizes image-data image-publish zot-disk \
        builder-setup builder-pool list-nodes fleet-apply fleet-check \
        builder-status builder-logs builder-restart \
        build-status build-logs build-inspect builder-ensure watch \
        build-stop gpu-test \
        serve-vllm serve-stack serve-wait serve-down serve-status \
        serve-test serve-test-baseline serve-test-l2 \
        serve-logs serve-logs-cache serve-logs-sorted \
        build-cold push-aiter-wheel fetch-aiter-wheel push-wheels _push-wheels \
        build-torch-wheel build-triton-wheel build-aiter-wheel \
        _build-all _push-all \
        push-torch-wheel fetch-torch-wheel \
        push-triton-wheel fetch-triton-wheel \
        push-nixl-wheel build-nixl-wheel fetch-nixl-wheel \
        push-cupy-wheel build-cupy-wheel fetch-cupy-wheel \
        build-vllm push-vllm push-vllm-wheel build-vllm-wheel fetch-vllm-wheel \
        build-lmcache push-lmcache push-lmcache-wheel build-lmcache-wheel \
        fetch-lmcache-wheel \
        build-serving push-serving \
        cache-summary cache-check cache-logs builder-load \
        perf-plan perf-cold perf-warm perf-report perf-runs perf-serve \
        perf-serve-stop perf-serve-status perf-publish \
        layer-summary \
        list-vars \
        build-rocm-runtime push-rocm-runtime \
        build-pytorch-src push-pytorch-src \
        build-base build-pytorch build-runtime build-all \
        push-base push-pytorch push-runtime push-all \
        clean clean-cache test \
        bench bench-report bench-data bench-publish \
        docs-deps docs-build docs-serve \
        version-check version-scrub version-scrub-check \
        validate bake-plan setup \
        arches-list arches-push-all arches-push-wheels \
        arches-perf-warm arches-perf-cold

# ─── Zot Registry ────────────────────────────────────────────────
# zot runs as a bare-metal systemd service on Strix, deployed and owned
# outside this repo. These targets inspect it; they never start or stop
# it, because other services on the fleet pull through the same registry.
##@ OCI Registry (Zot)

zot-check: ## Verify the Zot registry is reachable
	@systemctl is-active --quiet zot \
		&& echo "zot.service: active" \
		|| echo "zot.service: NOT active (remote node, or not running here)"
	@curl -sf http://$(REGISTRY)/v2/_catalog > /dev/null \
		&& echo "Zot registry is ready at $(REGISTRY)" \
		|| { echo "Zot registry unreachable at $(REGISTRY)"; exit 1; }

zot-catalog: ## List repositories in the Zot registry
	@curl -sf http://$(REGISTRY)/v2/_catalog | python3 -m json.tool

# curl, not docker: the Docker CLI cannot enumerate tags in a registry.
# `docker search` only queries Docker Hub, and `docker manifest inspect`
# needs a tag you already know. Listing them is a registry API call.
zot-tags: ## List tags for a repo (REPO=rocm-pytorch/base)
	@curl -sf http://$(REGISTRY)/v2/$(REPO)/tags/list 2>/dev/null | python3 -m json.tool 2>/dev/null \
		|| echo "No such repository in $(REGISTRY): $(REPO)"

# Wheel artifacts are plain images whose only payload is /wheels, so
# they show up in the catalog like anything else — this filters to them.
# Every target with a `wheel` stage. nixl, vllm and lmcache were
# missing, so the three newest artifacts were published and invisible
# here — the same way the serving stack was absent from the layer
# panel. Keep in step with the `wheels` group in rocm-bake.hcl.
WHEEL_REPOS ?= pytorch-wheel triton-wheel aiter-wheel \
               nixl-wheel cupy-wheel vllm-wheel lmcache-wheel

# How many tags zot-wheels shows per repo, newest first. Every build
# adds a tag and nothing removes them, so the full list is mostly
# history. ZOT_TAGS=0 for all of it.
ZOT_TAGS ?= 5
zot-wheels: ## List wheel artifacts published to Zot, newest first
	@python3 .builders/wheelhouse.py --brief --limit $(ZOT_TAGS) \
		"$(REGISTRY)" "$(REGISTRY_NAME)" $(WHEEL_REPOS)

zot-wheelhouse: ## Show published wheel artifacts and their sizes
	@python3 .builders/wheelhouse.py "$(REGISTRY)" "$(REGISTRY_NAME)" $(WHEEL_REPOS)
	@if [ -d dist/wheels ]; then \
		echo "  --- extracted locally (./dist/wheels) ---"; \
		ls -1sh dist/wheels/ | tail -n +2 | sed 's/^/      /'; \
	fi

zot-logs: ## Follow Zot registry logs
	@sudo journalctl -u zot -f

# ─── Image sizes ─────────────────────────────────────────────────
# The run images — the ones that get pulled onto a GPU host — and the
# layer-cache repos. zot-wheelhouse above sizes the wheel artifacts,
# which are scratch images whose payload is a few hundred MB; these are
# the multi-gigabyte ones and nothing sized them until now.
#
# The column that matters is `shared`, not `total`: a layer digest that
# appears under more than one repository is shared, and an image whose
# own contribution is a fraction of its total has a base-image problem
# rather than a problem of its own. That is how one 8.67 GB ROCm SDK
# layer came to be 71-95% of every published image here.
IMAGE_REPOS ?= rocm-runtime base pytorch runtime vllm lmcache

# Every repo buildkit exports a layer cache to. Keep in step with the
# cache-to refs in rocm-bake.hcl: pytorch-wheel and lmcache-wheel share
# their sibling's cache repo and so are deliberately absent.
CACHE_REPOS ?= rocm-runtime-cache base-cache pytorch-cache runtime-cache \
               vllm-cache lmcache-cache triton-wheel-cache \
               aiter-wheel-cache cupy-wheel-cache nixl-wheel-cache

# IMAGE_ARCH, not PYTORCH_ROCM_ARCH directly, so one table can be asked
# for while a build for another architecture is in flight. Scoping to
# one arch is not cosmetic: `shared` counts a layer digest carried by
# more than one image, so a table mixing gfx950 and gfx1250 reports
# every layer as unshared and the `own` column — the one that matters —
# becomes wrong.
IMAGE_ARCH ?= $(PYTORCH_ROCM_ARCH)

image-sizes: ## Published image sizes, split into shared and own layers
	@python3 .builders/imagesizes.py "$(REGISTRY)" "$(REGISTRY_NAME)" \
		--images $(IMAGE_REPOS) --wheels $(WHEEL_REPOS) \
		--caches $(CACHE_REPOS) --arch "$(IMAGE_ARCH)" \
		$(if $(LAYERS),--layers,)

# What the documentation site plots. Under dist/ for the same reason
# BENCH_JSON is: generated, gitignored, and published to gh-pages
# rather than committed to main.
IMAGE_JSON ?= dist/images/images.json

image-data: ## Aggregate published image sizes into dist/images/images.json
	@python3 .builders/imagesizes.py "$(REGISTRY)" "$(REGISTRY_NAME)" \
		--images $(IMAGE_REPOS) --wheels $(WHEEL_REPOS) \
		--caches $(CACHE_REPOS) --arch "$(IMAGE_ARCH)" --json $(IMAGE_JSON)

# Same flow and the same gate as bench-publish: the data only exists on
# this fleet, the docs workflow preserves data/ when it deploys, and the
# numbers are public the moment they land, so pushing needs PUSH=1.
#
# The file is read before it is overwritten, not clobbered: images.json
# carries its own history array, and the copy on gh-pages is the only
# place the older points exist.
image-publish: ## Publish image sizes onto gh-pages (PUSH=1 to push)
	@dir=$$(.builders/ghpages.sh $(GH_PAGES_DIR) $(GH_PAGES_BRANCH)); \
	mkdir -p $(dir $(IMAGE_JSON)); \
	if [ -f "$$dir/data/images.json" ] && [ ! -f $(IMAGE_JSON) ]; then \
		cp "$$dir/data/images.json" $(IMAGE_JSON); \
	fi; \
	$(MAKE) --no-print-directory image-data; \
	mkdir -p "$$dir/data"; \
	cp $(IMAGE_JSON) "$$dir/data/images.json"; \
	git -C "$$dir" add data; \
	git -C "$$dir" diff --cached --quiet \
		&& echo "no change to publish" \
		|| git -C "$$dir" commit -s \
			-m "data: refresh published image sizes"; \
	if [ "$(PUSH)" = 1 ]; then \
		git -C "$$dir" push origin HEAD:$(GH_PAGES_BRANCH); \
	else \
		echo; \
		echo "Committed locally. To publish:"; \
		echo "  git -C $$dir push origin HEAD:$(GH_PAGES_BRANCH)"; \
		echo "or re-run with PUSH=1."; \
	fi

# What the registry actually costs on disk, which is not the sum of the
# sizes above. Two corrections pull in opposite directions and both are
# large: summing manifests double-counts every layer two tags share,
# while Zot's dedupe and its untagged-manifest GC remove blobs no
# manifest references any more.
#
# Worth having next to the per-image numbers precisely because the
# per-image numbers invite the wrong conclusion. The cache repos look
# like hundreds of GB of unbounded growth summed by tag; they are in
# fact five fixed tags each — latest, latest-<arch>, latest-<arch>-ref
# — overwritten on every build, with Zot collecting what that orphans.
#
# Best-effort and host-local: this reads a directory that only exists
# on the node running Zot, so it degrades to a line of output
# elsewhere, the same way cache-summary does.
zot-disk: ## Actual deduplicated disk used by the registry
	@dir=$$(sudo python3 -c "import json;print(json.load(open('/etc/zot/config.json'))['storage']['rootDirectory'])" 2>/dev/null); \
	if [ -z "$$dir" ] || ! sudo test -d "$$dir"; then \
		printf '  registry storage not readable here (Zot runs on %s)\n' "$(WEBDAV_HOST)"; \
	else \
		printf '  %-22s %s\n' "$$dir" "$$(sudo du -sh "$$dir" 2>/dev/null | cut -f1)"; \
		printf '  %-22s %s\n' "$$dir/$(REGISTRY_NAME)" \
			"$$(sudo du -sh "$$dir/$(REGISTRY_NAME)" 2>/dev/null | cut -f1)"; \
		df -h "$$dir" 2>/dev/null | tail -1 \
			| awk '{printf "  %-28s %s of %s used, %s free\n", "filesystem", $$3, $$2, $$4}'; \
	fi

# ─── Buildx Builder Setup ────────────────────────────────────────
##@ Compiler Cache

# The sccache store every node shares: nginx WebDAV over a directory
# tree on Strix, so a power cycle does not cost the fleet its cache.
#
# WebDAV has no stats verb, so the store itself can only report size
# and object count. Hit rates come from sccache, which prints
# --show-stats at the end of each build; telemetry/build.sh parses that
# into rocm_build_sccache_hit_ratio, which is where cache-summary reads
# it from.
# The other cache. sccache stores compiler objects; this is buildkit's
# layer reuse, and the two move independently — a Dockerfile edit can
# drop layer reuse to 5% while sccache still serves every compile.
#
# Keyed by image, not by node. Which node a target ran on is an
# artefact of scheduling — the balancer moves targets between nodes run
# to run — so a per-node view answers "what did this machine last do"
# when the question is "how much of this image did we rebuild". The
# node is still shown, because it explains a low number: a target that
# moved nodes cannot use the previous node's local buildkit cache and
# must refetch from Zot.
layer-summary: ## Layer reuse on the most recent build of each image
	@printf '\033[36m══ layer reuse\033[0m  (shared cache: Zot on %s)\n' "$(WEBDAV_HOST)"
	@timeout 40 python3 .builders/history.py --by-image $(WATCH_BUILDERS) 2>/dev/null

CACHE_STATE := /tmp/.rocm-cache-prev

# One target, not two. cache-stats and cache-summary read the same
# store and were split only by how much they printed, so the pair gave
# two partial answers and you had to know which: stats had the endpoint
# and the disk, summary had the deltas, neither had both. This is the
# union.
#
# Totals alone say nothing about the build in front of you, hence the
# delta since the previous call — the number that moves while a build
# runs — and now a rate, because "+412 objects" means something quite
# different over eight seconds than over an hour.
#
# The hit rate used to be the line "see 'sccache --show-stats' in the
# build log", which is a pointer, not a statistic. telemetry/build.sh
# already parses exactly that output into
# rocm_build_sccache_hit_ratio, so the number is sitting in the
# textfile collector; read it from there instead of sending someone to
# a log. It is per-target and from the last build of each, which is why
# the target name is printed with it.
#
# Every lookup is best-effort. This runs inside `make watch`'s refresh
# loop, so a missing sudo, an unmounted store or an absent telemetry
# file must degrade to a line of output rather than break the panel.
cache-summary: ## Compiler-cache state: size, disk, deltas and hit rates
	@printf '\033[36m══ sccache store (WebDAV, durable)\033[0m\n'
	@curl -sf -o /dev/null -m 5 -w "  endpoint  HTTP %{http_code}  $(WEBDAV_URL)\n" "$(WEBDAV_URL)/" \
		2>/dev/null || echo "  endpoint  UNREACHABLE  $(WEBDAV_URL)"
	@objs=$$(sudo find $(WEBDAV_DIR) -type f 2>/dev/null | wc -l); \
	size=$$(sudo du -sb $(WEBDAV_DIR) 2>/dev/null | cut -f1); \
	now=$$(date +%s); \
	if [ -z "$$size" ]; then \
		printf '  store     unreadable at %s\n' "$(WEBDAV_DIR)"; \
	else \
		printf '%s %s %s\n' "$$objs" "$$size" "$$now" > $(CACHE_STATE).now; \
		[ -s $(CACHE_STATE) ] || cp $(CACHE_STATE).now $(CACHE_STATE); \
		paste $(CACHE_STATE).now $(CACHE_STATE) \
		| awk '{ \
			o=$$1; b=$$2; t=$$3; po=$$4; pb=$$5; pt=$$6; \
			printf "  objects   %d  size=%.2fGB\n", o, b/1073741824; \
			dt = (pt > 0 && t > pt) ? t - pt : 0; \
			if (o - po <= 0) \
				printf "  interval  idle (no new objects%s)\n", \
					dt ? sprintf(" in %ds", dt) : " since last refresh"; \
			else if (dt > 0) \
				printf "  interval  +%d objects  +%.0fMB  (%.1f obj/s, %.1fMB/s over %ds)\n", \
					o-po, (b-pb)/1048576, (o-po)/dt, ((b-pb)/1048576)/dt, dt; \
			else \
				printf "  interval  +%d objects  +%.0fMB\n", o-po, (b-pb)/1048576; \
			}'; \
		mv $(CACHE_STATE).now $(CACHE_STATE); \
	fi
	@df -h $(WEBDAV_DIR) 2>/dev/null | tail -1 \
		| awk '{printf "  disk      %s of %s used, %s free\n", $$3, $$2, $$4}' \
		|| true
	@prom=$$(ls -t telemetry/out/*.prom /var/lib/node_exporter/textfile_collector/*.prom 2>/dev/null | head -1); \
	if [ -n "$$prom" ]; then \
		awk -F'[{}]' '/^rocm_build_sccache_hit_ratio\{/ { \
			split($$2, a, "\""); t = a[2]; \
			if (!(t in r)) ord[++n] = t; \
			r[t] = $$3 + 0 } \
		END { \
			line = ""; \
			for (i = 1; i <= n; i++) \
				line = line sprintf("  %s %.0f%%", ord[i], r[ord[i]]*100); \
			if (n) printf "  hit rate %s  (last build of each)\n", line; \
			else print "  hit rate  not recorded yet — no build has published sccache stats" \
		}' "$$prom"; \
	else \
		echo "  hit rate  no telemetry file found"; \
	fi

# Every build node in the manifest, named as the builder rather than
# the machine: that is the name the rest of the fleet tooling prints,
# and the endpoint beside it says where it actually ran.
cache-check: ## Verify every build node can reach the compiler cache
	@for pair in $(FLEET_BUILD_ENDPOINTS); do \
		n=$${pair%%=*}; e=$${pair#*=}; \
		printf '  %-14s %-26s ' "$$n" "$$e"; \
		if [ "$$e" = local ]; then \
			curl -sf -o /dev/null -w 'HTTP %{http_code}' "$(WEBDAV_URL)/" || printf UNREACHABLE; \
		else \
			ssh -n -o BatchMode=yes "$${e#ssh://}" "curl -sf -o /dev/null -w 'HTTP %{http_code}' '$(WEBDAV_URL)/'" 2>/dev/null \
				|| printf UNREACHABLE; \
		fi; \
		echo; \
	done

SCCACHE_LOG_FILE ?= /var/log/nginx/sccache.log

# Falls back to the shared access.log for a node whose nginx predates
# the dedicated vhost log. Re-run .builders/deploy-webdav.sh to get the
# sized format perfreport.py reads.
cache-logs: ## Follow the WebDAV store's access log
	@if sudo test -f $(SCCACHE_LOG_FILE); then \
		sudo tail -f $(SCCACHE_LOG_FILE); \
	else \
		echo "note: $(SCCACHE_LOG_FILE) absent — re-run .builders/deploy-webdav.sh"; \
		echo "      for per-object write sizes. Falling back to access.log."; \
		sudo tail -f /var/log/nginx/access.log; \
	fi

##@ Fleet

# One builder per node in the manifest. This was three hand-written
# targets that differed only in a name and an endpoint, and could not
# describe a fourth node without a fourth copy; the work is in
# .builders/builder-create.sh now, and the node list comes from
# manifests/$(FLEET).yml.
#
# Remote nodes join over SSH to their Docker daemons, not the
# remote/TLS driver: buildx creates and owns a buildkit container on
# each, so a remote node needs neither buildkitd, nor TLS certs, nor
# the buildx plugin installed.
builder-setup: $(addprefix builder-,$(FLEET_NODES)) ## Setup a builder for every node in the manifest (one node: builder-<node>)
	@echo "builders: $(FLEET_NODES)"

# A pattern rule, so `make builder-snoc-think` still works and a node
# added to the manifest needs no Makefile edit. Every explicit
# builder-* target below (status, logs, restart, health, load, ensure,
# pool) wins over this: make prefers an explicit rule to a pattern.
#
# The pool name routes to --pool, so the `make builder-$(POOL_BUILDER)`
# spelling that predates this still does what it says.
builder-%:
	@.builders/builder-create.sh $*

# One buildx builder holding every node. buildx spreads independent
# targets across its nodes, so `docker buildx bake --builder $(POOL_BUILDER)`
# uses the whole fleet — but it selects by platform, not by capacity,
# which is why `make push-all BUILDER=$(POOL_BUILDER)` goes through
# balance.sh instead and this builder need not exist at all.
builder-pool: ## Setup a buildx pool holding every build node
	@.builders/builder-create.sh --pool

# What the manifest says, before anything tries to reach a machine.
# The first question when a build lands somewhere surprising is which
# manifest is in effect, and FLEET is easy to have exported and
# forgotten.
list-nodes: ## Show the fleet manifest in effect and the nodes it declares
	@python3 -I .builders/fleet.py --table

# Ansible owns the state of a node — packages, daemon configuration,
# the registry, the compiler-cache store, the exporter — and reads the
# same manifest through the same fleet.py. These two targets exist so
# the entry point is still `make`; everything they do is in ansible/.
ANSIBLE_FLAGS ?=
fleet-apply: ## Bring every node to the state the manifest claims (ANSIBLE_FLAGS=--check)
	@command -v ansible-playbook >/dev/null \
		|| { echo "ansible-playbook not found: apt-get install ansible"; exit 1; }
	@cd ansible && ansible-playbook site.yml $(ANSIBLE_FLAGS)

fleet-check: ## Can every node do the job the manifest says it has?
	@command -v ansible-playbook >/dev/null \
		|| { echo "ansible-playbook not found: apt-get install ansible"; exit 1; }
	@cd ansible && ansible-playbook check.yml $(ANSIBLE_FLAGS)

##@ Monitoring

builder-status: ## Show all builders and their nodes
	@docker buildx ls

# The buildkitd *daemon* log, which is a different thing from a build
# log: scheduling, cache GC, registry auth and connection failures. Use
# `make watch` or `docker buildx history logs` for the steps of a build.
# The container lives on whichever node the endpoint points at, so a
# remote node's log has to be fetched over SSH.
builder-logs: ## Tail buildkitd's own log for each node of $(BUILDER)
	@docker buildx inspect $(BUILDER) 2>/dev/null \
		| awk '/^Name:[[:space:]]+[^[:space:]]/ {n=$$2} /^Endpoint:/ {print n, $$2}' \
		| while read node endpoint; do \
			echo "══ $$node ($$endpoint)"; \
			case "$$endpoint" in \
				ssh://*) ssh -n "$${endpoint#ssh://}" \
					"docker logs --tail $(WATCH_LINES) buildx_buildkit_$$node 2>&1" ;; \
				*) docker logs --tail $(WATCH_LINES) "buildx_buildkit_$$node" 2>&1 ;; \
			esac; \
		done

# `history logs` streams and never returns while a build is in flight, so
# it is bounded by timeout(1). Killing the stream makes the client print
# "rpc error: code = Canceled", once per refresh, which reads like a
# build failure and is not one — hence the grep. Buffer through a file
# rather than piping
# straight to tail: when timeout kills docker mid-pipe the buffered
# output is lost and the shell prints "Terminated" into the display.
WATCH_INTERVAL ?= 5
WATCH_LINES ?= 20
# Build records shown per builder. The full list grows without bound and
# pushes the running build off screen.
WATCH_HISTORY ?= 5
# A busy builder answers its control API slowly - a node saturating
# its uplink on a cache export measured 9.2s against 0.08s for an idle
# one. At the old 3s this timed out, SIGTERMed the docker client, and
# the client's "got 1 SIGTERM/SIGINTs, forcing shutdown" was captured
# into WATCH_TMP and printed straight into the panel. The filter below
# already dropped one flavour of that noise; it now drops the rest,
# and the timeout is no longer tighter than a loaded node's latency.
WATCH_LOG_TIMEOUT ?= 12

WATCH_TMP := /tmp/.rocm-build-watch.log
# Every snoc-* builder, so a build started on any node shows up. The pool
# keeps its own buildkit instances separate from the single-node
# builders, so it has its own history and is listed in its own right.
# Override to narrow: make watch WATCH_BUILDERS=snoc-think
#
# From builder-health.py, which already parses `docker buildx ls` and
# caches the result, rather than running it again here.
#
# Memoised rather than plain `?=` or `:=`, because neither works:
#
#   ?=  is recursive, so every reference re-runs the probe. The watch
#       recipe names it three times, so `make watch` paid for three —
#       and with a node down a probe waits out its ssh timeout, 40s
#       here, so watch sat silent for two minutes before painting.
#   :=  expands once, but at *parse* time, which means every target
#       pays it. `make help` cold took 40s.
#
# The $(eval) rewrites this variable to a simple one on first use, so
# the probe happens at most once and only for targets that actually
# ask. Override still works: `?=` defers to an environment value, and a
# command-line WATCH_BUILDERS= overrides the assignment outright.
WATCH_BUILDERS ?= $(eval WATCH_BUILDERS := $(shell python3 .builders/builder-health.py --list 2>/dev/null))$(WATCH_BUILDERS)

watch: ## Live build history across all snoc-* builders (WATCH_BUILDERS=, WATCH_LINES=)
	@command -v watch > /dev/null || { echo "watch(1) not found: apt-get install procps"; exit 1; }
	@# Warm the health cache before entering the loop, which reads it
	@# with --cached-only and must never block. Not --refresh: the
	@# WATCH_BUILDERS expansion above has usually just populated it, and
	@# this respects that. It only probes when the cache is stale, or
	@# when WATCH_BUILDERS was given explicitly so nothing warmed it.
	@printf 'checking builder health... '
	@python3 .builders/builder-health.py --list > /dev/null 2>&1 || true
	@printf '\r                            \r'
	@watch -n $(WATCH_INTERVAL) -t --color ' \
		printf "\\033[1mROCm PyTorch Build\\033[0m — watching %s · refresh %ss · %s\\n" \
			"$(strip $(WATCH_BUILDERS))" "$(WATCH_INTERVAL)" "$$(date +%H:%M:%S)"; \
		echo; \
		$(MAKE_BIN) --no-print-directory layer-summary; \
		echo; \
		$(MAKE_BIN) --no-print-directory cache-summary; \
		echo; \
		$(MAKE_BIN) --no-print-directory perf-serve-status; \
		echo; \
		for b in $(WATCH_BUILDERS); do \
			out=$$(python3 .builders/history.py $$b $(WATCH_HISTORY) 2>/dev/null); \
			[ -n "$$out" ] || continue; \
			h=$$(python3 .builders/builder-health.py --status $$b --cached-only 2>/dev/null); \
			case "$$h" in \
				running)  hc="\\033[32m" ;; \
				inactive) hc="\\033[33m" ;; \
				*)        hc="\\033[31m" ;; \
			esac; \
			printf "\\033[36m══ %s\\033[0m  $$hc%s\\033[0m\\n" "$$b" "$$h"; \
			echo "$$out"; \
			run=$$(timeout 8 docker buildx history ls --builder $$b \
				--filter status=running --format "{{.Ref}}" 2>/dev/null); \
			if [ -n "$$run" ] || [ -s $(LOAD_CACHE).busy.$$b ]; then \
				[ -n "$$run" ] && touch $(LOAD_CACHE).busy.$$b || rm -f $(LOAD_CACHE).busy.$$b; \
				$(MAKE_BIN) --no-print-directory builder-load BUILDER=$$b; \
			fi; \
			echo; \
		done; \
		for b in $(WATCH_BUILDERS); do \
			for id in $$(docker buildx history ls --builder $$b \
					--filter status=running --format "{{.Ref}}" 2>/dev/null); do \
				printf "\\033[36m──── %s / %s ────\\033[0m\\n" "$$b" "$$id"; \
				timeout $(WATCH_LOG_TIMEOUT) docker buildx history logs "$$id" --builder $$b \
					> $(WATCH_TMP) 2>&1 || true; \
				grep -v "^$$" $(WATCH_TMP) \
					| grep -vE "rpc error: code = Canceled|SIGTERM/SIGINT|error during connect|context canceled|failed to list workers" \
					| tail -$(WATCH_LINES); \
				echo; \
			done; \
		done'



# Build targets depend on this, not on builder-snoc-strix: hardcoding one
# builder as the prerequisite meant `make push-base BUILDER=snoc-think`
# created snoc-strix and made it the default, then built somewhere else.
# Restart buildkitd on each node of $(BUILDER). This is how you clear a
# build that is wedged — a stuck upload, or one left retrying after an
# infrastructure fault. It drops that node's in-memory build state; the
# registry layer cache and the shared compiler cache are untouched.
builder-restart: ## Restart buildkitd for $(BUILDER), clearing stuck builds
	@docker buildx inspect $(BUILDER) 2>/dev/null \
		| awk '/^Name:[[:space:]]+[^[:space:]]/ {n=$$2} /^Endpoint:/ {print n, $$2}' \
		| while read node endpoint; do \
			echo "restarting buildkitd on $$node ($$endpoint)"; \
			case "$$endpoint" in \
				ssh://*) ssh -n "$${endpoint#ssh://}" \
					"docker restart buildx_buildkit_$$node" > /dev/null ;; \
				*) docker restart "buildx_buildkit_$$node" > /dev/null ;; \
			esac; \
		done
	@echo "done"

# Per-node load. Kept as its own target so `watch` can re-enter make
# rather than inlining a second layer of quoting inside its shell string.
LOAD_CACHE := /tmp/.rocm-load
builder-load: ## Show CPU, cores and load for each node of $(BUILDER)
	@timeout 10 docker buildx inspect $(BUILDER) 2>/dev/null \
		| awk '/^Name:[[:space:]]+[^[:space:]]/ {n=$$2} /^Endpoint:/ {print n, $$2}' \
		| while read node endpoint; do \
			case "$$endpoint" in \
				ssh://*) stats=$$(timeout 6 ssh -n -o BatchMode=yes "$${endpoint#ssh://}" \
					"docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' buildx_buildkit_$$node 2>/dev/null; nproc; uptime" 2>/dev/null) ;; \
				*) stats=$$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' "buildx_buildkit_$$node" 2>/dev/null; nproc; uptime) ;; \
			esac; \
			cpu=$$(echo "$$stats" | sed -n 1p | cut -d'|' -f1); \
			mem=$$(echo "$$stats" | sed -n 1p | cut -d'|' -f2); \
			cores=$$(echo "$$stats" | sed -n 2p); \
			load=$$(echo "$$stats" | sed -n 3p | sed 's/.*load average: //'); \
			line=$$(printf '   %-14s cpu=%-9s of %s cores   mem=%-22s load=%s' \
				"$$node" "$$cpu" "$$cores" "$$mem" "$$load"); \
			if [ -n "$$cpu" ] && [ -n "$$cores" ]; then \
				echo "$$line" > "$(LOAD_CACHE).$$node"; \
				printf '\033[32m%s\033[0m\n' "$$line"; \
			elif [ -s "$(LOAD_CACHE).$$node" ]; then \
				printf '\033[32m%s\033[0m  (stale)\n' "$$(cat $(LOAD_CACHE).$$node)"; \
			else \
				printf '   %-14s (load unavailable)\n' "$$node"; \
			fi; \
		done

build-stop: ## Stop builds started from this repo (balancer, bake clients)
	@.builders/build-stop.sh

build-status: ## List build records for $(BUILDER), with the node each ran on
	@python3 .builders/history.py $(BUILDER) $(WATCH_HISTORY)

# The steps of a build, as opposed to builder-logs which is the daemon.
# Defaults to the most recent record; pass BUILD=<id> for a specific one.
BUILD ?=
build-logs: ## Show build-step logs (BUILD=<id>, default: most recent)
	@id="$(BUILD)"; \
	[ -n "$$id" ] || id=$$(docker buildx history ls --builder $(BUILDER) \
		--format "{{.Ref}}" 2>/dev/null | head -1); \
	[ -n "$$id" ] || { echo "No build records on $(BUILDER)"; exit 1; }; \
	echo "══ $$id"; \
	timeout 10 docker buildx history logs "$$id" --builder $(BUILDER) 2>&1 \
		| grep -v "rpc error: code = Canceled" || true

build-inspect: ## Duration, steps and cache stats (BUILD=<id>, default: most recent)
	@id="$(BUILD)"; \
	[ -n "$$id" ] || id=$$(docker buildx history ls --builder $(BUILDER) \
		--format "{{.Ref}}" 2>/dev/null | head -1); \
	[ -n "$$id" ] || { echo "No build records on $(BUILDER)"; exit 1; }; \
	docker buildx history inspect "$$id" --builder $(BUILDER)

# Existence is not readiness. `docker buildx inspect` succeeds for a
# builder whose buildkitd is wedged — snoc-gaming has sat in `error`
# state and passed this check — so the build then started, ran for as
# long as it took the endpoint to give up, and failed. Ask for the
# status instead; see .builders/builder-health.py for what each one
# means and why `inactive` is allowed through.
builder-ensure:
	@[ "$(BUILDER)" = "$(POOL_BUILDER)" ] && exit 0; \
	python3 .builders/builder-health.py --check $(BUILDER)

builder-health: ## Show which builders can take work (buildx node status)
	@python3 .builders/builder-health.py $(if $(ALL),--all,)

# ─── Build Targets ───────────────────────────────────────────────
# One canned recipe for every bake invocation. This used to be nine
# copy-pasted blocks, and they had drifted: each push-* target ran the
# build with no --push, then a SECOND bake with --push but no target
# name — which builds and pushes the whole default group. `make
# push-base` would have kicked off the full PyTorch build.
#
#   $(1) bake target ("" = the default group)
#   $(2) extra flags (--push)
#   $(3) non-empty to resolve inputs from the registry
#
# $(3) is for a rule that names ONE target. Its dependencies are not
# being built here, so taking them from the registry is both correct
# and what the caller meant: `make push-runtime` rebuilt rocm-runtime,
# base and pytorch from scratch — including a 482s PyTorch clone — to
# produce an image whose inputs were published that morning.
#
# It must NOT be set for a rule that bakes a GROUP. Group members feed
# each other through `target:` contexts, PUBLISHED_INPUTS collapses
# those to registry refs, and bake resolves every ref before it pushes
# anything — so a sibling built in the same invocation is not there
# yet. push-serving, push-all and push-wheels build the graph on one
# builder precisely because of that, and they stay as they are.
#
# PUBLISHED_INPUTS is read from the environment by rocm-bake.hcl
# rather than passed with --set, because it selects which `contexts`
# block a target gets, not an arg value.
define bake
@echo $$$$ >> $(BUILD_PIDFILE); \
b="$(BUILDER)"; \
if [ "$$b" = "$(POOL_BUILDER)" ]; then \
	b=$$(.builders/balance.sh --best); \
	echo "balance: $(POOL_BUILDER) -> $$b"; \
fi; \
$(if $(3),PUBLISHED_INPUTS=1 PYTORCH_ROCM_ARCH=$(PYTORCH_ROCM_ARCH) \
	python3 -I .builders/depgraph.py --preflight $(1) || exit 1; \
	PUBLISHED_INPUTS=1) \
$(BAKE) \
	--builder "$$b" \
	--set "*.args.REGISTRY=$(REGISTRY)" \
	--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
	--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
	--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
	--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
	--set "*.args.PYTORCH_ROCM_ARCH=$(PYTORCH_ROCM_ARCH)" \
	$(BAKE_EXTRA) $(2) $(1)
endef

##@ Build

# The ROCm SDK cut down to one architecture and flattened. Everything
# else builds FROM this; see docs/reference/image-sizes.md.
# PyTorch's source tree, fetched once. Keyed on PYTORCH_VERSION and
# GIT_REF alone, so this is rebuilt when the version moves and at no
# other time — not when ROCm, Python, the prune or the architecture
# change. See docker/Dockerfile.pytorch-src.
#
# Worth building on its own before a cold run: `pytorch`,
# `pytorch-wheel` and `pytorch-test` all take this copy, and a cold
# run cannot hand it to them itself.
build-pytorch-src: builder-ensure ## Fetch the PyTorch source tree (no push)
	$(call bake,pytorch-src)

push-pytorch-src: builder-ensure ## * Fetch and publish the PyTorch source tree
	$(call bake,pytorch-src,--push,pub)

build-rocm-runtime: builder-ensure ## Build the pruned ROCm base image
	$(call bake,rocm-runtime)

push-rocm-runtime: builder-ensure ## * Build and push the pruned ROCm base
	$(call bake,rocm-runtime,--push,pub)

build-base: builder-ensure ## Build ROCm base image
	$(call bake,pytorch-base)

build-pytorch: builder-ensure ## Build PyTorch (depends on base)
	$(call bake,pytorch)

build-runtime: builder-ensure ## Build runtime image (depends on pytorch)
	$(call bake,pytorch-run)

# The wheels had push-only targets. Building one without publishing it
# is wanted when the registry is unavailable or unwritable — and the
# benchmark harness needs exactly that, since the credential helper
# cannot decrypt outside an interactive session.
build-torch-wheel: builder-ensure ## Build the torch wheel image (no push)
	$(call bake,pytorch-wheel)

build-triton-wheel: builder-ensure ## Build the Triton wheel image (no push)
	$(call bake,triton-wheel)

build-aiter-wheel: builder-ensure ## Build the AITER wheel image (no push)
	$(call bake,aiter-wheel)

# Not offered for the pool. Scheduling across nodes makes every target
# its own bake invocation, so they cannot hand results to each other
# through `target:` contexts — stage 2 would build against whatever is
# already in Zot rather than what stage 1 just produced, silently. On a
# single builder the contexts resolve in-process and this is fine.
build-all: ## Build every * target (images and wheels) — single builder only
	@if [ "$(BUILDER)" = "$(POOL_BUILDER)" ]; then \
		echo "build-all cannot use $(POOL_BUILDER): targets are scheduled across"; \
		echo "nodes as separate builds, so they can only exchange results"; \
		echo "through the registry. Use one of:"; \
		echo "  make push-all  BUILDER=$(POOL_BUILDER)   # scheduled, publishes"; \
		echo "  make build-all BUILDER=snoc-think        # single builder, no push"; \
		exit 1; \
	fi
	@$(MAKE_BIN) --no-print-directory _build-all BUILDER=$(BUILDER)

_build-all: builder-ensure
	$(call bake,)

# A genuinely cold build: no layer cache AND no compiler-cache hits.
# --no-cache alone is not cold — sccache would still serve every object
# from the shared store, and the build would finish in minutes while
# measuring nothing. SCCACHE_RECACHE=true forces every compile to run and
# repopulate. Use it to measure true build cost, not for routine builds.
COLD_TARGET ?= pytorch

build-cold: builder-ensure ## Fully cold build (no layer or compiler cache). COLD_TARGET=
	@echo "Cold build of $(COLD_TARGET) on $(BUILDER): no layer cache, no sccache hits."
	$(call bake,$(COLD_TARGET),--no-cache --set "*.args.FORCE_RECACHE=true")

# ─── Push Targets ────────────────────────────────────────────────
# --push replaces the image output, so these build and push in one pass
# rather than building twice.
##@ Push

push-base: builder-ensure ## * Build and push base image
	$(call bake,pytorch-base,--push,pub)

push-pytorch: builder-ensure ## * Build and push PyTorch
	$(call bake,pytorch,--push,pub)

push-runtime: builder-ensure ## Build and push runtime image
	$(call bake,pytorch-run,--push,pub)

BALANCE_STREAM ?= 1

push-all: ## Build and push everything (* targets) — the usual way to build
	@if [ "$(BUILDER)" = "$(POOL_BUILDER)" ]; then \
		BALANCE_STREAM=$(BALANCE_STREAM) .builders/balance.sh; \
	else \
		$(MAKE_BIN) --no-print-directory _push-all BUILDER=$(BUILDER); \
	fi

_push-all: builder-ensure
	$(call bake,,--push)

# Same pool/node split as push-all, and for the same reason. The old
# recipe called bake directly, so BUILDER=snoc-pool resolved through
# `balance.sh --best` — which returns a single node by definition. Every
# one of the six wheel targets then built on that one machine while the
# other two sat idle.
#
# The target set is bake's `wheels` group plus the two images the
# wheels build on. pytorch and pytorch-base are not wheels and are not
# in that group, but every wheel resolves one or both of them from the
# registry — so naming only the group would either rebuild nothing
# usable or, worse, schedule wheels against an image no run creates.
# balance.sh orders them from the bake graph; nothing here says when.
push-wheels: ## Push the wheel artifacts (torch, triton, aiter, nixl, vllm, lmcache)
	@if [ "$(BUILDER)" = "$(POOL_BUILDER)" ]; then \
		BALANCE_STREAM=$(BALANCE_STREAM) \
		TARGETS="$$(python3 -I .builders/depgraph.py --group wheels) pytorch pytorch-base" \
			.builders/balance.sh; \
	else \
		$(MAKE_BIN) --no-print-directory _push-wheels BUILDER=$(BUILDER); \
	fi

_push-wheels: builder-ensure
	$(call bake,wheels,--push)

##@ Multi-GFX

# The archs the fleet BUILDS FOR, which are not the archs it runs:
# snoc-strix is gfx1151 and the other two are gfx1201, so gfx950 — the
# default — is cross-compiled by every node. PYTORCH_ROCM_ARCH stays
# single-valued and still defaults to gfx950, so every existing target
# is unchanged; this is the list the arches-* wrappers fan out over.
#
# gfx1250 (MI450) is in the list without being in the fleet. The
# builders already cross-compile — the two gfx1201 nodes build gfx950
# today — so having no such card only means `make test` and `make
# gpu-test` cannot cover it, not that it cannot be built. The ROCm 10.1
# toolchain in our base image compiles it:
#   clang -x hip --offload-arch=gfx1250 -nogpulib -c   # exits 0
# Note it is NOT RDNA despite the gfx12 number; see ARCH_RDNA_TEST in
# rocm-bake.hcl for what that would otherwise have broken.
#
# Each arch is a full pass over every target, so this list is a
# multiplier on build time. Narrow it per invocation when iterating:
#   make arches-push-all ARCHES=gfx950
#
# A space-separated list of single archs, not the ";"-separated form
# PYTORCH_ROCM_ARCH takes. Those are different things: "gfx950;gfx1201"
# is one fat build carrying both code objects, while ARCHES is two
# builds producing two separately-tagged sets of artifacts. The fat
# build is still available — set PYTORCH_ROCM_ARCH to the ";" form —
# but it costs both compiles and ships every card the larger binary.
ARCHES ?= gfx950 gfx1201 gfx1250

# `make arches-push-all`, `make arches-build-pytorch`, `make
# arches-push-wheels` — any target, once per arch. Sequential: the
# archs contend for the same three builders and the same sccache store,
# so running them concurrently just makes both slower.
#
# Safe to repeat now that rocm-bake.hcl scopes the layer cache by arch
# (CACHE_ARCH). Before that, alternating archs through this loop would
# have been the worst case for it — each pass evicting the last.
arches-%:
	@set -e; for a in $(ARCHES); do \
		printf '\n\033[36m== %s  PYTORCH_ROCM_ARCH=%s\033[0m\n' "$*" "$$a"; \
		$(MAKE_BIN) --no-print-directory "$*" \
			PYTORCH_ROCM_ARCH="$$a" BUILDER=$(BUILDER); \
	done

# The pattern rule above covers any target, which is flexible and
# invisible. A pattern has no name, so it reaches neither `make help`
# — which matches `^[a-zA-Z0-9_-]+:.*?## ` — nor shell completion,
# which reads explicit targets out of the make database. The result is
# a wrapper nobody can discover and the shell will not finish for you.
#
# So the ones worth reaching for get a real target each, over one
# macro. An explicit target cannot delegate to the pattern rule by
# name — `arches-push-all` would match itself and recurse — so the
# loop lives here and both forms run the same thing.
define arches_fanout
@set -e; for a in $(ARCHES); do \
	printf '\n\033[36m== %s  PYTORCH_ROCM_ARCH=%s\033[0m\n' "$(1)" "$$a"; \
	$(MAKE_BIN) --no-print-directory "$(1)" \
		PYTORCH_ROCM_ARCH="$$a" BUILDER=$(BUILDER); \
done
endef

arches-push-all: ## Build and push every target, for every arch in ARCHES
	$(call arches_fanout,push-all)

arches-push-wheels: ## Build and push just the wheels, every arch
	$(call arches_fanout,push-wheels)

arches-perf-warm: ## Instrumented warm build, every arch in ARCHES
	$(call arches_fanout,perf-warm)

arches-perf-cold: ## Instrumented cold build, every arch in ARCHES
	$(call arches_fanout,perf-cold)

arches-list: ## Show the archs the arches-* wrappers fan out over
	@printf 'ARCHES = %s\n' "$(ARCHES)"
	@for a in $(ARCHES); do \
		printf '  %-10s pytorch:%s-%s-%s\n' "$$a" \
			"$(PYTORCH_VERSION)" "$(ROCM_VERSION)" "$$a"; \
	done
	@printf '\nusage: make arches-push-all        # every target, every arch\n'
	@printf '       make arches-push-wheels     # just the wheel artifacts\n'
	@printf '       make arches-perf-warm       # instrumented, caches live\n'
	@printf '       make arches-perf-cold       # instrumented, from nothing\n'
	@printf '\nThose four are real targets, so help lists them and the shell\n'
	@printf 'completes them. Any other make target also works through the\n'
	@printf 'arches-%% pattern rule, undiscoverably:\n'
	@printf '       make arches-build-pytorch ARCHES=gfx1201\n'

# ─── Per-arch pip index ──────────────────────────────────────────
# The wheels this repo builds have arch-independent filenames — torch
# is torch-2.14.1a0+git5c48869-cp314-cp314-linux_x86_64.whl whether it
# was compiled for gfx950 or gfx1201 — so the arch has to live in the
# path. One PEP 503 index per arch, selected by index URL, with a
# generated rocm-torch metapackage in each offering a device-<arch>
# extra that pins the whole set. See .builders/wheelindex.py.
WHEELS_DIR ?= dist/wheels
INDEX_DIR  ?= dist/index

# Fetched by arch-specific tag, never :latest. :latest is written by
# whichever arch was pushed last and the wheels inside cannot be told
# apart afterwards, which is the entire failure this index exists to
# prevent. The tags come from bake --print rather than being rebuilt
# here: rocm-bake.hcl owns tag construction (PUB_* and ARCH_TAG), and a
# second copy in the Makefile is exactly the drift check-defaults.py
# exists to catch.
wheel-index: ## Fetch each arch's wheels and build a pip index (ARCHES=)
	@set -e; \
	for a in $(ARCHES); do \
		dest="$(WHEELS_DIR)/$$a"; \
		rm -rf "$$dest"; mkdir -p "$$dest"; \
		echo "== $$a"; \
		for t in $(WHEEL_REPOS); do \
			ref=$$(PYTORCH_ROCM_ARCH="$$a" $(BAKE_PRINT) --print "$$t" 2>/dev/null \
				| jq -r ".target[\"$$t\"].tags[0]"); \
			printf '   %-16s %s\n' "$$t" "$$ref"; \
			printf 'FROM %s\n' "$$ref" \
				| docker buildx build --builder $(BUILDER) \
					--output type=local,dest="$$dest" - 2>/dev/null \
				|| { echo "   (not published for $$a — skipped)"; continue; }; \
		done; \
		if [ -d "$$dest/wheels" ]; then \
			mv "$$dest"/wheels/*.whl "$$dest"/ 2>/dev/null || true; \
			[ -f "$$dest/wheels-arch.txt" ] || true; \
		fi; \
		python3 .builders/wheelindex.py "$$dest" --arch "$$a" \
			--out "$(INDEX_DIR)/$$a" --version "$(ROCM_VERSION)" \
			--python "$(PYTHON_VERSION)"; \
	done
	@printf '\nserve it with:  python3 -m http.server 8081 --directory dist\n'
	@printf 'install with:   pip install \\\n'
	@printf '                  --index-url http://<host>:8081/index/<arch>/ \\\n'
	@printf '                  --extra-index-url https://pypi.org/simple \\\n'
	@printf '                  "rocm-torch[device-<arch>]"\n'

# --extra-index-url is not optional. --index-url replaces PyPI outright,
# so without it the first wheel with an ordinary dependency (numpy, via
# triton-kernels) fails to resolve. download.pytorch.org has the same
# property and the same workaround.
#
# --ignore-requires-python for the same reason the Dockerfiles use it:
# LMCache v0.5.6 declares ">=3.10,<3.14" and this lane is cp314
# throughout. See docker/Dockerfile.lmcache, which carries the full
# rationale. wheelindex.py names every wheel this applies to rather
# than letting the flag hide them.
wheel-index-check: ## Install each generated index into a throwaway venv
	@set -e; \
	port=8099; \
	python3 -m http.server $$port --directory dist >/dev/null 2>&1 & \
	srv=$$!; trap 'kill '"$$srv"' 2>/dev/null || true' EXIT; sleep 2; \
	for a in $(ARCHES); do \
		[ -d "$(INDEX_DIR)/$$a" ] || { echo "no index for $$a — run make wheel-index"; continue; }; \
		v=$$(mktemp -d); python3 -m venv "$$v" >/dev/null; \
		echo "== $$a"; \
		no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost \
		"$$v/bin/pip" install -q --no-cache-dir --ignore-requires-python \
			--index-url "http://127.0.0.1:$$port/index/$$a/" \
			--extra-index-url https://pypi.org/simple \
			"rocm-torch[device-$$a]" \
			&& "$$v/bin/pip" list 2>/dev/null | sed 's/^/     /'; \
		rm -rf "$$v"; \
	done

##@ Performance

# ─── Performance runs ────────────────────────────────────────────
# A cold, parallel, instrumented build of every wheel, and the report
# that comes out of it. Separate from bench.sh on purpose: bench
# serialises to get clean per-target numbers, this one runs the fleet
# flat out and measures what that looks like. Both are useful; they
# answer different questions and must not be confused in a report.
PERF_ARCH ?= $(PYTORCH_ROCM_ARCH)

perf-plan: ## Show which builder each wheel would land on (no build)
	@PYTORCH_ROCM_ARCH=$(PERF_ARCH) .builders/perfrun.sh --dry-run

perf-cold: ## Cold parallel build of every wheel, fully instrumented
	@PYTORCH_ROCM_ARCH=$(PERF_ARCH) .builders/perfrun.sh

# The same instrumentation on an ordinary build: caches on, results
# pushed, the fleet's real sccache store. perf-cold answers "what does
# this cost from nothing"; this answers "what does a build I would
# actually run look like", and both land in the same report and the
# same live chart.
perf-warm: ## Instrumented *warm* build — caches on, pushes to Zot
	@PYTORCH_ROCM_ARCH=$(PERF_ARCH) .builders/perfrun.sh --warm

perf-report: ## Render the newest perf run as markdown + SVG charts
	@python3 .builders/perfreport.py $(PERF_RUN)

# The `||` has to hang off the whole thing, not off ls: in a pipeline
# the exit status is the last command's, so sed succeeding on empty
# input swallowed ls's failure and the target printed nothing at all.
# PERF_PORT=, PERF_BIND=, PERF_RUN=, PERF_REFRESH= all pass through.
# Defaults to the newest run; binds every interface because the usual
# viewer is a laptop on the LAN rather than on the tailnet.
perf-serve: ## Serve the newest run's interactive chart (PERF_PORT=8090)
	@.builders/perfserve.sh

# Ctrl-C in the terminal that started it does the same thing; this is
# for the usual case, where that terminal is long gone and the server
# has been exposing 0.0.0.0 for days.
#
# Signal the parent only and let its EXIT trap reap the regen loop and
# the http.server. TERM, never KILL: SIGKILL skips the trap and leaves
# both children orphaned, still rewriting .current every cycle, which
# is the mess perfserve's own port-claim guard exists to apologise for.
#
# Parentage is read for every match before anything is signalled, which
# is why this is two loops rather than one. Killing the parent inside
# the loop reparents the regen loop to init first, so by the time its
# turn came its ppid no longer named a perfserve and it was reported as
# "stopping" — an already-dead process, named as if it had been missed.
# The grace loop is why this reports rather than escalating — anything
# still alive after it wants looking at, not a bigger hammer.
#
# [p]erfserve, not perfserve: pgrep matches whole command lines, and
# this recipe's own shell has the pattern in its argv. The literal
# form matched that shell, so the recipe killed itself halfway through
# and the server survived. pgrep excludes itself but not its parent.
#
# Anchored, too, so a match is a server and not a command line that
# merely mentions one — `nohup .builders/perfserve.sh >log` names the
# script and is not the script, and killing that wrapper signals
# nothing the trap would hear. make exec's the recipe shell, so a real
# server's argv ends at the script with no sh -c left in between.
perf-serve-stop: ## Stop a running perf-serve (and free PERF_PORT)
	@port=$${PERF_PORT:-8090}; \
	pids=$$(pgrep -f '[p]erfserve\.sh$$' 2>/dev/null); \
	if [ -z "$$pids" ]; then \
		echo "no perfserve running"; \
	else \
		tops=; \
		for p in $$pids; do \
			ppid=$$(ps -o ppid= -p "$$p" 2>/dev/null | tr -d ' '); \
			echo "$$pids" | grep -qx "$$ppid" && continue; \
			tops="$$tops $$p"; \
		done; \
		for p in $$tops; do \
			echo "stopping perfserve $$p"; \
			kill "$$p" 2>/dev/null || true; \
		done; \
		for _ in 1 2 3 4 5 6 7 8 9 10; do \
			pgrep -f '[p]erfserve\.sh$$' >/dev/null 2>&1 || break; \
			sleep 0.5; \
		done; \
	fi; \
	left=$$(pgrep -f '[p]erfserve\.sh$$' 2>/dev/null); \
	if [ -n "$$left" ]; then \
		echo "still running after SIGTERM: $$left" >&2; \
		ps -o pid,ppid,etime,cmd -p $$(echo $$left | tr ' ' ',') >&2; \
		exit 1; \
	fi; \
	if ss -ltn "sport = :$$port" 2>/dev/null | grep -q LISTEN; then \
		echo "port $$port is still held by something else:" >&2; \
		ss -ltnp "sport = :$$port" 2>/dev/null >&2; \
		exit 1; \
	fi; \
	echo "port $$port free"

# One line, for the watch panel. A perf-serve binds 0.0.0.0 by default
# and outlives the terminal that started it, so "is one up, and where"
# is otherwise a pgrep away at exactly the moment you are not thinking
# about it — this one has been found three days old.
#
# The port comes from the http.server child's argv, not from PERF_PORT:
# the variable says what the next server would use, and the question
# here is what the running one *did* use. Same for the bind address,
# which is why an exposed server reads differently from a loopback one
# rather than both printing a URL that looks equally safe.
perf-serve-status: ## Show whether a perf-serve is running, and where
	@pids=$$(pgrep -f '[p]erfserve\.sh$$' 2>/dev/null); \
	if [ -z "$$pids" ]; then \
		printf '\033[36m══ perf-serve\033[0m  not running\n'; \
		exit 0; \
	fi; \
	for p in $$pids; do \
		srv=$$(pgrep -a -P "$$p" -f 'http\.server' 2>/dev/null | head -1); \
		[ -n "$$srv" ] || continue; \
		port=$$(echo "$$srv" | sed -n 's/.*http\.server \([0-9]*\).*/\1/p'); \
		bind=$$(echo "$$srv" | sed -n 's/.*--bind \([^ ]*\).*/\1/p'); \
		up=$$(ps -o etime= -p "$$p" 2>/dev/null | tr -d ' '); \
		case "$$bind" in \
			0.0.0.0|"") host=$$(hostname -I 2>/dev/null | awk '{print $$1}'); \
				where="http://$$host:$$port/  \033[33mLAN-visible\033[0m" ;; \
			*) where="http://$$bind:$$port/" ;; \
		esac; \
		printf '\033[36m══ perf-serve\033[0m  %b  pid %s  up %s\n' \
			"$$where" "$$p" "$$up"; \
	done

perf-runs: ## List collected performance runs, newest last
	@found=$$(ls -1d /var/tmp/rocm-perf/*/ 2>/dev/null); \
	if [ -n "$$found" ]; then printf '  %s\n' $$found; \
	else echo "  (none yet — make perf-cold)"; fi

# Publish one perf run onto gh-pages, beside the bench data. Same
# reasoning as bench-publish, and deliberately the same shape: the run
# only exists on this fleet, the docs workflow preserves data/ when it
# deploys, and the push is gated behind PUSH=1 because the numbers are
# public the moment they land.
#
# Under data/perf/<stamp>/ rather than data/perf.json: a run is a
# directory of SVGs, an index.html and a report, not one file, and
# keeping the stamp means publishing a second run never overwrites the
# first.
#
# perfsite.py then builds the selector index at data/perf/, so that URL
# is the same tool `make perf-serve` gives locally — the chart is
# self-contained, so a single run already rendered on the site; what it
# could not do was offer the OTHER runs. Each <stamp>/ keeps working as
# a permalink. No --live: a published run is frozen, and the page reads
# that from runs.json and stops polling rather than re-fetching static
# bytes every 20s on every open tab. bench-publish can use a single file because bench.sh already
# aggregates across runs; nothing aggregates these.
#
# The heavy inputs stay behind. samples.jsonl and the build-*.jsonl
# streams are tens of MB per run and are the raw material the report
# was already rendered from — committing them to a branch GitHub Pages
# serves would put the repo on a diet of binary-ish churn for data
# nobody fetches over HTTP.
PERF_PUBLISH_FILES ?= report.md run.json data.json index.html *.svg

perf-publish: ## Publish a perf run onto gh-pages (PERF_RUN=, PUSH=1 to push)
	@run="$(PERF_RUN)"; \
	[ -n "$$run" ] || run=$$(ls -1d /var/tmp/rocm-perf/*/ 2>/dev/null | tail -1); \
	[ -n "$$run" ] || { echo "no perf run found — run make perf-cold"; exit 1; }; \
	test -s "$$run/report.md" \
		|| { echo "$$run has no report.md — run make perf-report"; exit 1; }; \
	stamp=$$(basename "$$run"); \
	echo "publishing $$stamp"; \
	.builders/ghpages.sh $(GH_PAGES_DIR) $(GH_PAGES_BRANCH) > /dev/null; \
	mkdir -p $(GH_PAGES_DIR)/data/perf/$$stamp; \
	for f in $(PERF_PUBLISH_FILES); do \
		cp $$run/$$f $(GH_PAGES_DIR)/data/perf/$$stamp/ 2>/dev/null || true; \
	done; \
	python3 -I .builders/perfsite.py \
		$(GH_PAGES_DIR)/data/perf $(GH_PAGES_DIR)/data/perf; \
	git -C $(GH_PAGES_DIR) add data; \
	git -C $(GH_PAGES_DIR) diff --cached --quiet \
		&& echo "no change to publish" \
		|| git -C $(GH_PAGES_DIR) commit -s \
			-m "data: add perf run $$stamp"; \
	if [ "$(PUSH)" = 1 ]; then \
		git -C $(GH_PAGES_DIR) push origin HEAD:$(GH_PAGES_BRANCH); \
	else \
		echo; \
		echo "Committed locally. To publish:"; \
		echo "  git -C $(GH_PAGES_DIR) push origin HEAD:$(GH_PAGES_BRANCH)"; \
		echo "or re-run with PUSH=1."; \
	fi

##@ Wheels

push-torch-wheel: builder-ensure ## * Build and push the torch wheel image to Zot
	$(call bake,pytorch-wheel,--push,pub)

# The wheel lives in an image; this pulls it back onto local disk.
fetch-torch-wheel: ## Fetch the torch wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/pytorch-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

push-triton-wheel: builder-ensure ## * Build and push the Triton wheel image
	$(call bake,triton-wheel,--push,pub)

fetch-triton-wheel: ## Fetch the Triton wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/triton-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

push-aiter-wheel: builder-ensure ## * Build and push the AITER wheel image to Zot
	$(call bake,aiter-wheel,--push,pub)

# The wheel lives in an image; this is how you get it onto local disk.
fetch-aiter-wheel: ## Fetch the AITER wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/aiter-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

# CuPy is not an optional extra: LMCache's MP server imports it at
# module scope, and no published wheel matches ROCm 10.1 on cp314.
# See Dockerfile.cupy.
push-cupy-wheel: builder-ensure ## * Build and push the CuPy wheel image (ROCm source build)
	$(call bake,cupy-wheel,--push,pub)

build-cupy-wheel: builder-ensure ## Build the CuPy wheel image (no push)
	$(call bake,cupy-wheel)

fetch-cupy-wheel: ## Fetch the CuPy wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/cupy-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

# The build-only counterparts exist for bench.sh, which dispatches
# through `make build-<name>` and so could only measure a target that
# had one. Four of the seven wheels did, so a cold run covered torch,
# triton, aiter and cupy and stopped at nixl. They are useful on their
# own too: the push- form writes to Zot, which the credential helper on
# this host cannot do unattended.
build-nixl-wheel: builder-ensure ## Build the NIXL wheel image (no push)
	$(call bake,nixl-wheel)

push-nixl-wheel: builder-ensure ## * Build and push the NIXL wheel image (NIXL + ROCm UCX)
	$(call bake,nixl-wheel,--push,pub)

fetch-nixl-wheel: ## Fetch the NIXL wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/nixl-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

# ─── Serving stack ────────────────────────────────────────────────
# vLLM and LMCache, plus the NIXL wheel they both transfer KV cache
# through. These are part of build-all/push-all now: bake resolves the
# ordering itself from the `target:` contexts, and the balancer reaches
# them through STAGE_4/STAGE_5 with PUBLISHED_INPUTS=1.
#
# The build-* variants here remain single-builder. They take their
# inputs through `target:` contexts, which only resolve within one bake
# invocation — the balancer swaps those for published images instead.
##@ Serving (vLLM / LMCache)

# Read from rocm-bake.hcl, which owns them; make needs its own copy only to
# build the serving tags below and to print them. These used to be
# declared here with literal values and a comment asking whoever
# changed one to change it in rocm-bake.hcl too — see the Defaults block at
# the top of this file for why that is no longer how it works.
#
# Still exported, and still not passed as --set "*.args.X": a bake
# variable reads from an environment variable of the same name, whereas
# --set "*.args." adds a build ARG to *every* target, changing the
# cache key of targets that never use it. Exporting the value bake
# already has is a no-op; exporting a user's override is the point.
VLLM_REF    := $(or $(VLLM_REF),$(call bake_default,VLLM_REF))
LMCACHE_REF := $(or $(LMCACHE_REF),$(call bake_default,LMCACHE_REF))
NIXL_REF    := $(or $(NIXL_REF),$(call bake_default,NIXL_REF))
UCX_REF     := $(or $(UCX_REF),$(call bake_default,UCX_REF))
export VLLM_REF
export LMCACHE_REF
export NIXL_REF
export UCX_REF

build-vllm: builder-ensure ## Build the vLLM serving image (single builder)
	$(call bake,vllm)

push-vllm: builder-ensure ## * Build and push the vLLM serving image
	$(call bake,vllm,--push,pub)

build-vllm-wheel: builder-ensure ## Build the vLLM wheel image (no push)
	$(call bake,vllm-wheel)

push-vllm-wheel: builder-ensure ## * Build and push the vLLM wheel image
	$(call bake,vllm-wheel,--push,pub)

fetch-vllm-wheel: ## Fetch the vLLM wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/vllm-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

build-lmcache: builder-ensure ## Build the LMCache MP image (single builder)
	$(call bake,lmcache)

push-lmcache: builder-ensure ## * Build and push the LMCache multi-process image
	$(call bake,lmcache,--push,pub)

build-lmcache-wheel: builder-ensure ## Build the LMCache wheel image (no push)
	$(call bake,lmcache-wheel)

push-lmcache-wheel: builder-ensure ## * Build and push the LMCache wheel image
	$(call bake,lmcache-wheel,--push,pub)

fetch-lmcache-wheel: ## Fetch the LMCache wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/lmcache-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

build-serving: builder-ensure ## Build nixl + vLLM + LMCache (single builder)
	@if [ "$(BUILDER)" = "$(POOL_BUILDER)" ]; then \
		echo "build-serving cannot use $(POOL_BUILDER): these targets exchange"; \
		echo "results through 'target:' contexts, which only resolve within a"; \
		echo "single builder. Use 'make push-serving' or name a node."; \
		exit 1; \
	fi
	$(call bake,serving)

push-serving: builder-ensure ## * Build and push nixl + vLLM + LMCache
	$(call bake,serving,--push)

# ─── Run ──────────────────────────────────────────────────────────
# Executing what the Build section produced, as opposed to producing
# it. These need a node that can actually run the artifact, which is
# why none of them are in push-all: a build host is not necessarily a
# GPU host. The manifest's `gpu_node:` names it; a fleet that has no
# node with the `gpu` capability — a cloud build fleet, where no
# instance has an AMD accelerator — leaves it empty, and these targets
# say so rather than failing on an empty hostname.
##@ Run

test: builder-ensure ## Run the test stage against a GPU
	$(call bake,pytorch-test)

# The node with the GPU is rarely the node driving the build, so this
# runs over ssh by default. GPU_HOST is the machine with /dev/kfd;
# PYTORCH_ROCM_ARCH selects which image to test, so the same target
# covers every architecture we publish.
GPU_HOST ?= $(call fleet_var,FLEET_GPU_HOST)

# Printed by every target that needs a card, in place of the obscure
# failure an empty GPU_HOST produces: `ssh ""`, or a compose file
# pointed at DOCKER_HOST=ssh:// with nothing after it.
define require_gpu_host
	@[ -n "$(GPU_HOST)" ] || { \
		echo "fleet $(call fleet_var,FLEET_NAME) declares no gpu node, so there is"; \
		echo "nowhere to run this. Either set GPU_HOST=<host> for a one-off, or"; \
		echo "give a node the 'gpu' capability and name it in gpu_node: in"; \
		echo "$(call fleet_var,FLEET_MANIFEST_PATH)."; \
		exit 1; }
endef

gpu-test: ## Run the published image on a real GPU (GPU_HOST=, PYTORCH_ROCM_ARCH=)
	$(require_gpu_host)
	@.builders/gpu-test.sh --host "$(GPU_HOST)" --arch "$(PYTORCH_ROCM_ARCH)"

# ─── Serve ────────────────────────────────────────────────────────
# Bringing the serving stack up on the GPU host, as opposed to
# building it.
#
# DOCKER_HOST=ssh:// rather than copying the compose file over: the
# engine runs on GPU_HOST while the file stays here, version
# controlled, with one copy to drift from. Everything in it resolves
# remotely — /dev/kfd, the render gid, the HF cache, the volumes.
#
# VLLM_BIND defaults to 0.0.0.0 here but to 127.0.0.1 in the compose
# file. The file's default is right for someone running it locally;
# driving it from this machine needs the port off loopback. Narrow it
# again, or tunnel, if the host is not on a trusted network.
##@ Serve
SERVE_DIR     := serving
COMPOSE_FILE  := $(SERVE_DIR)/docker-compose.yml
GPU_RENDER_GID = $(shell ssh -o BatchMode=yes $(GPU_HOST) 'stat -c %g /dev/kfd' 2>/dev/null || echo 993)

# docker-compose.yml owns the serving runtime defaults, the way rocm-bake.hcl
# owns the build ones, and for the same reason: a second copy here would
# agree until someone changed one. Reads the `${NAME:-default}` form out
# of the file.
compose_default = $(shell sed -n 's/.*$${$(1):-\([^}]*\)}.*/\1/p' $(COMPOSE_FILE) | head -1)

# Passed only when actually set. An exported empty variable is still
# *set*, so `VAR=` would override the compose file's own default with
# "" — the same trap the bake refs hit. $(if ...) omits it instead,
# leaving the default to apply.
COMPOSE_VARS = $(foreach v,TRANSFER_MODE KV_TIER VLLM_DEV_MODE HSA_IPC_LEGACY \
                           L1_SIZE_GB CHUNK_SIZE MAX_MODEL_LEN GPU_UTIL \
                           KV_STORE HF_CACHE VLLM_EXTRA_ARGS \
                           TORCH_BLAS_PREFER_HIPBLASLT, \
                 $(if $($(v)),$(v)='$($(v))'))

COMPOSE        = DOCKER_HOST=ssh://$(GPU_HOST) RENDER_GID=$(GPU_RENDER_GID) \
                 VLLM_BIND=$(VLLM_BIND) MODEL=$(SERVE_MODEL) \
                 VLLM_TAG=$(VLLM_TAG) LMCACHE_TAG=$(LMCACHE_TAG) \
                 $(COMPOSE_VARS) \
                 docker compose -f $(COMPOSE_FILE)

# The machine that serves is not the machine that builds, and on this
# fleet it does not even have the same GPU: PYTORCH_ROCM_ARCH defaults
# to gfx950 while GPU_HOST is a gfx1201 RX 9070 XT. Taking
# the serving tag from the build default therefore asked Zot for an
# image nobody had built, and the only symptom was a pull failure
# naming a tag that looked plausible.
#
# Ask the host which GPU it has, the same way GPU_RENDER_GID asks it
# for the render group. Recursive `=`, not `:=`, so the ssh happens
# only for targets that actually serve — `make help` must not reach
# over the network. Falls back to the build arch when the host is
# unreachable or has no rocminfo, which is the right answer when
# someone is driving this against a single machine.
SERVE_ARCH = $(or $(shell ssh -o BatchMode=yes -o ConnectTimeout=5 $(GPU_HOST) \
                   "rocminfo 2>/dev/null | grep -m1 -oE 'gfx[0-9a-z]+'" 2>/dev/null),\
               $(PYTORCH_ROCM_ARCH))

# Mirrors ARCH_TAG in rocm-bake.hcl: a ";"-separated arch list is not a
# legal tag component, so the separator becomes "_". Derived here too
# because bake's copy is not visible to make.
SERVE_ARCH_TAG = $(subst ;,_,$(SERVE_ARCH))

SERVE_MODEL  ?= Qwen/Qwen2.5-3B-Instruct
VLLM_BIND    ?= 0.0.0.0
VLLM_TAG     ?= $(VLLM_REF)-$(ROCM_VERSION)-$(SERVE_ARCH_TAG)
LMCACHE_TAG  ?= $(LMCACHE_REF)-$(ROCM_VERSION)-$(SERVE_ARCH_TAG)
# The runtime knobs below have no default here on purpose — the compose
# file carries them and list-vars reads them back out with
# compose_default. Set any of them to override for one invocation:
#
#   KV_TIER         cpu = L1 only, file = L1 + L2 on disk
#   TRANSFER_MODE   auto | engine_driven | lmcache_driven. Both sides of
#                   the pair read it, so they cannot be configured
#                   apart. If the first request never returns, that is
#                   LMCache#4419 and engine_driven is the way out, at
#                   the cost of the caching win. A failure during
#                   *startup* is a different problem and this will not
#                   fix it — see HSA_ENABLE_IPC_MODE_LEGACY in the
#                   compose file, which decides whether the two
#                   containers can share KV memory at all.
#   HSA_IPC_LEGACY  that setting, surfaced as a variable
#   VLLM_DEV_MODE   1 exposes /reset_prefix_cache, which serve-test
#                   needs to tell LMCache's cache from vLLM's own
#   L1_SIZE_GB CHUNK_SIZE MAX_MODEL_LEN GPU_UTIL

# Extra flags for serve-logs*, e.g. SERVE_LOG_ARGS='-n 200 ov-vllm'
SERVE_LOG_ARGS ?=
# Extra flags for serve-test, e.g. SERVE_TEST_ARGS='--baseline'
SERVE_TEST_ARGS ?=

# Down before up, and both services rather than vllm alone.
#
# vllm joins lmcache's IPC namespace (`ipc: service:lmcache`), so the
# two are not independent: `up -d vllm` recreates only vllm and leaves
# lmcache running, which means a fresh engine attaches to a namespace a
# previous, half-initialised engine already lived in. Across a run of
# failed starts — a bad flag, an OOM, an unsupported arch — lmcache
# accumulates whatever those left behind, and the next attempt inherits
# it. That turns a clean failure into one that depends on what was
# tried before it.
#
# `down` is cheap next to loading a model, and it is the only way to be
# sure a result is attributable to the configuration under test rather
# than to the one before it.
serve-vllm: ## Serve vLLM alone on GPU_HOST, no KV offload (the baseline)
	$(require_gpu_host)
	@echo "serving $(SERVE_MODEL) on $(GPU_HOST) — vLLM only"
	@$(COMPOSE) down --remove-orphans 2>/dev/null || true
	@$(COMPOSE) up -d --wait lmcache 2>/dev/null || true
	@KV_OFFLOAD=0 $(COMPOSE) up -d vllm
	@$(MAKE_BIN) --no-print-directory serve-wait

serve-stack: ## Serve vLLM + LMCache MP on GPU_HOST (KV_TIER=cpu|file)
	$(require_gpu_host)
	@echo "serving $(SERVE_MODEL) on $(GPU_HOST) — vLLM + LMCache MP, tier=$(or $(KV_TIER),$(call compose_default,KV_TIER))"
	@KV_OFFLOAD=1 $(COMPOSE) up -d
	@$(MAKE_BIN) --no-print-directory serve-wait

# Readiness is /health, not `docker compose up --wait`: the container
# is up long before the model is loaded and the engine has finished
# capturing graphs, and asking the endpoint is the only thing that
# distinguishes "running" from "serving".
serve-wait: ## Block until the endpoint answers /health
	@echo "waiting for http://$(GPU_HOST):8000/health"
	@for i in $$(seq 1 240); do \
		if curl -fsS --max-time 3 "http://$(GPU_HOST):8000/health" >/dev/null 2>&1; then \
			echo "  ready after ~$$((i*5))s"; exit 0; \
		fi; \
		sleep 5; \
	done; \
	echo "  never became healthy — try 'make serve-logs'"; exit 1

# serve-wait says the endpoint is up; this says it is doing its job.
# Not the same question: LMCache can serve every request correctly and
# cache nothing at all, with no error anywhere — see the #4419 note in
# serving/docker-compose.yml. The test measures a repeated prefill and
# reads LMCache's own log rather than trusting /health.
serve-test: ## Exercise the running stack and prove the KV cache works
	@.builders/serve-test.sh $(SERVE_TEST_ARGS)

# The baseline has no connector, so the cache checks are skipped rather
# than failed.
serve-test-baseline: ## Same, for a stack started with serve-vllm
	@.builders/serve-test.sh --baseline $(SERVE_TEST_ARGS)

# Empties LMCache's L1 as well as vLLM's VRAM between the two requests,
# so a hit can only have come off disk. Needs KV_TIER=file — with the
# default cpu tier there is no L2 to serve from.
serve-test-l2: ## Prove the disk tier serves KV blocks (needs KV_TIER=file)
	@.builders/serve-test.sh --l2 $(SERVE_TEST_ARGS)

serve-down: ## Stop the serving stack and remove its containers
	$(require_gpu_host)
	@$(COMPOSE) down --remove-orphans

# Not `compose logs`: that only knows about the compose stack, and the
# benchmark harness starts its containers with plain docker run. The
# script finds whichever is up and merges both streams tagged by
# container, which matters because the useful lines alternate — vLLM
# says what it asked for, LMCache says whether it had it. Reading them
# apart means correlating by eye, and it hid a failure once already:
# LMCache died on a missing cupy and vLLM spent five minutes waiting
# before reporting a generic engine error.
serve-logs: ## Tail serving logs on GPU_HOST, both containers merged
	@.builders/serve-logs.sh $(SERVE_LOG_ARGS)

serve-logs-cache: ## Same, filtered to cache hit/miss/store lines
	@.builders/serve-logs.sh --cache $(SERVE_LOG_ARGS)

serve-logs-sorted: ## Snapshot of both logs merged in timestamp order
	@.builders/serve-logs.sh --sorted $(SERVE_LOG_ARGS)

serve-status: ## Show what is running on GPU_HOST
	$(require_gpu_host)
	@$(COMPOSE) ps

# ─── Benchmarks ───────────────────────────────────────────────────
# .builders/bench.sh measures the same target under four cache
# conditions — frozen, cold, warm, hot — and appends one JSON line per
# build. It was a standalone operator script for a long time; these
# targets exist because the numbers are now published, and a number
# nobody can reproduce from a documented command is not evidence.
#
# BENCH_DIR is the harness's own and is deliberately outside the repo:
# a cold pytorch log is large, and results accumulate across months.
##@ Benchmarks

BENCH_DIR ?= /var/tmp/rocm-bench
BENCH_SCENARIO ?= all
BENCH_TARGETS ?=
export BENCH_DIR

bench: ## Run the benchmark harness (BENCH_SCENARIO=frozen|cold|warm|hot|all|everything)
	@BUILDER=$(BUILDER) .builders/bench.sh $(BENCH_SCENARIO) $(BENCH_TARGETS)

bench-report: ## Render accumulated benchmark results as markdown
	@.builders/bench.sh report

# What the documentation site plots. Written under dist/ because dist/
# is gitignored and this is generated — the published copy lives on the
# gh-pages branch, never on main.
BENCH_JSON ?= dist/bench/bench.json

bench-data: ## Aggregate benchmark results into dist/bench/bench.json
	@mkdir -p $(dir $(BENCH_JSON))
	@.builders/bench.sh json $(BENCH_JSON)

# Publish the numbers onto gh-pages, beside the site the docs workflow
# builds there.
#
# From here rather than from CI, because this is the only place the data
# exists: the builds happen on this fleet and a GitHub-hosted runner has
# no way to reproduce or even read them. The docs workflow deliberately
# preserves data/ when it deploys, so the two writers do not clobber
# each other — see .github/workflows/docs.yml.
#
# A detached worktree under dist/, not a clone and not a branch switch:
# a switch would move the tree out from under whatever else is running
# here, and this repo is frequently mid-build.
#
# Commits are signed and signed-off, and the push needs PUSH=1. The data
# is public the moment it lands, so publishing is an explicit act rather
# than a side effect of generating a file.
GH_PAGES_BRANCH ?= gh-pages
GH_PAGES_DIR ?= dist/gh-pages

bench-publish: bench-data ## Publish the benchmark data onto gh-pages (PUSH=1 to push)
	@test -s $(BENCH_JSON) || { echo "no benchmark data — run make bench first"; exit 1; }
	@.builders/ghpages.sh $(GH_PAGES_DIR) $(GH_PAGES_BRANCH) > /dev/null
	@mkdir -p $(GH_PAGES_DIR)/data
	@cp $(BENCH_JSON) $(GH_PAGES_DIR)/data/bench.json
	@cp $(BENCH_DIR)/results.jsonl $(GH_PAGES_DIR)/data/bench.jsonl 2>/dev/null || true
	@git -C $(GH_PAGES_DIR) add data
	@git -C $(GH_PAGES_DIR) diff --cached --quiet \
		&& echo "no change to publish" \
		|| git -C $(GH_PAGES_DIR) commit -s \
			-m "data: refresh build benchmarks from $(BUILDER)"
	@if [ "$(PUSH)" = 1 ]; then \
		git -C $(GH_PAGES_DIR) push origin HEAD:$(GH_PAGES_BRANCH); \
	else \
		echo; \
		echo "Committed locally. To publish:"; \
		echo "  git -C $(GH_PAGES_DIR) push origin HEAD:$(GH_PAGES_BRANCH)"; \
		echo "or re-run with PUSH=1."; \
	fi

# ─── Documentation ────────────────────────────────────────────────
# The site is built by .github/workflows/docs.yml on every push to main.
# These targets exist so a page can be checked before it is pushed —
# --strict turns a broken internal link into a failure, which is the
# only thing standing between a nav entry and a 404.
#
# A venv under dist/ rather than a system install: this box has mkdocs
# from apt but not mkdocs-material, and mixing the two gets confusing
# fast. dist/ is gitignored.
##@ Documentation

DOCS_VENV ?= dist/docs-venv
DOCS_PY = $(DOCS_VENV)/bin/python

$(DOCS_VENV)/bin/mkdocs: docs/requirements.txt
	@python3 -m venv $(DOCS_VENV)
	@$(DOCS_PY) -m pip install -q --upgrade pip
	@$(DOCS_PY) -m pip install -q -r docs/requirements.txt
	@touch $@

docs-deps: $(DOCS_VENV)/bin/mkdocs ## Create the docs venv from docs/requirements.txt

docs-build: docs-deps ## Build the site into dist/site (fails on a broken link)
	@$(DOCS_VENV)/bin/mkdocs build --strict --site-dir dist/site
	@echo "Built dist/site — open dist/site/index.html"

docs-serve: docs-deps ## Serve the docs locally with live reload on :8000
	@$(DOCS_VENV)/bin/mkdocs serve

# ─── Utilities ────────────────────────────────────────────────────
##@ Utilities

validate: ## Validate bake file
	@docker buildx bake -f rocm-bake.hcl --print | jq empty && echo "Bake file is valid" || echo "Bake file has errors"

bake-plan: ## Print build plan
	@docker buildx bake -f rocm-bake.hcl --print | jq .

# Three jobs that look like one, kept apart on purpose.
#
# version-check asks the network: what has each upstream released, and
# what have we published to Zot. It needs the proxy for api.github.com
# and the tailnet for the registry, so it runs here and cannot run on a
# GitHub runner.
#
# version-scrub asks rocm-bake.hcl and nothing else, and rewrites the
# generated tables in README.md and docs/reference/bake-variables.md.
# That is what lets version-scrub-check gate every pull request in
# lint.yml — a check that needed `gh` and a tailnet name could not.
# Entangling the two would cost us the gate.
#
# No new variables here. Every version a check wants is already a
# `variable` block in rocm-bake.hcl, and check-defaults.py rejects a
# Makefile that declares one of those itself; REGISTRY and
# REGISTRY_NAME are already read through bake_default above.
version-check: ## Upstream releases vs published wheels vs our pins
	@python3 .builders/versioncheck.py \
		--registry "$(REGISTRY)" --namespace "$(REGISTRY_NAME)"

version-scrub: ## Regenerate the version tables from rocm-bake.hcl
	@python3 .builders/versioncheck.py --scrub

version-scrub-check: ## Fail if those generated tables are stale
	@python3 .builders/versioncheck.py --scrub-check

# Over ARCHES, not the single build arch: these tags are per-arch, and
# the gfx950 here used to be hardcoded — so on a gfx1201 build `clean`
# quietly removed nothing and reported success. runtime is in the loop
# because its tag carries the arch now too.
clean: ## Remove built images from local registry (every arch in ARCHES)
	@docker rmi $(REGISTRY)/$(REGISTRY_NAME)/base:$(ROCM_VERSION)-$(PYTHON_VERSION) 2>/dev/null || true
	@for a in $(ARCHES); do \
		docker rmi $(REGISTRY)/$(REGISTRY_NAME)/pytorch:$(PYTORCH_VERSION)-$(ROCM_VERSION)-$$a 2>/dev/null || true; \
		docker rmi $(REGISTRY)/$(REGISTRY_NAME)/runtime:$(PYTORCH_VERSION)-$(ROCM_VERSION)-$$a 2>/dev/null || true; \
	done
	@echo "Local images cleaned"

# This used to claim it removed cache images from Zot and did nothing
# of the sort: `docker rmi` against a registry ref carrying no tag
# matches nothing locally and never speaks to the registry at all, so
# it printed "Cache images removed" every time having removed none.
#
# Nothing replaces the registry half, because nothing needs to. The
# cache repos are not unbounded: each holds five fixed tags — latest,
# latest-<arch> and latest-<arch>-ref — overwritten on every build, and
# Zot is configured with dedupe, gc and deleteUntagged, so the
# manifests an overwrite orphans are collected on its own schedule.
# `make zot-disk` is the number to look at; `make image-sizes` is where
# a target's cache got large.
clean-cache: ## Drop locally-pulled cache images (Zot GCs its own)
	@for a in $(ARCHES); do \
		for r in $(CACHE_REPOS); do \
			docker rmi $(REGISTRY)/$(REGISTRY_NAME)/$$r:latest-$$a \
				2>/dev/null || true; \
		done; \
	done
	@for r in $(CACHE_REPOS); do \
		docker rmi $(REGISTRY)/$(REGISTRY_NAME)/$$r:latest 2>/dev/null || true; \
	done
	@echo "Local cache images dropped. Zot prunes its own store —"
	@echo "see 'make zot-disk' for what it actually holds."

setup: zot-check builder-setup ## Full setup: check Zot, then builders
	@echo "Setup complete. Run 'make build-all' to start building."

##@ Help

# The title line names one arch because one build is one arch — that is
# what PYTORCH_ROCM_ARCH means and it has not changed. ARCHES is a
# separate thing and gets its own line: it is what arches-* fans out
# over, it defaults to three, and each one is a full pass over every
# target. A multiplier on build time that large should not be something
# you only find out from a comment in here.
help: ## Show this help
	@printf '\n$(C_BOLD)ROCm PyTorch Build$(C_OFF) — PyTorch %s on ROCm %s for %s\n' \
		"$(PYTORCH_VERSION)" "$(ROCM_VERSION)" "$(PYTORCH_ROCM_ARCH)"
	@printf 'Registry %s · builder %s\n' "$(REGISTRY)" "$(BUILDER)"
	@printf 'One arch per build · $(C_CYAN)make arches-*$(C_OFF) covers ARCHES = %s\n' "$(ARCHES)"
	@printf 'Usage: make <target> [VAR=value]\n'
	@awk 'BEGIN {FS = ":.*?## "; cmd = "sort"} \
		/^##@/ { if (insec) close(cmd); printf "\n$(C_BOLD)%s$(C_OFF)\n", substr($$0, 5); insec = 1; next } \
		/^[a-zA-Z0-9_-]+:.*?## / { \
			name = $$1; text = $$2; \
			if (substr(text, 1, 2) == "* ") { name = name " *"; text = substr(text, 3) } \
			line = sprintf("  $(C_CYAN)%-20s$(C_OFF) %s", name, text); \
			if (insec) print line | cmd; else print line } \
		END { if (insec) close(cmd) }' \
		$(MAKEFILE_LIST)
	@printf '\n'

list-vars: ## Show the variables these targets read, and their values
	@printf '\n$(C_BOLD)Build$(C_OFF)\n'
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' PYTORCH_VERSION "$(PYTORCH_VERSION)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' ROCM_VERSION "$(ROCM_VERSION)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' PYTHON_VERSION "$(PYTHON_VERSION)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' TRITON_REF "$(call bake_default,TRITON_REF)  (bake)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' AITER_REF "$(call bake_default,AITER_REF)  (bake)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' NIXL_REF "$(NIXL_REF)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' UCX_REF "$(UCX_REF)  (built inside the nixl wheel)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' VLLM_REF "$(VLLM_REF)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' LMCACHE_REF "$(LMCACHE_REF)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' CUPY_REF "$(call bake_default,CUPY_REF)  (bake)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' PYTORCH_ROCM_ARCH "$(PYTORCH_ROCM_ARCH)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' ARCHES "$(ARCHES)  (what arches-* fans out over)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' MAX_JOBS "$(if $(MAX_JOBS),$(MAX_JOBS),(derived per node from free memory))"
	@printf '\n$(C_BOLD)Fleet$(C_OFF)  (make list-nodes for the whole manifest)\n'
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' FLEET "$(FLEET)  ($(call fleet_var,FLEET_MANIFEST_PATH))"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' FLEET_NODES "$(FLEET_NODES)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' POOL_BUILDER "$(POOL_BUILDER)  (sentinel: routes through balance.sh)"
	@printf '\n$(C_BOLD)Location$(C_OFF)\n'
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' BUILDER "$(BUILDER)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' REGISTRY "$(REGISTRY)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' REGISTRY_NAME "$(REGISTRY_NAME)"
	@printf '\n$(C_BOLD)Compiler Cache$(C_OFF)\n'
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' WEBDAV_HOST "$(WEBDAV_HOST)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' SCCACHE_WEBDAV_ENDPOINT "$(SCCACHE_WEBDAV_ENDPOINT)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' WEBDAV_DIR "$(WEBDAV_DIR)"
	@printf '\n$(C_BOLD)Reproducibility$(C_OFF)\n'
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' SDE_EPOCH \
		"$(call bake_default,SDE_EPOCH)  ($(shell date -u -d @$(call bake_default,SDE_EPOCH) '+%Y-%m-%d %H:%M' 2>/dev/null))  (bake)"
	@printf '  %s\n' 'pinned into every image config; SDE_<IMAGE> overrides one'
	@for v in $(foreach i,BASE PYTORCH TRITON AITER RUNTIME NIXL VLLM LMCACHE CUPY,$(if $(SDE_$(i)),SDE_$(i)=$(SDE_$(i)))); do \
		printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' "$${v%%=*}" "$${v#*=}  (overridden)"; \
	done
	@printf '\n$(C_BOLD)Serving$(C_OFF)  (make serve-vllm / serve-stack / serve-test)\n'
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' GPU_HOST "$(or $(GPU_HOST),(none — this fleet declares no gpu node))"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' SERVE_MODEL "$(SERVE_MODEL)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' SERVE_ARCH "$(SERVE_ARCH)  (probed from GPU_HOST, not the build arch)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' VLLM_TAG "$(VLLM_TAG)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' LMCACHE_TAG "$(LMCACHE_TAG)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' VLLM_BIND "$(VLLM_BIND)  (0.0.0.0 to drive it from another host)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' KV_TIER \
		"$(or $(KV_TIER),$(call compose_default,KV_TIER))  (cpu = L1 only, file = L1 + L2 on disk)  (compose)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' TRANSFER_MODE \
		"$(or $(TRANSFER_MODE),$(call compose_default,TRANSFER_MODE))  (auto|engine_driven|lmcache_driven)  (compose)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' HSA_IPC_LEGACY \
		"$(or $(HSA_IPC_LEGACY),$(call compose_default,HSA_IPC_LEGACY))  (1 required for cross-container HIP IPC)  (compose)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' VLLM_DEV_MODE \
		"$(or $(VLLM_DEV_MODE),$(call compose_default,VLLM_DEV_MODE))  (1 exposes /reset_prefix_cache for serve-test)  (compose)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' L1_SIZE_GB \
		"$(or $(L1_SIZE_GB),$(call compose_default,L1_SIZE_GB))  (LMCache host-RAM tier)  (compose)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' CHUNK_SIZE \
		"$(or $(CHUNK_SIZE),$(call compose_default,CHUNK_SIZE))  (tokens per cached chunk)  (compose)"
	@printf '\n$(C_BOLD)Toggles$(C_OFF)\n'
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' TELEMETRY "$(TELEMETRY)  (0 skips metrics collection)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' FORCE_RECACHE "$(if $(FORCE_RECACHE),$(FORCE_RECACHE),false)  (true = recompile everything, ignoring sccache)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' BAKE_EXTRA "$(if $(BAKE_EXTRA),$(BAKE_EXTRA),(none))"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' PREBUILD_KERNELS "$(if $(PREBUILD_KERNELS),$(PREBUILD_KERNELS),0 (default on every arch))  (bake)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' PUBLISHED_INPUTS "$(if $(PUBLISHED_INPUTS),$(PUBLISHED_INPUTS),(unset: targets feed each other directly))  (bake)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' RUN_ID "$(if $(RUN_ID),$(RUN_ID),$(call bake_default,RUN_ID))  (bake; stamped into build records)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' CACHE_TAG_SUFFIX "$(if $(CACHE_TAG_SUFFIX),$(CACHE_TAG_SUFFIX),(empty: write the rolling tag; -ref refreshes the baseline))  (bake)"
	@printf '  $(C_CYAN)%-24s$(C_OFF) %s\n' SCCACHE_LOG "$(if $(SCCACHE_LOG),$(SCCACHE_LOG),warn)  (debug reveals the Cache errors count; env only, see below)"
	@printf '\nOverride any of these on the command line: make <target> VAR=value\n'
	@printf 'SCCACHE_LOG is read by bake from the environment, so it needs\n'
	@printf 'SCCACHE_LOG=debug make <target> rather than make <target> SCCACHE_LOG=debug.\n\n'
