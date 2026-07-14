#!/usr/bin/ucode
// luxe-wifi.uc — distill UniFi controller dumps (stat/device + stat/sta) into
// the compact wifi.json the start page polls. The raw dumps are 80+ KB and
// carry device secrets (auth keys etc.) — they live in /tmp/luxe-raw, OUTSIDE
// the served directory; only this shaped output is public to the LAN.
import { open } from 'fs';

function load(path) {
    let f = open(path, 'r');
    if (!f) return null;
    let d = json(f.read('all'));
    f.close();
    return d?.data;
}

let devs = load('/tmp/luxe-raw/uf-dev.json') ?? [];
let stas = load('/tmp/luxe-raw/uf-sta.json') ?? [];

let aps = [];
let sw = null;
let apname = {};

for (d in devs) {
    if (d.type == 'uap') {
        apname[d.mac] = d.name;
        let radios = [];
        for (r in (d.radio_table_stats ?? [])) {
            push(radios, {
                band: r.radio == 'na' ? '5' : '2.4',
                ch: r.channel,
                util: r.cu_total ?? 0,     // airtime busy %, incl. neighbours' noise
                sta: r.num_sta ?? 0,
            });
        }
        push(aps, {
            name: d.name,
            model: d.model,
            ip: d.ip,
            uptime: +(d['system-stats']?.uptime ?? 0),
            radios: radios,
        });
    }
    else if (d.type == 'usw') {
        let poe_ports = length(filter(d.port_table ?? [], p => +(p.poe_power ?? 0) > 0));
        sw = {
            name: d.name,
            poe_w: +(d.total_used_power ?? 0),
            poe_ports: poe_ports,
            temp_c: d.has_temperature ? d.general_temperature : null,
            fan: d.fan_level ?? null,
        };
    }
}

let clients = [];
let wired = 0;
for (s in stas) {
    if (s.is_wired) { wired++; continue; }
    push(clients, {
        name: s.hostname ?? s.name ?? '',
        ip: s.ip ?? '',
        ssid: s.essid ?? '',
        ap: apname[s.ap_mac] ?? '?',
        band: s.radio == 'na' ? '5' : '2.4',
        signal: s.signal ?? -99,
        mbps: int((s.tx_rate ?? 0) / 1000),   // negotiated PHY rate, AP->client
        sat: s.satisfaction ?? -1,
    });
}

clients = sort(clients, (a, b) => b.signal - a.signal);   // strongest first

printf("%J\n", {
    ts: time(),
    aps: aps,
    sw: sw,
    clients: clients,
    counts: { wired: wired, wireless: length(clients) },
});
