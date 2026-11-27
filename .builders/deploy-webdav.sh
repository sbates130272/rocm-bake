#!/bin/bash
# deploy-webdav.sh - Durable sccache object store on SNOC Strix.
#
# Durable by design: the objects are files on disk, so a power cycle
# on Strix leaves the fleet's compiler cache intact. An in-RAM store
# does not survive one, and an overflow-to-disk tier is not the same
# thing — it is a spill target, not something read back at startup.
#
# WebDAV rather than S3/MinIO: dl.min.io is blocked by the corporate
# proxy and MinIO is not packaged, whereas nginx with the dav modules
# is a normal apt install. sccache speaks WebDAV natively via
# SCCACHE_WEBDAV_ENDPOINT.
#
# Usage: sudo ./deploy-webdav.sh [port]
#
# Storage is a plain directory tree, so it survives reboots and can be
# backed up with rsync. It is bounded by the daily LRU prune this
# script installs from `cache.budget_gb:` — nothing in nginx or sccache
# bounds it otherwise. See the Eviction section below.

set -euo pipefail

# Port and storage path from the fleet manifest, so the builders and
# this deployer cannot disagree about where the store is. An argument
# still wins, for a one-off on a nonstandard port.
_fleet() { python3 -I "$(dirname "${BASH_SOURCE[0]}")/fleet.py" --make 2>/dev/null \
    | sed -n "s/^$1=//p"; }
PORT="${1:-$(_fleet FLEET_CACHE_PORT)}"
PORT="${PORT:-8081}"
DATA_DIR="${DATA_DIR:-$(_fleet FLEET_CACHE_DIR)}"
DATA_DIR="${DATA_DIR:-/var/cache/sccache-webdav}"
# Empty means no ceiling and no timer — see `cache.budget_gb:` in the
# manifest for why a store with no ceiling is a bug and not a default.
BUDGET_GB="${BUDGET_GB:-$(_fleet FLEET_CACHE_BUDGET_GB)}"
SITE=/etc/nginx/sites-available/sccache-webdav
PRUNE_BIN=/usr/local/sbin/sccache-prune.sh

echo "=== sccache WebDAV store deployer ==="
echo "Port:    ${PORT}"
echo "Storage: ${DATA_DIR}"
echo "Budget:  ${BUDGET_GB:-none (store grows unbounded)}${BUDGET_GB:+ GB}"

if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (sudo)"
   exit 1
fi

echo "📦 Installing nginx with the DAV modules..."
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq nginx-extras > /dev/null

# Which address nginx binds, from the manifest's `cache.bind:`.
#
#   tailscale  the node's tailnet address (the default, and what the
#              SNOC fleet uses — it keeps the store off every other
#              interface including the public one)
#   private    the host's primary address, for a fleet whose nodes
#              share a private network instead of a tailnet
#   <address>  that address, verbatim
BIND_MODE="${BIND_MODE:-$(_fleet FLEET_CACHE_BIND)}"
BIND_MODE="${BIND_MODE:-tailscale}"
case "${BIND_MODE}" in
    tailscale)
        TAILNET_IP=$(tailscale ip -4 2>/dev/null | head -1)
        if [ -z "${TAILNET_IP}" ]; then
            echo "❌ No tailnet address; the other build nodes could not reach this."
            echo "   Set cache.bind: private in the manifest for a fleet that"
            echo "   shares a private network instead."
            exit 1
        fi ;;
    private)
        TAILNET_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [ -z "${TAILNET_IP}" ]; then
            echo "❌ No private address to bind."
            exit 1
        fi ;;
    *)  TAILNET_IP="${BIND_MODE}" ;;
esac
echo "🔗 Binding to 127.0.0.1 and ${TAILNET_IP} (${BIND_MODE})"

install -d -o www-data -g www-data -m 755 "${DATA_DIR}"

# nginx binds the tailnet address explicitly, to keep the store off the
# public interface. But at boot nginx starts before tailscaled has
# assigned that address, and bind() fails with EADDRNOTAVAIL — the
# service then stays down until someone restarts it by hand, which is
# how a reboot took the fleet's cache offline while the data itself was
# perfectly intact. Two independent guards, because either alone has a
# race: allow binding an address that does not exist yet, and order the
# unit after tailscaled so it usually does.
echo "🔧 Making the tailnet bind survive a reboot..."
cat > /etc/sysctl.d/99-sccache-webdav.conf << 'EOF'
# Lets nginx bind the tailnet address before tailscaled brings it up.
net.ipv4.ip_nonlocal_bind = 1
EOF
sysctl -q -p /etc/sysctl.d/99-sccache-webdav.conf

install -d -m 755 /etc/systemd/system/nginx.service.d
if [ "${BIND_MODE}" = tailscale ]; then
    cat > /etc/systemd/system/nginx.service.d/10-tailscale.conf << 'EOF'
# Managed by .builders/deploy-webdav.sh
[Unit]
After=tailscaled.service network-online.target
Wants=network-online.target
EOF
else
    # Nothing to wait for but the network itself. The drop-in is still
    # written rather than left behind from a previous bind mode, which
    # would order nginx after a tailscaled that is never going to start.
    cat > /etc/systemd/system/nginx.service.d/10-tailscale.conf << 'EOF'
# Managed by .builders/deploy-webdav.sh
[Unit]
After=network-online.target
Wants=network-online.target
EOF
fi
systemctl daemon-reload

cat > "${SITE}.new" << EOF
# Managed by .builders/deploy-webdav.sh — edits here are overwritten.
#
# sccache PUTs objects under a key prefix and GETs them back. It does
# not need the full DAV verb set, but create_full_put_path is essential:
# keys are nested (ab/cd/<hash>) and sccache does not MKCOL first.
# \$request_length, which the stock combined format omits. It logs
# \$body_bytes_sent — the size of the *response* — so a PUT, which is
# the only request that writes to the cache, was recorded as a couple
# of hundred bytes regardless of the object it carried. The request
# length is the object, so this is what makes "what was written to
# sccache, and when" answerable from the log rather than inferable
# from polling the store's total size.
#
# \$request_time too: an object that took 30s to upload is a different
# event from one that took 0.2s, and only one of them is a problem.
log_format sccache '\$time_iso8601 \$remote_addr \$request_method \$uri '
                   '\$status req=\$request_length resp=\$body_bytes_sent '
                   'secs=\$request_time';

server {
    listen ${TAILNET_IP}:${PORT};
    listen 127.0.0.1:${PORT};
    server_name _;

    # Its own log, not the shared access.log: this one is parsed by
    # .builders/perfreport.py, and sharing a file with every other
    # vhost means every parse starts by discarding someone else's
    # traffic.
    access_log /var/log/nginx/sccache.log sccache;

    root ${DATA_DIR};

    # Compiler objects are large and sccache streams them in one PUT.
    client_max_body_size 0;
    client_body_timeout 300s;
    send_timeout 300s;

    dav_methods PUT DELETE MKCOL COPY MOVE;
    dav_ext_methods PROPFIND OPTIONS;
    create_full_put_path on;
    dav_access user:rw group:rw all:r;

    # Access control is the tailnet, as with Zot.
    # Do not add a public interface to the listen lines above.
    autoindex on;
}
EOF

# Only touch nginx when the site actually changed. This script is
# re-run by the Ansible role on every converge, and it used to
# `systemctl restart nginx` unconditionally — which drops every
# in-flight sccache PUT, so converging the fleet during a build cost
# that build its uploads. A reload is graceful (in-flight requests
# finish on the old worker) and is all a site change needs; a restart
# is only correct when nginx is not running at all.
if cmp -s "${SITE}.new" "${SITE}" 2>/dev/null; then
    SITE_CHANGED=false
    rm -f "${SITE}.new"
else
    SITE_CHANGED=true
    mv "${SITE}.new" "${SITE}"
fi

ln -sf "${SITE}" /etc/nginx/sites-enabled/sccache-webdav
rm -f /etc/nginx/sites-enabled/default

echo "🔧 Checking nginx config..."
nginx -t

systemctl enable nginx > /dev/null 2>&1
if ! systemctl is-active --quiet nginx; then
    echo "🚀 Starting nginx..."
    systemctl start nginx
elif [ "${SITE_CHANGED}" = true ]; then
    echo "🚀 Reloading nginx (site changed)..."
    systemctl reload nginx
else
    echo "🚀 nginx already serving this site unchanged — not reloading"
fi

sleep 2
if ! systemctl is-active --quiet nginx; then
    echo "❌ nginx failed to start: journalctl -u nginx -n 50"
    exit 1
fi

echo "🧪 Round-tripping a test object..."
probe="http://${TAILNET_IP}:${PORT}/.probe/test"
if curl -fsS -T /etc/hostname "${probe}" > /dev/null 2>&1 \
   && curl -fsS "${probe}" > /dev/null 2>&1; then
    curl -fsS -X DELETE "${probe}" > /dev/null 2>&1 || true
    echo "✅ PUT and GET both work"
else
    echo "❌ WebDAV round-trip failed; check nginx error log"
    exit 1
fi

# ── Eviction ─────────────────────────────────────────────────────
#
# nginx DAV only ever writes. Nothing in the serving path removes an
# object, and sccache cannot help: SCCACHE_CACHE_SIZE bounds its local
# disk cache and is not consulted at all for a WebDAV backend, where
# the server owns eviction. So the store grows monotonically until the
# filesystem fills, which on the registry node means taking Zot down
# with it.
#
# LRU by atime, not mtime. mtime is when an object was compiled, which
# says nothing about whether anything still needs it — and the store's
# dead weight is precisely the objects that are old *and* unread (a
# compiler bump orphans every object keyed to the old one in a single
# day). / is mounted relatime, so atime advances at most once a day
# per file: coarse, but a day's resolution is far finer than the
# months this policy works in.
PRUNE_CHANGED=false
if [ -n "${BUDGET_GB}" ]; then
    echo "🧹 Installing the LRU prune (${BUDGET_GB} GB ceiling)..."
    cat > "${PRUNE_BIN}" << EOF
#!/bin/bash
# Managed by .builders/deploy-webdav.sh — edits here are overwritten.
#
# Evict least-recently-read objects until the store is under budget.
# Safe by construction: the store is content-addressed, so a deleted
# object is a cache miss and a recompile, never a wrong answer, and
# unlinking a file nginx has open is fine on POSIX — an in-flight GET
# finishes from the open descriptor, a later one 404s and sccache
# treats that as a miss.
#
# --dry-run reports what it would remove and removes nothing.
set -euo pipefail

DATA_DIR="\${DATA_DIR:-${DATA_DIR}}"
BUDGET_GB="\${BUDGET_GB:-${BUDGET_GB}}"
DRY_RUN=false
[ "\${1:-}" = --dry-run ] && DRY_RUN=true

# A prune that computed an empty or absurd root would delete the
# machine. Refuse rather than guess.
case "\${DATA_DIR}" in
    ""|/|/usr|/var|/etc|/home)
        echo "refusing to prune \${DATA_DIR:-<empty>}" >&2; exit 1 ;;
esac
[ -d "\${DATA_DIR}" ] || { echo "no store at \${DATA_DIR}" >&2; exit 0; }

budget=\$(( BUDGET_GB * 1024 * 1024 * 1024 ))
used=\$(du -sb "\${DATA_DIR}" | cut -f1)

if [ "\${used}" -le "\${budget}" ]; then
    printf 'sccache-prune: %.1f GB of %s GB budget, nothing to do\n' \\
        "\$(echo "\${used} 1073741824" | awk '{print \$1/\$2}')" "\${BUDGET_GB}"
    exit 0
fi

# Oldest read first. The subshell the pipe creates cannot export its
# running total back, so it prints the summary itself.
find "\${DATA_DIR}" -type f -printf '%A@ %s %p\0' \\
  | sort -zn \\
  | { freed=0; n=0; u=\${used}; \\
      while IFS=' ' read -r -d '' _atime size path; do
          [ "\${u}" -le "\${budget}" ] && break
          if [ "\${DRY_RUN}" = true ] || rm -f -- "\${path}"; then
              u=\$(( u - size )); freed=\$(( freed + size )); n=\$(( n + 1 ))
          fi
      done
      printf 'sccache-prune: %s %d objects, %.1f GB; store %.1f GB -> %.1f GB (budget %s GB)\n' \\
        "\$([ "\${DRY_RUN}" = true ] && echo would-remove || echo removed)" \\
        "\${n}" \\
        "\$(awk -v b=\${freed} 'BEGIN{print b/1073741824}')" \\
        "\$(awk -v b=\${used}  'BEGIN{print b/1073741824}')" \\
        "\$(awk -v b=\${u}     'BEGIN{print b/1073741824}')" \\
        "\${BUDGET_GB}"; }

# sccache nests keys ab/cd/<hash> and never MKCOLs, so the tree grows
# a leaf directory per prefix and eviction leaves them behind empty.
# Without this they accumulate faster than the objects do.
[ "\${DRY_RUN}" = true ] || find "\${DATA_DIR}" -mindepth 1 -type d -empty -delete
EOF
    chmod 755 "${PRUNE_BIN}"

    cat > /etc/systemd/system/sccache-prune.service << EOF
# Managed by .builders/deploy-webdav.sh
[Unit]
Description=Evict least-recently-used objects from the sccache store
# The store is nginx's to serve; pruning it while nginx is down is
# harmless but pointless, and ordering keeps the journal readable.
After=nginx.service

[Service]
Type=oneshot
ExecStart=${PRUNE_BIN}
# du and find over ~10^5 files; nice it so a prune landing mid-build
# costs the compile nothing it would notice.
Nice=10
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/sccache-prune.timer << 'EOF'
# Managed by .builders/deploy-webdav.sh
[Unit]
Description=Daily LRU prune of the sccache store

[Timer]
# 04:20 rather than a round hour: nothing else on this node should be
# running then, and the offset keeps it clear of every other daily
# timer that defaults to midnight.
OnCalendar=*-*-* 04:20:00
# A node that was off at 04:20 still prunes once it is back, rather
# than skipping a day and letting the store drift over budget.
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    if ! systemctl is-enabled --quiet sccache-prune.timer 2>/dev/null; then
        PRUNE_CHANGED=true
    fi
    systemctl enable --now sccache-prune.timer > /dev/null 2>&1
    echo "   next run: $(systemctl show sccache-prune.timer -p NextElapseUSecRealtime --value)"
else
    echo "⚠️  No cache.budget_gb in the manifest — the store has no ceiling."
    echo "   nginx DAV never deletes and sccache's own size limit does not"
    echo "   apply to a WebDAV backend, so it will grow until the disk fills."
fi

echo ""
echo "=== Deployment Complete ==="
echo "Store:   http://${TAILNET_IP}:${PORT}"
echo "Data:    ${DATA_DIR} (durable; survives reboot)"
if [ -n "${BUDGET_GB}" ]; then
echo "Prune:   ${BUDGET_GB} GB ceiling, daily; ${PRUNE_BIN} --dry-run to preview"
fi
echo ""
echo "Builds use it via SCCACHE_WEBDAV_ENDPOINT, already the default in"
echo "rocm-bake.hcl. Inspect it with: make cache-summary"

# The Ansible role keys `changed_when` off this line. Before it
# existed the role matched on "Store:", which every run prints, so
# every converge reported a change and nobody could see a real one.
if [ "${SITE_CHANGED}" = true ] || [ "${PRUNE_CHANGED}" = true ]; then
    echo "Changed: yes"
else
    echo "Changed: no"
fi
