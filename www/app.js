/* LuxeLAN start page — polls JSON snapshots written by luxe-statsd
   (served from /data -> /tmp/luxe). No libraries, no external requests. */
"use strict";

const NET_MS = 3000, SYS_MS = 3000, CACHE_MS = 15000, PING_MS = 500;
const $ = (id) => document.getElementById(id);
let lastOk = 0;

/* ---------------- formatting ---------------- */
function fmtBits(bps) {
  if (bps >= 1e9) return (bps / 1e9).toFixed(2) + " Gbit/s";
  if (bps >= 1e6) return (bps / 1e6).toFixed(1) + " Mbit/s";
  if (bps >= 1e3) return (bps / 1e3).toFixed(0) + " kbit/s";
  return bps + " bit/s";
}
function fmtBytes(b) {
  if (b >= 1e12) return (b / 1e12).toFixed(2) + " TB";
  if (b >= 1e9) return (b / 1e9).toFixed(1) + " GB";
  if (b >= 1e6) return (b / 1e6).toFixed(1) + " MB";
  return Math.round(b / 1e3) + " kB";
}
function fmtUptime(s) {
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600);
  return d > 0 ? `${d}d ${h}h` : `${h}h ${Math.floor((s % 3600) / 60)}m`;
}
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

async function getJSON(url) {
  const r = await fetch(url, { cache: "no-store" });
  if (!r.ok) throw new Error(url + " " + r.status);
  return r.json();
}

/* ---------------- ping sparkline ---------------- */
const SVG_NS = "http://www.w3.org/2000/svg";
// latency quality bands: blue = LAN-grade, greens = great, then via lime and
// yellow to red as it degrades toward 100 ms
const PING_BANDS = [
  [10, "#3987e5"],  // < 10 ms  blue
  [15, "#008300"],  // 10–15    dark green
  [20, "#0ca30c"],  // 15–20    light green
  [30, "#9db312"],  // 20–30    lime
  [50, "#fab219"],  // 30–50    yellow
  [75, "#ec835a"],  // 50–75    orange
  [Infinity, "#d03b3b"], // 75+  red
];
function pingColor(v) {
  for (const [lim, c] of PING_BANDS) if (v < lim) return c;
}
function renderPing(p) {
  if (!p) return;
  const rtt = $("ping-rtt");
  rtt.textContent = p.rtt_ms >= 0 ? Number(p.rtt_ms).toFixed(1) + " ms" : "down?";
  rtt.style.color = p.rtt_ms >= 0 ? pingColor(p.rtt_ms) : "#d03b3b";
  const loss = $("ping-loss");
  loss.hidden = !p.loss_pct;
  loss.textContent = p.loss_pct + "% loss";

  // MTR-style window stats; jitter = mean |Δ| of consecutive good samples
  const valid = (p.samples || []).filter((v) => v >= 0);
  if (valid.length) {
    const avg = valid.reduce((a, b) => a + b, 0) / valid.length;
    let dsum = 0, dn = 0;
    for (let i = 1; i < p.samples.length; i++) {
      if (p.samples[i] >= 0 && p.samples[i - 1] >= 0) {
        dsum += Math.abs(p.samples[i] - p.samples[i - 1]);
        dn++;
      }
    }
    const f = (v) => v.toFixed(1);
    $("ping-stats").textContent =
      `min ${f(Math.min(...valid))} · avg ${f(avg)} · max ${f(Math.max(...valid))}` +
      (dn ? ` · jitter ${f(dsum / dn)}` : "") + " ms";
  }

  const svg = $("ping-graph");
  svg.textContent = "";
  const s = p.samples || [];
  pingSamples = s;
  pingRate = p.rate || 1;
  if (!s.length) return;
  const W = 240, H = 44, PAD = 3;
  const max = Math.max(40, ...s.filter((v) => v >= 0)) * 1.1;
  const x = (i) => (i / Math.max(1, s.length - 1)) * W;
  const y = (v) => H - PAD - Math.min(1, v / max) * (H - 2 * PAD);
  // pairwise segments, each colored by the band of its mean value;
  // lost samples break the line and draw a full-height red bar
  for (let i = 0; i < s.length; i++) {
    const v = s[i];
    if (v < 0) {
      const bar = document.createElementNS(SVG_NS, "line");
      bar.setAttribute("x1", x(i)); bar.setAttribute("x2", x(i));
      bar.setAttribute("y1", PAD); bar.setAttribute("y2", H - PAD);
      bar.setAttribute("class", "ping-loss-bar");
      bar.setAttribute("vector-effect", "non-scaling-stroke");
      svg.append(bar);
      continue;
    }
    if (i === 0 || s[i - 1] < 0) continue;
    const seg = document.createElementNS(SVG_NS, "line");
    seg.setAttribute("x1", x(i - 1).toFixed(1)); seg.setAttribute("y1", y(s[i - 1]).toFixed(1));
    seg.setAttribute("x2", x(i).toFixed(1)); seg.setAttribute("y2", y(v).toFixed(1));
    seg.setAttribute("class", "ping-line");
    seg.setAttribute("stroke", pingColor((v + s[i - 1]) / 2));
    seg.setAttribute("vector-effect", "non-scaling-stroke");
    svg.append(seg);
  }
}

/* hover: crosshair + tooltip with the sample value and its age */
let pingSamples = [];
let pingRate = 1;
(() => {
  const wrap = $("ping-wrap"), tip = $("ping-tip"), cross = $("ping-cross");
  const hide = () => { tip.hidden = true; cross.hidden = true; };
  wrap.addEventListener("pointerleave", hide);
  wrap.addEventListener("pointermove", (ev) => {
    const n = pingSamples.length;
    if (!n) { hide(); return; }
    const r = wrap.getBoundingClientRect();
    const frac = Math.min(1, Math.max(0, (ev.clientX - r.left) / r.width));
    const i = Math.round(frac * (n - 1));
    const px = (i / Math.max(1, n - 1)) * r.width;
    const v = pingSamples[i];
    const sec = (n - 1 - i) / pingRate;
    tip.textContent = (v < 0 ? "packet lost" : Number(v).toFixed(1) + " ms") +
      " · " + (sec ? (Number.isInteger(sec) ? sec : sec.toFixed(1)) + " s ago" : "now");
    tip.className = "ping-tip" + (v < 0 ? " lost" : "");
    tip.hidden = false;
    cross.hidden = false;
    cross.style.left = px + "px";
    // keep the tooltip inside the wrapper
    tip.style.left = "0px";
    tip.hidden = false;
    const tw = tip.offsetWidth;
    tip.style.left = Math.min(Math.max(px - tw / 2, 0), r.width - tw) + "px";
  });
})();

/* ---------------- net: WAN + hosts ---------------- */
function renderNet(d) {
  // client flows only; the raw table also holds docker-internal + WAN noise
  const conns = $("conns");
  conns.textContent = (d.conns_lan ?? d.conns).toLocaleString();
  conns.title = d.conns.toLocaleString() + " flows tracked in total (incl. docker + inbound noise)";
  $("wan-down").textContent = fmtBits(d.wan.down_bps);
  $("wan-up").textContent = fmtBits(d.wan.up_bps);
  $("wan-down-bar").style.width = Math.min(100, 100 * d.wan.down_bps / d.wan.down_max) + "%";
  $("wan-up-bar").style.width = Math.min(100, 100 * d.wan.up_bps / d.wan.up_max) + "%";

  const hosts = d.hosts
    .slice()
    .sort((a, b) => (b.down_bps + b.up_bps) - (a.down_bps + a.up_bps) || b.conns - a.conns)
    .slice(0, 30);
  // bar scale: current view max, but never below 10 Mbit so idle noise stays small
  const max = Math.max(10e6, ...hosts.map((h) => Math.max(h.down_bps, h.up_bps)));

  const box = $("hosts");
  box.textContent = "";
  if (!hosts.length) { box.append(el("p", "empty", "nobody's talking — suspicious")); return; }
  for (const h of hosts) {
    const row = el("div", "host-row");
    const name = el("div", "host-name", h.name || h.ip);
    if (h.name) name.append(el("small", "", h.ip));
    const bars = el("div", "host-bars");
    for (const [cls, v] of [["down", h.down_bps], ["up", h.up_bps]]) {
      const bar = el("div", "host-bar " + cls);
      bar.style.width = Math.max(v > 0 ? 0.6 : 0, 100 * v / max) + "%";
      bars.append(bar);
    }
    const rates = el("div", "host-rates");
    rates.append(
      el("b", "", fmtBits(h.down_bps + h.up_bps)),
      el("br"),
      el("small", "", `↓ ${fmtBits(h.down_bps)} · ↑ ${fmtBits(h.up_bps)}`)
    );
    row.append(name, bars, rates, el("div", "host-conns", h.conns + " conn"));
    box.append(row);
  }
}

/* ---------------- sys: router health ---------------- */
function tempClass(c, warn = 60, hot = 75) {
  return c < warn ? "temp-good" : c < hot ? "temp-warning" : "temp-serious";
}
function setTemp(id, mc, warn, hot) {
  const c = Math.round(mc / 1000);
  const n = $(id);
  n.textContent = mc ? c + "°C" : "—";
  n.className = "tile-value " + (mc ? tempClass(c, warn, hot) : "");
}

/* gear.json: SFP+/NIC + MikroTik temps. Optics and switch ASICs run hot by
   design, so they get laxer thresholds than the CPU/NVMe tiles. */
let lastGear = null;
function renderGear(d) {
  lastGear = d;
  setTemp("temp-sfp", (d.r86s.sfp_c || 0) * 1000, 65, 75);
  setTemp("temp-nic", (d.r86s.nic_c || 0) * 1000, 85, 100);
  renderTopo();   // MikroTik temps ride on its topology node
}
function renderSys(d) {
  $("uptime").textContent = fmtUptime(d.uptime);
  setTemp("temp-cpu", d.temp.cpu_mc);
  setTemp("temp-nvme", d.temp.nvme_mc);
  $("load").textContent = d.load[0].toFixed(2);
  $("procs").textContent = d.procs;

  const cpus = $("cpus");
  cpus.textContent = "";
  for (const c of d.cpus) {
    const row = el("div", "cpu-row");
    const label = c.id === "cpu" ? "all" : "core " + c.id.slice(3);
    const meter = el("div", "meter slim");
    const fill = el("div", "meter-fill fill-down");
    fill.style.width = c.pct + "%";
    meter.append(fill);
    row.append(el("span", "lbl", label), meter, el("span", "pct", c.pct + "%"));
    cpus.append(row);
  }

  const usedKb = d.mem.total_kb - d.mem.avail_kb;
  $("mem").textContent = `${(usedKb / 1048576).toFixed(1)} / ${(d.mem.total_kb / 1048576).toFixed(0)} GB`;
  $("mem-bar").style.width = (100 * usedKb / d.mem.total_kb).toFixed(0) + "%";

  $("disk").textContent = `${(d.disk.used_kb / 1048576).toFixed(0)} / ${(d.disk.total_kb / 1048576).toFixed(0)} GB (${d.disk.pct}%)`;
  const diskBar = $("disk-bar");
  diskBar.style.width = d.disk.pct + "%";
  diskBar.className = "meter-fill fill-cache" + (d.disk.pct >= 97 ? " crit" : d.disk.pct >= 93 ? " warn" : "");

  const tb = $("top-procs");
  tb.textContent = "";
  for (const p of d.top) {
    const tr = el("tr");
    tr.append(el("td", "num", p.cpu + "%"), el("td", "cmd", p.cmd), el("td", "num", "pid " + p.pid));
    tb.append(tr);
  }
}

/* ---------------- wifi (unifi controller) ---------------- */
function signalClass(dbm) { return dbm >= -65 ? "temp-good" : dbm >= -75 ? "temp-warning" : "temp-serious"; }
function utilClass(pct) { return pct >= 70 ? " crit" : pct >= 40 ? " warn" : ""; }
let lastWifi = null;
function renderWifi(d) {
  lastWifi = d;
  renderTopo();   // USW temp rides on its topology node
  const aps = $("aps");
  aps.textContent = "";
  for (const ap of d.aps || []) {
    const box = el("div", "ap");
    const name = el("div", "ap-name", ap.name + " ");
    name.append(el("small", "", `${ap.model} · up ${fmtUptime(ap.uptime)}`));
    box.append(name);
    for (const r of ap.radios || []) {
      const row = el("div", "radio-row");
      const meter = el("div", "meter slim");
      const fill = el("div", "meter-fill fill-down" + utilClass(r.util));
      fill.style.width = Math.min(100, r.util) + "%";
      meter.append(fill);
      row.append(
        el("span", "lbl", `${r.band} GHz · ch ${r.ch}`),
        meter,
        el("span", "pct", r.util + "%"),
        el("span", "sta", r.sta + " dev")
      );
      box.append(row);
    }
    aps.append(box);
  }
  if (d.sw) $("poe").textContent =
    `${d.sw.name}: ${d.sw.poe_w.toFixed(1)} W of PoE feeding ${d.sw.poe_ports} device${d.sw.poe_ports === 1 ? "" : "s"} (the APs)`;
  $("wifi-counts").textContent = `${d.counts.wireless} devices`;

  const box = $("wifi-clients");
  box.textContent = "";
  if (!(d.clients || []).length) { box.append(el("p", "empty", "nobody on Wi-Fi")); return; }
  for (const c of d.clients) {
    const row = el("div", "wc-row");
    const name = el("div", "wc-name", c.name || c.ip);
    if (c.name) name.append(el("small", "", c.ip));
    const sig = el("div", "wc-signal " + signalClass(c.signal), c.signal + " dBm");
    const chips = el("span", "wc-chips");
    chips.append(el("span", "chip", c.ssid), el("span", "chip", c.band + " GHz"),
                 el("span", "chip chip-ap", c.ap));
    row.append(name, chips, el("div", "wc-rate", c.mbps + " Mbit"), sig);
    box.append(row);
  }
}

/* ---------------- topology ---------------- */
let lastTopo = null;
const KIND_ICON = { core: "🕸", unifi: "🔀", switch: "🔀", ap: "📶", direct: "" };
function devChip(d) {
  const chip = el("span", "dev", d.name || d.ip || d.mac);
  chip.title = [d.ip, d.mac].filter(Boolean).join(" · ");
  return chip;
}
function topoNode(n) {
  const box = el("div", "topo-node");
  const head = el("div", "topo-head");
  if (n.label) head.append(el("span", "chip", n.label));
  const icon = KIND_ICON[n.kind] || "";
  if (n.name) head.append(el("b", "", `${icon} ${n.name}`.trim()));
  const ndev = (n.devices || []).length;
  if (n.kind === "ap") head.append(el("small", "", ` ${n.count || 0} client${n.count === 1 ? "" : "s"}`));
  else if (ndev > 1) head.append(el("small", "", ` ${ndev} devices`));
  const mt = lastGear?.mikrotik;
  if (n.kind === "core" && mt)
    head.append(el("small", "", `CPU ${mt.cpu_c}°C` +
      mt.sfp.map((s) => ` · SFP+${s.port} ${s.c}°C`).join("")));
  const sw = lastWifi?.sw;
  if (n.kind === "unifi" && sw?.temp_c != null)
    head.append(el("small", "", `${sw.temp_c}°C` + (sw.fan != null ? ` · fan ${sw.fan}%` : "")));
  if (n.note) head.append(el("small", "", n.note));
  box.append(head);
  if (ndev) {
    const devs = el("div", "topo-devs");
    for (const d of n.devices) devs.append(devChip(d));
    box.append(devs);
  }
  if ((n.children || []).length) {
    const kids = el("div", "topo-children");
    for (const c of n.children) kids.append(topoNode(c));
    box.append(kids);
  }
  return box;
}
function renderTopo(d) {
  if (d) lastTopo = d;
  if (!lastTopo) return;
  const box = $("topo");
  box.textContent = "";
  const root = el("div", "topo-node");
  root.append(el("div", "topo-head-root", "⚡ " + lastTopo.tree.name));
  const kids = el("div", "topo-children");
  for (const c of lastTopo.tree.children || []) kids.append(topoNode(c));
  root.append(kids);
  box.append(root);
}

/* ---------------- cache ---------------- */
function renderCache(d) {
  if (d.cache) {
    const c = d.cache;
    $("cache-used").textContent =
      `${fmtBytes(c.usedCacheSize)} of ${fmtBytes(c.totalCacheSize)} (${c.usagePercent.toFixed(0)}%) — full is fine, old games make room`;
    $("cache-bar").style.width = c.usagePercent.toFixed(0) + "%";
  }
  const box = $("downloads");
  box.textContent = "";
  // API rows are per-session; one game download shows up as many rows.
  // Group per game+client+service (the manager's own UI does the same).
  const groups = new Map();
  for (const dl of d.downloads || []) {
    const key = `${dl.service}|${dl.clientIp}|${dl.gameName || ""}`;
    const g = groups.get(key);
    if (!g) {
      groups.set(key, {
        game: dl.gameName || dl.service, service: dl.service, client: dl.clientIp,
        hit: dl.cacheHitBytes || 0, miss: dl.cacheMissBytes || 0, active: !!dl.isActive,
      });
    } else {
      g.hit += dl.cacheHitBytes || 0;
      g.miss += dl.cacheMissBytes || 0;
      g.active = g.active || !!dl.isActive;
    }
  }
  const dls = [...groups.values()]
    .filter((g) => g.active || g.hit + g.miss >= 1e6)  // hide 0-byte metadata noise
    .slice(0, 10);
  if (!dls.length) { box.append(el("p", "empty", "no downloads seen yet")); return; }
  for (const dl of dls) {
    const total = dl.hit + dl.miss;
    const row = el("div", "dl-row");
    const game = el("div", "dl-game");
    if (dl.active) game.append(el("span", "dl-live"));
    game.append(dl.game);
    row.append(
      game,
      el("div", "dl-size", fmtBytes(total)),
      el("div", "dl-meta", `${dl.service} · ${dl.client}`),
      el("div", "dl-hit", (total ? (100 * dl.hit) / total : 0).toFixed(0) + "% from cache")
    );
    box.append(row);
  }
}

/* ---------------- polling ---------------- */
function poll(url, render, interval) {
  let timer = null;
  const tick = async () => {
    try {
      render(await getJSON(url));
      lastOk = Date.now();
    } catch (e) { /* keep last view; stale badge handles visibility */ }
    timer = setTimeout(tick, interval);
  };
  const stop = () => { clearTimeout(timer); timer = null; };
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stop();
    else if (!timer) tick();
  });
  tick();
}

setInterval(() => { $("stale").hidden = Date.now() - lastOk < 15000; }, 5000);

/* copy buttons — page is plain http, so navigator.clipboard (secure-context
   only) usually isn't there; fall back to the old execCommand path */
document.addEventListener("click", (ev) => {
  const btn = ev.target.closest(".copy-btn");
  if (!btn) return;
  ev.preventDefault();
  ev.stopPropagation();          // cards are links — don't launch mumble://
  const text = btn.dataset.copy;
  const done = (ok) => {
    if (!ok) {
      // no clipboard access — select the address so one keystroke finishes it
      const code = btn.parentElement.querySelector("code");
      if (code) {
        const range = document.createRange();
        range.selectNodeContents(code);
        const sel = getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      }
    }
    btn.textContent = ok ? "✓" : "⌘C";
    btn.classList.toggle("copied", ok);
    setTimeout(() => { btn.textContent = "⧉"; btn.classList.remove("copied"); }, 2500);
  };
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(() => done(true), () => done(false));
  } else {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.append(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { /* ok stays false */ }
    ta.remove();
    done(ok);
  }
});

/* site.json: passwords / addresses shown on the cards. Gitignored — lives
   only on the router, so the repo carries no secrets. Fetched once. */
getJSON("site.json").then((s) => {
  $("mumble-server").textContent = s.mumble_server || "—";
  $("mumble-pass").textContent = s.mumble_password || "—";
  $("mumble-remote").textContent = s.mumble_remote || "—";
  document.querySelector(".copy-btn").dataset.copy = s.mumble_remote || "";
  $("wifi-ssids").textContent = s.wifi_ssids || "—";
  $("wifi-pass").textContent = s.wifi_password || "—";
  $("router-ip").textContent = s.router_ip || "—";
}).catch(() => { /* page still works without site.json */ });

poll("data/ping.json", renderPing, PING_MS);
poll("data/net.json", renderNet, NET_MS);
poll("data/sys.json", renderSys, SYS_MS);
poll("data/cache.json", renderCache, CACHE_MS);
poll("data/wifi.json", renderWifi, CACHE_MS);
poll("data/gear.json", renderGear, CACHE_MS);
poll("data/topo.json", renderTopo, CACHE_MS);
