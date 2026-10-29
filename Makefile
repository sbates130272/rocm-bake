# Makefile - convenience wrapper for rocm-pytorch builds

# ─── Defaults ────────────────────────────────────────────────────
# bake.hcl is the single source for every value a build reads. This
# file does not get to have an opinion about them: it used to carry its
# own copy of ten defaults, which agreed with bake.hcl only because
# nobody had changed one yet. A `make` target and a bare
# `docker buildx bake` would then have built different images from the
# same tree, and nothing would have said so.
#
# One awk pass over bake.hcl at parse time, rather than a $(shell) per
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
		printf "%s=%s\n", name, v; name = "" }' bake.hcl)

# Empty when the variable has no default in bake.hcl, which for our
# purposes is indistinguishable from an empty default — both mean
# "bake decides".
bake_default = $(patsubst $(1)=%,%,$(filter $(1)=%,$(BAKE_DEFAULTS)))

# $(or ...) rather than ?=: the value has to be expanded once here, not
# re-derived at every reference. An environment variable of the same
# name still wins (make imports it, so $(REGISTRY) is already set), and
# a command-line VAR=value overrides the assignment outright — so both
# override paths keep working.
REGISTRY          := $(or $(REGISTRY),$(call bake_default,REGISTRY))
REGISTRY_NAME     := $(or $(REGISTRY_NAME),$(call bake_default,REGISTRY_NAME))
PYTORCH_VERSION   := $(or $(PYTORCH_VERSION),$(call bake_default,PYTORCH_VERSION))
ROCM_VERSION      := $(or $(ROCM_VERSION),$(call bake_default,ROCM_VERSION))
PYTHON_VERSION    := $(or $(PYTHON_VERSION),$(call bake_default,PYTHON_VERSION))
PYTORCH_ROCM_ARCH := $(or $(PYTORCH_ROCM_ARCH),$(call bake_default,PYTORCH_ROCM_ARCH))

# BUILDER and REPO are make's own: bake has no concept of which node a
# build lands on, nor of which Zot repository `make zot-tags` lists.
BUILDER ?= snoc-strix
REPO ?= $(REGISTRY_NAME)/base

# Remote build nodes. SSH endpoints, so these must be reachable as
# `ssh <host>` from here (tailnet names work on the host; only builder
# *containers* lack MagicDNS). Note the builder is named snoc-think but
# the machine is snoc-thinkstation — there is no snoc-think on the
# tailnet, so this variable keeps the real hostname.
# (THINK_HOST and GAMING_HOST are defined below.)

# The tailnet must never go through the corporate proxy. HTTP_PROXY and
# HTTPS_PROXY are set in this environment but no_proxy is not, so every
# proxy-aware tool (curl in some modes, python urllib, Go binaries like
# zli and docker) tries to reach snoc-* through ZScaler and fails. Set
# it here so make targets are correct regardless of the user's shell;
# add the same to your profile for interactive use.
NO_PROXY_LIST := localhost,127.0.0.1,::1,.ts.net,.local,10.0.0.0/8,100.64.0.0/10
export no_proxy := $(NO_PROXY_LIST)
export NO_PROXY := $(NO_PROXY_LIST)

# help lives at the bottom of this file, in its own section, so it is
# no longer the first target. Without this, `make` with no arguments
# would run whatever target happens to come first.
.DEFAULT_GOAL := help

# Aliased so the recipe text does not contain the literal $(MAKE):
# make executes any line referencing $(MAKE) even under -n, which made
# `make -n watch` launch a full-screen watch instead of printing it.
# Where running builds record themselves, for `make build-stop`.
BUILD_PIDFILE ?= /tmp/.rocm-build.pids
export BUILD_PIDFILE

MAKE_BIN := $(MAKE)

# Shared compiler-cache store on Strix: nginx WebDAV over a directory
# tree, so it survives a reboot. Replaced memcached, which did not.
# Host and port from bake.hcl, for the same reason as everything else
# in the block above — the builders and the deploy targets have to
# agree on where the store is.
WEBDAV_HOST := $(or $(WEBDAV_HOST),$(call bake_default,SCCACHE_WEBDAV_HOST))
WEBDAV_PORT := $(or $(WEBDAV_PORT),$(call bake_default,SCCACHE_WEBDAV_PORT))
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
WEBDAV_DIR  ?= /var/cache/sccache-webdav

# A sentinel, not a builder. BUILDER=snoc-pool means "let the balancer
# choose"; requests for it are routed through .builders/balance.sh,
# which runs each target against a concrete node. Nothing is ever built
# against a buildx pool now, so the pool builder need not exist — and if
# it does, its records never update, which is why watch skips it.
# Reclaim its containers with: docker buildx rm snoc-pool
POOL_BUILDER ?= snoc-pool

THINK_HOST ?= snoc-thinkstation
GAMING_HOST ?= snoc-gaming

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

# SOURCE_DATE_EPOCH used to be computed and exported from here, one
# value per image. It lives in bake.hcl now — see the SDE_EPOCH block
# there for why it is a constant rather than a date from git history.
# Overriding one image's epoch is still possible, and still per image:
#
#   make build-pytorch BAKE_EXTRA='--set pytorch.args.SOURCE_DATE_EPOCH=...'
#
# or SDE_PYTORCH=... in the environment, which bake reads directly.

TELEMETRY ?= 1
ifeq ($(TELEMETRY),0)
BAKE = docker buildx bake -f bake.hcl
else
BAKE = ./telemetry/build.sh
endif

.PHONY: help zot-check zot-catalog zot-tags zot-wheels zot-wheelhouse zot-logs \
        builder-setup builder-snoc-strix builder-snoc-think builder-snoc-gaming \
        builder-snoc-pool builder-status builder-logs builder-restart \
        build-status build-logs build-inspect builder-ensure watch \
        build-stop gpu-test \
        serve-vllm serve-stack serve-wait serve-down serve-status \
        serve-test serve-test-baseline serve-test-l2 \
        serve-logs serve-logs-cache serve-logs-sorted \
        cold-build push-aiter-wheel fetch-aiter-wheel push-wheels _push-wheels \
        build-torch-wheel build-triton-wheel build-aiter-wheel \
        _build-all _push-all \
        push-torch-wheel fetch-torch-wheel \
        push-triton-wheel fetch-triton-wheel \
        push-nixl-wheel fetch-nixl-wheel \
        push-cupy-wheel build-cupy-wheel fetch-cupy-wheel \
        build-vllm push-vllm push-vllm-wheel fetch-vllm-wheel \
        build-lmcache push-lmcache push-lmcache-wheel fetch-lmcache-wheel \
        build-serving push-serving \
        cache-stats cache-summary cache-check cache-logs builder-load \
        layer-summary \
        list-vars \
        build-base build-pytorch build-runtime build-all \
        push-base push-pytorch push-runtime push-all \
        clean clean-cache test \
        validate bake-plan setup

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
# panel. Keep in step with the `wheels` group in bake.hcl.
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

# ─── Buildx Builder Setup ────────────────────────────────────────
##@ Compiler Cache

# The sccache store every node shares: nginx WebDAV over a directory
# tree on Strix. It replaced memcached, which held everything in RAM and
# lost the fleet's cache on every power cycle.
#
# WebDAV has no stats verb, so unlike memcached the store cannot report
# hit rates — only size and object count. Hit rates come from sccache
# itself, which prints --show-stats at the end of each build.
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

cache-stats: ## Show the shared compiler-cache (WebDAV) state
	@curl -sf -o /dev/null -w "  endpoint            HTTP %{http_code}  $(WEBDAV_URL)\n" "$(WEBDAV_URL)/" \
		|| { echo "  endpoint            UNREACHABLE  $(WEBDAV_URL)"; exit 1; }
	@sudo du -sh $(WEBDAV_DIR) 2>/dev/null | awk '{printf "  size                %s\n", $$1}'
	@sudo find $(WEBDAV_DIR) -type f 2>/dev/null | wc -l | awk '{printf "  objects             %s\n", $$1}'
	@df -h $(WEBDAV_DIR) 2>/dev/null | tail -1 \
		| awk '{printf "  filesystem          %s of %s used, %s free\n", $$3, $$2, $$4}'
	@echo "  hit_rate            see 'sccache --show-stats' in the build log"

CACHE_STATE := /tmp/.rocm-cache-prev

# Totals alone say nothing about the build in front of you, so this
# prints current state plus the delta since the previous call — the
# number that moves while a build runs.
cache-summary: ## One-line cache state plus deltas since the last call
	@objs=$$(sudo find $(WEBDAV_DIR) -type f 2>/dev/null | wc -l); \
	size=$$(sudo du -sb $(WEBDAV_DIR) 2>/dev/null | cut -f1); \
	if [ -z "$$size" ]; then \
		printf '\033[36m══ sccache store\033[0m unreachable at %s\n' "$(WEBDAV_DIR)"; \
	else \
		echo "$$objs $$size" > $(CACHE_STATE).now; \
		[ -s $(CACHE_STATE) ] || cp $(CACHE_STATE).now $(CACHE_STATE); \
		paste $(CACHE_STATE).now $(CACHE_STATE) \
		| awk '{ \
			o=$$1; b=$$2; po=$$3; pb=$$4; \
			printf "\033[36m══ sccache store (WebDAV, durable)\033[0m\n"; \
			printf "  objects=%d  size=%.2fGB\n", o, b/1073741824; \
			if (o - po <= 0) \
				printf "  interval  idle (no new objects since last refresh)\n"; \
			else \
				printf "  interval  +%d objects  +%.0fMB\n", o-po, (b-pb)/1048576; \
			}'; \
		mv $(CACHE_STATE).now $(CACHE_STATE); \
	fi

cache-check: ## Verify every build node can reach the compiler cache
	@for h in localhost $(THINK_HOST) $(GAMING_HOST); do \
		printf '  %-20s ' "$$h"; \
		if [ "$$h" = localhost ]; then \
			curl -sf -o /dev/null -w 'HTTP %{http_code}' "$(WEBDAV_URL)/" || printf UNREACHABLE; \
		else \
			ssh -n -o BatchMode=yes "$$h" "curl -sf -o /dev/null -w 'HTTP %{http_code}' '$(WEBDAV_URL)/'" 2>/dev/null \
				|| printf UNREACHABLE; \
		fi; \
		echo; \
	done

cache-logs: ## Follow the WebDAV store's access log
	@sudo tail -f /var/log/nginx/access.log

##@ Builders

builder-setup: builder-snoc-strix builder-snoc-think builder-snoc-gaming ## Setup all builders

builder-snoc-strix: ## Setup the snoc-strix builder (local docker-container)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'snoc-strix'; then \
		echo "snoc-strix builder already exists"; \
	else \
		echo "Creating snoc-strix builder..."; \
		docker buildx create \
			--name snoc-strix \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64; \
	fi
	@docker buildx use snoc-strix
	@echo "snoc-strix builder active"

# snoc-thinkstation and snoc-gaming join over SSH to their Docker
# daemons, not the remote/TLS driver: buildx creates and owns a buildkit
# container on each, so neither node needs buildkitd, TLS certs, or the
# buildx plugin installed. Both are gfx1201 (RDNA4), so they can
# cross-compile for gfx950 but cannot run the GPU test stage.
builder-snoc-think: ## Setup the snoc-think builder (over SSH to snoc-thinkstation)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'snoc-think'; then \
		echo "snoc-think builder already exists"; \
	else \
		echo "Creating snoc-think builder..."; \
		docker buildx create \
			--name snoc-think \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64 \
			ssh://$(THINK_HOST); \
	fi

builder-snoc-gaming: ## Setup the snoc-gaming builder (over SSH)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'snoc-gaming'; then \
		echo "snoc-gaming builder already exists"; \
	else \
		echo "Creating snoc-gaming builder..."; \
		docker buildx create \
			--name snoc-gaming \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64 \
			ssh://$(GAMING_HOST); \
	fi

# One builder with all three nodes. buildx spreads independent targets
# across nodes, so `make build-all BUILDER=snoc-pool` uses the whole fleet.
# A single target still builds on one node — this is fan-out, not a
# distributed compile of one image.
builder-snoc-pool: ## Setup a 3-node pool (snoc-strix + snoc-think + snoc-gaming)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'snoc-pool'; then \
		echo "snoc-pool builder already exists"; \
	else \
		echo "Creating snoc-pool builder..."; \
		docker buildx create --name snoc-pool --node snoc-strix \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--platform linux/amd64; \
		docker buildx create --name snoc-pool --append --node snoc-think \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--platform linux/amd64 \
			ssh://$(THINK_HOST); \
		docker buildx create --name snoc-pool --append --node snoc-gaming \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--platform linux/amd64 \
			ssh://$(GAMING_HOST); \
	fi
	@docker buildx inspect snoc-pool --bootstrap

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
				timeout 3 docker buildx history logs "$$id" --builder $$b \
					> $(WATCH_TMP) 2>&1 || true; \
				grep -v "^$$" $(WATCH_TMP) \
					| grep -v "rpc error: code = Canceled" \
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
define bake
@echo $$$$ >> $(BUILD_PIDFILE); \
b="$(BUILDER)"; \
if [ "$$b" = "$(POOL_BUILDER)" ]; then \
	b=$$(.builders/balance.sh --best); \
	echo "balance: $(POOL_BUILDER) -> $$b"; \
fi; \
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

cold-build: builder-ensure ## Fully cold build (no layer or compiler cache). COLD_TARGET=
	@echo "Cold build of $(COLD_TARGET) on $(BUILDER): no layer cache, no sccache hits."
	$(call bake,$(COLD_TARGET),--no-cache --set "*.args.FORCE_RECACHE=true")

# ─── Push Targets ────────────────────────────────────────────────
# --push replaces the image output, so these build and push in one pass
# rather than building twice.
##@ Push

push-base: builder-ensure ## * Build and push base image
	$(call bake,pytorch-base,--push)

push-pytorch: builder-ensure ## * Build and push PyTorch
	$(call bake,pytorch,--push)

push-runtime: builder-ensure ## Build and push runtime image
	$(call bake,pytorch-run,--push)

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
# The staged path reuses balance.sh: stages 2 and 3 already produce the
# torch, triton, aiter and nixl wheels, so only the serving wheels need
# adding on the end.
push-wheels: ## Push the wheel artifacts (torch, triton, aiter, nixl, vllm, lmcache)
	@if [ "$(BUILDER)" = "$(POOL_BUILDER)" ]; then \
		BALANCE_STREAM=$(BALANCE_STREAM) \
		STAGE_4="lmcache-wheel" STAGE_5="vllm-wheel" .builders/balance.sh; \
	else \
		$(MAKE_BIN) --no-print-directory _push-wheels BUILDER=$(BUILDER); \
	fi

_push-wheels: builder-ensure
	$(call bake,wheels,--push)

##@ Wheels

push-torch-wheel: builder-ensure ## * Build and push the torch wheel image to Zot
	$(call bake,pytorch-wheel,--push)

# The wheel lives in an image; this pulls it back onto local disk.
fetch-torch-wheel: ## Fetch the torch wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/pytorch-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

push-triton-wheel: builder-ensure ## * Build and push the Triton wheel image
	$(call bake,triton-wheel,--push)

fetch-triton-wheel: ## Fetch the Triton wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/triton-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

push-aiter-wheel: builder-ensure ## * Build and push the AITER wheel image to Zot
	$(call bake,aiter-wheel,--push)

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
	$(call bake,cupy-wheel,--push)

build-cupy-wheel: builder-ensure ## Build the CuPy wheel image (no push)
	$(call bake,cupy-wheel)

fetch-cupy-wheel: ## Fetch the CuPy wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/cupy-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

push-nixl-wheel: builder-ensure ## * Build and push the NIXL wheel image (NIXL + ROCm UCX)
	$(call bake,nixl-wheel,--push)

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

# Read from bake.hcl, which owns them; make needs its own copy only to
# build the serving tags below and to print them. These used to be
# declared here with literal values and a comment asking whoever
# changed one to change it in bake.hcl too — see the Defaults block at
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
	$(call bake,vllm,--push)

push-vllm-wheel: builder-ensure ## * Build and push the vLLM wheel image
	$(call bake,vllm-wheel,--push)

fetch-vllm-wheel: ## Fetch the vLLM wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/vllm-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

build-lmcache: builder-ensure ## Build the LMCache MP image (single builder)
	$(call bake,lmcache)

push-lmcache: builder-ensure ## * Build and push the LMCache multi-process image
	$(call bake,lmcache,--push)

push-lmcache-wheel: builder-ensure ## * Build and push the LMCache wheel image
	$(call bake,lmcache-wheel,--push)

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
# GPU host. snoc-thinkstation has the gfx1201 card and is the default.
##@ Run

test: builder-ensure ## Run the test stage against a GPU
	$(call bake,pytorch-test)

# The node with the GPU is rarely the node driving the build, so this
# runs over ssh by default. GPU_HOST is the machine with /dev/kfd;
# PYTORCH_ROCM_ARCH selects which image to test, so the same target
# covers every architecture we publish.
GPU_HOST ?= snoc-thinkstation
gpu-test: ## Run the published image on a real GPU (GPU_HOST=, PYTORCH_ROCM_ARCH=)
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

# docker-compose.yml owns the serving runtime defaults, the way bake.hcl
# owns the build ones, and for the same reason: a second copy here would
# agree until someone changed one. Reads the `${NAME:-default}` form out
# of the file.
compose_default = $(shell sed -n 's/.*$${$(1):-\([^}]*\)}.*/\1/p' $(COMPOSE_FILE) | head -1)

# Passed only when actually set. An exported empty variable is still
# *set*, so `VAR=` would override the compose file's own default with
# "" — the same trap the bake refs hit. $(if ...) omits it instead,
# leaving the default to apply.
COMPOSE_VARS = $(foreach v,TRANSFER_MODE KV_TIER VLLM_DEV_MODE HSA_IPC_LEGACY \
                           L1_SIZE_GB CHUNK_SIZE MAX_MODEL_LEN GPU_UTIL, \
                 $(if $($(v)),$(v)=$($(v))))

COMPOSE        = DOCKER_HOST=ssh://$(GPU_HOST) RENDER_GID=$(GPU_RENDER_GID) \
                 VLLM_BIND=$(VLLM_BIND) MODEL=$(SERVE_MODEL) \
                 VLLM_TAG=$(VLLM_TAG) LMCACHE_TAG=$(LMCACHE_TAG) \
                 $(COMPOSE_VARS) \
                 docker compose -f $(COMPOSE_FILE)

# The machine that serves is not the machine that builds, and on this
# fleet it does not even have the same GPU: PYTORCH_ROCM_ARCH defaults
# to gfx950 (Strix Halo) while GPU_HOST is a gfx1201 RX 9070 XT. Taking
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

# Mirrors ARCH_TAG in bake.hcl: a ";"-separated arch list is not a
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

serve-vllm: ## Serve vLLM alone on GPU_HOST, no KV offload (the baseline)
	@echo "serving $(SERVE_MODEL) on $(GPU_HOST) — vLLM only"
	@$(COMPOSE) up -d --wait lmcache 2>/dev/null || true
	@KV_OFFLOAD=0 $(COMPOSE) up -d vllm
	@$(MAKE_BIN) --no-print-directory serve-wait

serve-stack: ## Serve vLLM + LMCache MP on GPU_HOST (KV_TIER=cpu|file)
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
	@$(COMPOSE) ps

# ─── Utilities ────────────────────────────────────────────────────
##@ Utilities

validate: ## Validate bake file
	@docker buildx bake -f bake.hcl --print | jq empty && echo "Bake file is valid" || echo "Bake file has errors"

bake-plan: ## Print build plan
	@docker buildx bake -f bake.hcl --print | jq .

clean: ## Remove built images from local registry
	@docker rmi $(REGISTRY)/$(REGISTRY_NAME)/base:$(ROCM_VERSION)-$(PYTHON_VERSION) 2>/dev/null || true
	@docker rmi $(REGISTRY)/$(REGISTRY_NAME)/pytorch:$(PYTORCH_VERSION)-$(ROCM_VERSION)-gfx950 2>/dev/null || true
	@docker rmi $(REGISTRY)/$(REGISTRY_NAME)/runtime:$(PYTORCH_VERSION)-$(ROCM_VERSION) 2>/dev/null || true
	@echo "Local images cleaned"

clean-cache: ## Remove cache images from Zot
	@echo "Removing cache images..."
	@for tag in base-cache pytorch-cache runtime-cache cache; do \
		docker rmi $(REGISTRY)/$(REGISTRY_NAME)/$$tag 2>/dev/null || true; \
	done
	@echo "Cache images removed (local only; Zot registry must be pruned separately)"

setup: zot-check builder-setup ## Full setup: check Zot, then builders
	@echo "Setup complete. Run 'make build-all' to start building."

##@ Help

help: ## Show this help
	@printf '\n\033[1mROCm PyTorch Build\033[0m — PyTorch %s on ROCm %s for %s\n' \
		"$(PYTORCH_VERSION)" "$(ROCM_VERSION)" "$(PYTORCH_ROCM_ARCH)"
	@printf 'Registry %s · builder %s\n' "$(REGISTRY)" "$(BUILDER)"
	@printf 'Usage: make <target> [VAR=value]\n'
	@awk 'BEGIN {FS = ":.*?## "; cmd = "sort"} \
		/^##@/ { if (insec) close(cmd); printf "\n\033[1m%s\033[0m\n", substr($$0, 5); insec = 1; next } \
		/^[a-zA-Z0-9_-]+:.*?## / { \
			name = $$1; text = $$2; \
			if (substr(text, 1, 2) == "* ") { name = name " *"; text = substr(text, 3) } \
			line = sprintf("  \033[36m%-20s\033[0m %s", name, text); \
			if (insec) print line | cmd; else print line } \
		END { if (insec) close(cmd) }' \
		$(MAKEFILE_LIST)
	@printf '\n'

list-vars: ## Show the variables these targets read, and their values
	@printf '\n\033[1mBuild\033[0m\n'
	@printf '  \033[36m%-24s\033[0m %s\n' PYTORCH_VERSION "$(PYTORCH_VERSION)"
	@printf '  \033[36m%-24s\033[0m %s\n' ROCM_VERSION "$(ROCM_VERSION)"
	@printf '  \033[36m%-24s\033[0m %s\n' PYTHON_VERSION "$(PYTHON_VERSION)"
	@printf '  \033[36m%-24s\033[0m %s\n' TRITON_REF "$(call bake_default,TRITON_REF)  (bake)"
	@printf '  \033[36m%-24s\033[0m %s\n' AITER_REF "$(call bake_default,AITER_REF)  (bake)"
	@printf '  \033[36m%-24s\033[0m %s\n' NIXL_REF "$(NIXL_REF)"
	@printf '  \033[36m%-24s\033[0m %s\n' UCX_REF "$(UCX_REF)  (built inside the nixl wheel)"
	@printf '  \033[36m%-24s\033[0m %s\n' VLLM_REF "$(VLLM_REF)"
	@printf '  \033[36m%-24s\033[0m %s\n' LMCACHE_REF "$(LMCACHE_REF)"
	@printf '  \033[36m%-24s\033[0m %s\n' CUPY_REF "$(call bake_default,CUPY_REF)  (bake)"
	@printf '  \033[36m%-24s\033[0m %s\n' PYTORCH_ROCM_ARCH "$(PYTORCH_ROCM_ARCH)"
	@printf '  \033[36m%-24s\033[0m %s\n' MAX_JOBS "$(if $(MAX_JOBS),$(MAX_JOBS),(derived per node from free memory))"
	@printf '\n\033[1mLocation\033[0m\n'
	@printf '  \033[36m%-24s\033[0m %s\n' BUILDER "$(BUILDER)"
	@printf '  \033[36m%-24s\033[0m %s\n' REGISTRY "$(REGISTRY)"
	@printf '  \033[36m%-24s\033[0m %s\n' REGISTRY_NAME "$(REGISTRY_NAME)"
	@printf '\n\033[1mCompiler Cache\033[0m\n'
	@printf '  \033[36m%-24s\033[0m %s\n' WEBDAV_HOST "$(WEBDAV_HOST)"
	@printf '  \033[36m%-24s\033[0m %s\n' SCCACHE_WEBDAV_ENDPOINT "$(SCCACHE_WEBDAV_ENDPOINT)"
	@printf '  \033[36m%-24s\033[0m %s\n' WEBDAV_DIR "$(WEBDAV_DIR)"
	@printf '\n\033[1mReproducibility\033[0m\n'
	@printf '  \033[36m%-24s\033[0m %s\n' SDE_EPOCH \
		"$(call bake_default,SDE_EPOCH)  ($(shell date -u -d @$(call bake_default,SDE_EPOCH) '+%Y-%m-%d %H:%M' 2>/dev/null))  (bake)"
	@printf '  %s\n' 'pinned into every image config; SDE_<IMAGE> overrides one'
	@for v in $(foreach i,BASE PYTORCH TRITON AITER RUNTIME NIXL VLLM LMCACHE CUPY,$(if $(SDE_$(i)),SDE_$(i)=$(SDE_$(i)))); do \
		printf '  \033[36m%-24s\033[0m %s\n' "$${v%%=*}" "$${v#*=}  (overridden)"; \
	done
	@printf '\n\033[1mServing\033[0m  (make serve-vllm / serve-stack / serve-test)\n'
	@printf '  \033[36m%-24s\033[0m %s\n' GPU_HOST "$(GPU_HOST)"
	@printf '  \033[36m%-24s\033[0m %s\n' SERVE_MODEL "$(SERVE_MODEL)"
	@printf '  \033[36m%-24s\033[0m %s\n' SERVE_ARCH "$(SERVE_ARCH)  (probed from GPU_HOST, not the build arch)"
	@printf '  \033[36m%-24s\033[0m %s\n' VLLM_TAG "$(VLLM_TAG)"
	@printf '  \033[36m%-24s\033[0m %s\n' LMCACHE_TAG "$(LMCACHE_TAG)"
	@printf '  \033[36m%-24s\033[0m %s\n' VLLM_BIND "$(VLLM_BIND)  (0.0.0.0 to drive it from another host)"
	@printf '  \033[36m%-24s\033[0m %s\n' KV_TIER \
		"$(or $(KV_TIER),$(call compose_default,KV_TIER))  (cpu = L1 only, file = L1 + L2 on disk)  (compose)"
	@printf '  \033[36m%-24s\033[0m %s\n' TRANSFER_MODE \
		"$(or $(TRANSFER_MODE),$(call compose_default,TRANSFER_MODE))  (auto|engine_driven|lmcache_driven)  (compose)"
	@printf '  \033[36m%-24s\033[0m %s\n' HSA_IPC_LEGACY \
		"$(or $(HSA_IPC_LEGACY),$(call compose_default,HSA_IPC_LEGACY))  (1 required for cross-container HIP IPC)  (compose)"
	@printf '  \033[36m%-24s\033[0m %s\n' VLLM_DEV_MODE \
		"$(or $(VLLM_DEV_MODE),$(call compose_default,VLLM_DEV_MODE))  (1 exposes /reset_prefix_cache for serve-test)  (compose)"
	@printf '  \033[36m%-24s\033[0m %s\n' L1_SIZE_GB \
		"$(or $(L1_SIZE_GB),$(call compose_default,L1_SIZE_GB))  (LMCache host-RAM tier)  (compose)"
	@printf '  \033[36m%-24s\033[0m %s\n' CHUNK_SIZE \
		"$(or $(CHUNK_SIZE),$(call compose_default,CHUNK_SIZE))  (tokens per cached chunk)  (compose)"
	@printf '\n\033[1mToggles\033[0m\n'
	@printf '  \033[36m%-24s\033[0m %s\n' TELEMETRY "$(TELEMETRY)  (0 skips metrics collection)"
	@printf '  \033[36m%-24s\033[0m %s\n' FORCE_RECACHE "$(if $(FORCE_RECACHE),$(FORCE_RECACHE),false)  (true = recompile everything, ignoring sccache)"
	@printf '  \033[36m%-24s\033[0m %s\n' BAKE_EXTRA "$(if $(BAKE_EXTRA),$(BAKE_EXTRA),(none))"
	@printf '  \033[36m%-24s\033[0m %s\n' PREBUILD_KERNELS "$(if $(PREBUILD_KERNELS),$(PREBUILD_KERNELS),(from arch: 0 on RDNA, 2 on CDNA))  (bake)"
	@printf '  \033[36m%-24s\033[0m %s\n' PUBLISHED_INPUTS "$(if $(PUBLISHED_INPUTS),$(PUBLISHED_INPUTS),(unset: targets feed each other directly))  (bake)"
	@printf '  \033[36m%-24s\033[0m %s\n' RUN_ID "$(if $(RUN_ID),$(RUN_ID),$(call bake_default,RUN_ID))  (bake; stamped into build records)"
	@printf '  \033[36m%-24s\033[0m %s\n' CACHE_TAG_SUFFIX "$(if $(CACHE_TAG_SUFFIX),$(CACHE_TAG_SUFFIX),(empty: write the rolling tag; -ref refreshes the baseline))  (bake)"
	@printf '  \033[36m%-24s\033[0m %s\n' SCCACHE_LOG "$(if $(SCCACHE_LOG),$(SCCACHE_LOG),warn)  (debug reveals the Cache errors count; env only, see below)"
	@printf '\nOverride any of these on the command line: make <target> VAR=value\n'
	@printf 'SCCACHE_LOG is read by bake from the environment, so it needs\n'
	@printf 'SCCACHE_LOG=debug make <target> rather than make <target> SCCACHE_LOG=debug.\n\n'
