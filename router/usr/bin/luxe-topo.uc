#!/usr/bin/ucode
// luxe-topo.uc — derive the live L2 topology tree for the start page.
//
// Sources (all in /tmp/luxe-raw, refreshed by luxe-statsd):
//   fdb.txt        router bridge FDB as "eth0|eth4 <mac>" lines. eth0 macs
//                  are the TP-Link segment (bridged THROUGH the router);
//                  eth4 macs live somewhere behind the MikroTik.
//   mt-hosts.json  MikroTik CRS305 bridge host table (mac -> sfp port)
//   uf-dev.json    UniFi devices (USW + APs, uplink ports)
//   uf-sta.json    UniFi clients (wireless -> AP, wired -> USW port)
//   /tmp/dhcp.leases  mac -> ip/hostname
//
// Identification is by MAC, never by remembered IPs (house rule).
import { open } from 'fs';

function slurp(path) {
    let f = open(path, 'r');
    if (!f) return null;
    let d = f.read('all');
    f.close();
    return d;
}
function loadjson(path) {
    let d = slurp(path);
    return d ? json(d) : null;
}

// Site specifics arrive via env (set by luxe-statsd from /etc/luxe/config.sh);
// router MACs are runtime-detected there, never configured.
let ROUTER_MACS = {};
for (m in split(getenv('ROUTER_MACS') ?? '', ' '))
    if (m) ROUTER_MACS[lc(m)] = 1;
// Cosmetic labels for known unmanaged switches (invisible at L2, so their
// model can't be detected); unknown clusters just say "switch".
const SWITCH_LABELS = json(getenv('SWITCH_LABELS_JSON') || '{}');
// Known switch-behind-switch cascades: one L2 segment, devices listed on the
// parent could physically hang off either box.
const CASCADES = json(getenv('CASCADES_JSON') || '{}');
// The core switch's own port MACs share this prefix (filtered out).
const CRS_SELF_PREFIX = getenv('CRS_SELF_PREFIX') ?? '';

// ---- leases: mac -> {name, ip}
let lease = {};
for (line in split(slurp('/tmp/dhcp.leases') ?? '', '\n')) {
    let f = split(trim(line), ' ');
    if (length(f) < 4) continue;
    lease[lc(f[1])] = { name: f[3] == '*' ? '' : f[3], ip: f[2] };
}

// ---- router FDB: which macs sit on which bridge leg
let legs = {};        // leg iface -> {mac: 1}
for (line in split(slurp('/tmp/luxe-raw/fdb.txt') ?? '', '\n')) {
    let f = split(trim(line), ' ');
    if (length(f) != 2) continue;
    legs[f[0]] = legs[f[0]] ?? {};
    legs[f[0]][lc(f[1])] = 1;
}
// leg link speeds ("eth0:1000 eth4:10000"), for the branch labels
let legspeed = {};
for (s in split(getenv('LEG_SPEEDS') ?? '', ' ')) {
    let f = split(s, ':');
    if (length(f) == 2) legspeed[f[0]] = +f[1];
}
function speedlabel(mbit) {
    if (!mbit || mbit < 0) return '';
    return mbit >= 1000 ? ' · ' + (mbit / 1000) + 'G' : ' · ' + mbit + 'M';
}

// ---- UniFi devices: infra macs, AP names, USW uplink port
let ufdev = loadjson('/tmp/luxe-raw/uf-dev.json')?.data ?? [];
let infra = {};       // mac -> true (never list as a client)
let apname = {};      // ap mac -> name
let usw = null;
for (d in ufdev) {
    infra[lc(d.mac)] = 1;
    if (d.type == 'uap') apname[lc(d.mac)] = d.name;
    if (d.type == 'usw') usw = d;
}
let usw_uplink = usw?.uplink?.port_idx ?? -1;

// ---- UniFi clients
let ufsta = loadjson('/tmp/luxe-raw/uf-sta.json')?.data ?? [];
let ap_clients = {};  // ap mac -> [dev]
let sw_ports = {};    // port_idx -> [dev]
let uf_known = {};    // macs UniFi already placed
function devent(mac, name, ip) {
    let l = lease[mac];
    return { mac, ip: ip || l?.ip || '', name: name || l?.name || '' };
}
for (s in ufsta) {
    let mac = lc(s.mac);
    if (infra[mac] || ROUTER_MACS[mac]) continue;
    if (s.is_wired) {
        if (s.sw_port == null || s.sw_port == usw_uplink) continue;
        sw_ports[s.sw_port] = sw_ports[s.sw_port] ?? [];
        push(sw_ports[s.sw_port], devent(mac, s.hostname ?? s.name, s.ip));
        uf_known[mac] = 1;
    } else {
        let ap = lc(s.ap_mac ?? '');
        ap_clients[ap] = ap_clients[ap] ?? [];
        push(ap_clients[ap], devent(mac, s.hostname ?? s.name, s.ip));
        uf_known[mac] = 1;
    }
}

// ---- MikroTik host table: sfp port -> macs
let mthosts = loadjson('/tmp/luxe-raw/mt-hosts.json') ?? [];
let crs = {};         // port -> [mac]
let uplink_port = ''; // CRS port toward the router
let unifi_port = '';  // CRS port toward the USW
for (h in (type(mthosts) == 'array' ? mthosts : [])) {
    let mac = lc(h['mac-address']);
    let port = h['on-interface'];
    if (port == 'bridge') continue;
    if (CRS_SELF_PREFIX && index(mac, CRS_SELF_PREFIX) == 0) continue; // CRS self
    if (ROUTER_MACS[mac]) { uplink_port = port; continue; }
    if (usw && mac == lc(usw.mac)) unifi_port = port;
    crs[port] = crs[port] ?? [];
    push(crs[port], mac);
}

// ---- assemble the tree
// name sort, case-insensitive, unnamed (IP-only) entries last
function sortdevs(devs) {
    return sort(devs, (a, b) => {
        let ka = a.name ? lc(a.name) : '~' + a.ip;
        let kb = b.name ? lc(b.name) : '~' + b.ip;
        return ka == kb ? 0 : (ka > kb ? 1 : -1);
    });
}
function devlist(macs) {
    let out = [];
    for (m in macs)
        if (!infra[m] && !ROUTER_MACS[m]) push(out, devent(m));
    return sortdevs(out);
}

// Which bridge leg leads to the core switch? The one where the USW's MAC
// (or, failing that, most MT-branch macs) is learned. Every OTHER leg is a
// local segment and becomes its own branch node.
let uplink_leg = '';
if (usw) {
    for (leg in keys(legs))
        if (legs[leg][lc(usw.mac)]) uplink_leg = leg;
}
if (!uplink_leg && length(keys(crs))) {
    let best = 0;
    for (leg in keys(legs)) {
        let n = 0;
        for (port in keys(crs))
            for (m in crs[port]) if (legs[leg][m]) n++;
        if (n > best) { best = n; uplink_leg = leg; }
    }
}
// macs on local (non-uplink) legs — they leak onto the CRS uplink port too
let localside = {};
let leg_branches = [];
for (leg in sort(keys(legs))) {
    if (leg == uplink_leg) continue;
    let macs = [];
    let swname = 'switch';
    for (m in keys(legs[leg])) {
        if (ROUTER_MACS[m] || infra[m]) continue;
        localside[m] = 1;
        // a managed-but-dumb switch's own lease names the branch (e.g. TL-*)
        if (index(lease[m]?.name ?? '', 'TL-') == 0) { swname = lease[m].name; continue; }
        push(macs, m);
    }
    if (!length(macs)) continue;
    let devs = devlist(macs);
    push(leg_branches, {
        label: leg + speedlabel(legspeed[leg]),
        kind: length(devs) > 1 ? 'switch' : 'direct',
        name: length(devs) > 1 ? swname : '',
        devices: devs,
    });
}

let crs_children = [];
for (port in sort(keys(crs))) {
    if (port == unifi_port || port == uplink_port) continue;
    let macs = filter(crs[port], m => !localside[m] && !uf_known[m]);
    if (!length(macs)) continue;
    let devs = devlist(macs);
    let known = SWITCH_LABELS['crs:' + port];
    let cascade = CASCADES['crs:' + port];
    push(crs_children, {
        label: replace(port, 'sfp-sfpplus', 'SFP+'),
        kind: (known || length(devs) > 1) ? 'switch' : 'direct',
        name: known ?? (length(devs) > 1 ? 'switch' : ''),
        devices: devs,
        children: cascade ? [ {
            label: 'cascade', kind: 'switch', name: cascade, devices: [],
            note: 'same segment — the devices above may hang off either switch',
        } ] : [],
    });
}

let usw_children = [];
for (p in sort(map(keys(sw_ports), k => +k), (a, b) => a - b)) {
    let devs = sortdevs(sw_ports[p]);
    let is_sfp = p >= 9;   // USW-Enterprise-8-PoE: 1-8 RJ45, 9-10 SFP+
    let known = SWITCH_LABELS['usw:' + p];
    push(usw_children, {
        label: 'port ' + p + (is_sfp ? ' · SFP+' : ''),
        kind: (known || length(devs) > 2) ? 'switch' : 'direct',
        name: known ?? (length(devs) > 2 ? 'switch' : ''),
        devices: devs,
    });
}
// APs: count only — the Wireless clients panel already lists everyone
for (d in ufdev) {
    if (d.type != 'uap') continue;
    push(usw_children, {
        label: 'port ' + (d.uplink?.uplink_remote_port ?? '?'),
        kind: 'ap',
        name: d.name,
        devices: [],
        count: length(ap_clients[lc(d.mac)] ?? []),
    });
}

// core subtree only when a MikroTik host table is available
let children = [ ...leg_branches ];
if (length(keys(crs)) || unifi_port) {
    let usw_node = usw ? [ {
        label: replace(unifi_port, 'sfp-sfpplus', 'SFP+'),
        kind: 'unifi', name: usw.name ?? 'UniFi switch',
        children: usw_children,
    } ] : [];
    push(children, {
        label: uplink_leg + speedlabel(legspeed[uplink_leg]) +
               replace(uplink_port, 'sfp-sfpplus', ' → SFP+'),
        kind: 'core', name: 'MikroTik core switch',
        children: [ ...crs_children, ...usw_node ],
    });
} else if (usw) {
    // no MikroTik: hang the UniFi subtree straight off the router
    push(children, {
        label: uplink_leg + speedlabel(legspeed[uplink_leg]),
        kind: 'unifi', name: usw.name ?? 'UniFi switch',
        children: usw_children,
    });
}

printf("%J\n", { ts: time(), tree: { name: 'Router', children } });
