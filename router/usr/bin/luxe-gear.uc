#!/usr/bin/ucode
// luxe-gear.uc — shape network-gear temperatures into gear.json.
// Inputs: MikroTik REST dumps in /tmp/luxe-raw (health + ethernet monitor),
// R86S values via env (SFP_C = ethtool -m module temp, NIC_C = mlx5 hwmon).
import { open } from 'fs';

function load(path) {
    let f = open(path, 'r');
    if (!f) return null;
    let d = json(f.read('all'));
    f.close();
    return d;
}

let health = load('/tmp/luxe-raw/mt-health.json');
let mon = load('/tmp/luxe-raw/mt-mon.json');

let mt = null;
if (type(health) == 'array') {
    mt = { cpu_c: null, sfp: [] };
    for (h in health)
        if (h.name == 'cpu-temperature') mt.cpu_c = +h.value;
    for (m in (type(mon) == 'array' ? mon : []))
        if (m['sfp-temperature'])
            push(mt.sfp, { port: +substr(m.name, -1), c: +m['sfp-temperature'] });
}

let sfp = +getenv('SFP_C');
let nic = +getenv('NIC_C');

printf("%J\n", {
    ts: time(),
    r86s: { sfp_c: sfp > 0 ? sfp : null, nic_c: nic > 0 ? nic : null },
    mikrotik: mt,
});
