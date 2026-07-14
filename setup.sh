#!/bin/sh
# One-time OpenWrt bootstrap for lan-dash. Run from your workstation; uses
# config.local.sh (copy from config.sh.example). Idempotent.
#
#   1. installs packages (coreutils-sleep for the 2 Hz pinger, ethtool for
#      SFP+ module temps) via apk or opkg, whichever the firmware has
#   2. verifies prerequisites (ucode, brctl, uhttpd, br-lan)
#   3. points DNS name(s) at the dashboard: AdGuard Home rewrites via its API
#      when ADGUARD_URL is set (applies instantly, no restarts), else dnsmasq
#      address records (needs a dnsmasq restart, which briefly blips DNS)
#
# Then run ./deploy.sh to install the dashboard itself.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
[ -f "$DIR/config.local.sh" ] || {
    echo "copy config.sh.example -> config.local.sh and edit it first" >&2
    exit 1
}
. "$DIR/config.local.sh"
: "${ROUTER:?set ROUTER in config.local.sh}"
: "${ALIAS_IP:?set ALIAS_IP in config.local.sh}"

echo "== packages + prerequisites =="
ssh "$ROUTER" PUBLIC_DOMAIN="$PUBLIC_DOMAIN" 'sh -s' <<'EOF'
set -e
# base: coreutils-sleep (2 Hz pinger) + ethtool (SFP+ module temps);
# with PUBLIC_DOMAIN: acme (Let's Encrypt) + ddns-scripts (dynamic DNS)
PKGS="coreutils-sleep ethtool"
[ -n "$PUBLIC_DOMAIN" ] && PKGS="$PKGS acme-common acme-acmesh ddns-scripts"
if command -v apk >/dev/null 2>&1; then
    missing=""
    for p in $PKGS; do apk info -e "$p" >/dev/null 2>&1 || missing="$missing $p"; done
    [ -n "$missing" ] && { apk update >/dev/null; apk add $missing; }
elif command -v opkg >/dev/null 2>&1; then
    missing=""
    for p in $PKGS; do opkg list-installed 2>/dev/null | grep -q "^$p " || missing="$missing $p"; done
    [ -n "$missing" ] && { opkg update >/dev/null; opkg install $missing; }
else
    echo "WARNING: no apk/opkg found — install yourself: $PKGS"
fi
echo "ok: packages ($PKGS)"
for c in ucode brctl uhttpd; do
    command -v "$c" >/dev/null 2>&1 || { echo "MISSING: $c"; exit 1; }
done
[ -d /sys/class/net/br-lan ] || { echo "MISSING: br-lan bridge (adjust scripts for your bridge name)"; exit 1; }
if /bin/sleep 0.1 2>/dev/null; then
    echo "ok: fractional sleep available (ping graph runs at 2 Hz)"
else
    echo "note: no fractional sleep — pinger will degrade to 1 sample/s"
fi
echo "ok: prerequisites"
EOF

echo "== DNS =="
if [ -n "$DASH_NAMES" ] && [ -n "$ADGUARD_URL" ]; then
    jar=$(mktemp)
    curl -s -c "$jar" -X POST "$ADGUARD_URL/control/login" \
        -H 'Content-Type: application/json' \
        --data-binary "{\"name\":\"$ADGUARD_USER\",\"password\":\"$ADGUARD_PASS\"}" > /dev/null
    existing=$(curl -s -b "$jar" "$ADGUARD_URL/control/rewrite/list")
    for name in $DASH_NAMES; do
        if printf '%s' "$existing" | grep -q "\"domain\":\"$name\""; then
            echo "AdGuard rewrite exists: $name"
        else
            curl -s -b "$jar" -X POST "$ADGUARD_URL/control/rewrite/add" \
                -H 'Content-Type: application/json' \
                --data-binary "{\"domain\":\"$name\",\"answer\":\"$ALIAS_IP\"}"
            echo "AdGuard rewrite added: $name -> $ALIAS_IP (active immediately)"
        fi
    done
    rm -f "$jar"
elif [ -n "$DASH_NAMES" ]; then
    ssh "$ROUTER" DASH_NAMES="$DASH_NAMES" ALIAS_IP="$ALIAS_IP" 'sh -s' <<'EOF'
changed=0
for name in $DASH_NAMES; do
    uci show dhcp 2>/dev/null | grep -q "address='/$name/" || {
        uci add_list dhcp.@dnsmasq[0].address="/$name/$ALIAS_IP"
        changed=1
    }
done
[ "$changed" = 1 ] && uci commit dhcp \
    && echo "dnsmasq records added — apply with '/etc/init.d/dnsmasq restart' (brief DNS blip)" \
    || echo "dnsmasq records already present"
EOF
else
    echo "DASH_NAMES not set — skipping DNS; the page will be at http://$ALIAS_IP/"
fi

echo "setup done — now run ./deploy.sh"
