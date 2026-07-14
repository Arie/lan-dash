#!/bin/sh
# Deploy the lan-dash dashboard to the router.
# Idempotent — safe to re-run after editing www/, the collectors, or config.
#
# Needs two gitignored local files (copy from the .example versions):
#   config.local.sh   secrets + network shape -> pushed to /etc/luxe/config.sh
#   www/site.json     passwords/addresses the page displays
#
# What it does (all ADDITIVE — no fw4 reload, no AdGuard/dnsmasq restart):
#   1. Copies www/ + site.json to $WEB_ROOT (+ data -> /tmp/luxe symlink)
#   2. Installs the collectors + procd init scripts
#   3. Pushes config.local.sh to /etc/luxe/config.sh
#   4. Adds IP alias $ALIAS_IP/24 on br-lan (live + uci, NO network reload)
#   5. Adds uhttpd instance "luxe" on $ALIAS_IP:80 (restarts uhttpd only —
#      brief LuCI blip, nothing else)
#   6. Registers files in /etc/sysupgrade.conf
#
# DNS rewrites (luxe, luxe.lan -> $ALIAS_IP) are added separately via the
# AdGuard API — see README.md — because they only ever need to happen once.
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
if [ ! -f "$DIR/config.local.sh" ] || [ ! -f "$DIR/www/site.json" ]; then
    echo "missing config: copy config.sh.example -> config.local.sh and" >&2
    echo "www/site.json.example -> www/site.json, then edit both" >&2
    exit 1
fi
. "$DIR/config.local.sh"
: "${ROUTER:?set ROUTER in config.local.sh}"
: "${ALIAS_IP:?set ALIAS_IP in config.local.sh}"
WEB_ROOT="${WEB_ROOT:-/mnt/nvme0n1p1/luxe/www}"

echo "== copying files =="
ssh "$ROUTER" "mkdir -p '$WEB_ROOT' /etc/luxe"
for f in index.html style.css app.js site.json; do
    ssh "$ROUTER" "cat > '$WEB_ROOT/$f'" < "$DIR/www/$f"
done
ssh "$ROUTER" 'cat > /etc/luxe/config.sh' < "$DIR/config.local.sh"
for f in luxe-statsd luxe-pinger luxe-wifi.uc luxe-gear.uc luxe-topo.uc; do
    ssh "$ROUTER" "cat > /usr/bin/$f && chmod +x /usr/bin/$f" < "$DIR/router/usr/bin/$f"
done
for f in luxe-statsd luxe-pinger; do
    ssh "$ROUTER" "cat > /etc/init.d/$f && chmod +x /etc/init.d/$f" < "$DIR/router/etc/init.d/$f"
done

echo "== configuring router =="
ssh "$ROUTER" ALIAS_IP="$ALIAS_IP" WEB_ROOT="$WEB_ROOT" 'sh -s' <<'EOF'
set -e
mkdir -p /tmp/luxe
ln -sfn /tmp/luxe "$WEB_ROOT/data"

# IP alias: live (idempotent) + persisted. NO network reload — the live add
# covers now, uci covers reboot. (Golden rule: don't restart what's serving.)
ip addr show br-lan | grep -q "inet $ALIAS_IP/" || ip addr add "$ALIAS_IP/24" dev br-lan
uci show network.lan.ipaddr | grep -q "$ALIAS_IP" || {
    uci add_list network.lan.ipaddr="$ALIAS_IP/24"
    uci commit network
}

# uhttpd instance "luxe" — static files only, no CGI, no TLS
if ! uci -q get uhttpd.luxe >/dev/null; then
    uci set uhttpd.luxe=uhttpd
    uci add_list uhttpd.luxe.listen_http="$ALIAS_IP:80"
    uci set uhttpd.luxe.home="$WEB_ROOT"
    uci set uhttpd.luxe.max_requests='5'
    uci set uhttpd.luxe.max_connections='100'
    uci set uhttpd.luxe.network_timeout='15'
    uci set uhttpd.luxe.http_keepalive='20'
    uci set uhttpd.luxe.tcp_keepalive='1'
    uci commit uhttpd
    /etc/init.d/uhttpd restart     # brief LuCI blip only
fi

/etc/init.d/luxe-statsd enable
/etc/init.d/luxe-statsd restart
/etc/init.d/luxe-pinger enable
/etc/init.d/luxe-pinger restart

for f in /usr/bin/luxe-statsd /usr/bin/luxe-pinger /usr/bin/luxe-wifi.uc /usr/bin/luxe-gear.uc /usr/bin/luxe-topo.uc \
         /etc/init.d/luxe-statsd /etc/init.d/luxe-pinger /etc/luxe/config.sh; do
    grep -qx "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done
EOF

echo "== verifying =="
sleep 5
ssh "$ROUTER" "
pgrep -f /usr/bin/luxe-statsd >/dev/null && echo 'statsd: running' || echo 'statsd: NOT RUNNING'
pgrep -f /usr/bin/luxe-pinger >/dev/null && echo 'pinger: running' || echo 'pinger: NOT RUNNING'
netstat -tln | grep -q '$ALIAS_IP:80' && echo 'uhttpd: listening on $ALIAS_IP:80' || echo 'uhttpd: NOT LISTENING'
for j in net sys cache wifi ping gear topo; do
    ls /tmp/luxe/\$j.json >/dev/null 2>&1 && echo \"\$j.json: present\" || echo \"\$j.json: missing (wait ~15 s)\"
done
"
echo "done — check http://$ALIAS_IP/"
