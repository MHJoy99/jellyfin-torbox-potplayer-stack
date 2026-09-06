"use strict";
/* OPSM pack: 10 additive ops wins. IIFE, no deps, guarded, dark vars.
 * Reads real endpoints: GET /api/status, /api/health, /api/config,
 * POST /api/action, POST /api/restart. Touches no existing files. */
(function () {
  if (typeof document === "undefined" || typeof window === "undefined") return;
  if (window.__OPSM && window.__OPSM.booted) return;
  var booted = { booted: true, v: 1 };
  try { window.__OPSM = booted; } catch (_) { return; }

  var STATUS_URL = "/api/status?light=1";
  var HEALTH_URL = "/api/health";
  var CONFIG_URL = "/api/config";
  var ACTION_URL = "/api/action";
  var POLL_MS = 15000;
  var LS_AUDIT = "opsm.audit.v1";
  var LS_MAINT = "opsm.maint.v1";
  var LS_DRY = "opsm.dryrun.v1";
  var LS_WD = "opsm.watchdog.v1";
  var LS_CFGBAK = "opsm.cfgbackup.v1";
  var AUDIT_CAP = 200;

  function esc(s) {
    return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");
  }
  function lsGet(k, fb) {
    try { var v = localStorage.getItem(k); return v == null ? fb : v; }
    catch (_) { return fb; }
  }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
  function lsJson(k, fb) {
    try { var v = JSON.parse(lsGet(k, "")); return v == null ? fb : v; }
    catch (_) { return fb; }
  }
  function fmtUptime(s) {
    s = Math.max(0, Math.floor(Number(s) || 0));
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600),
        m = Math.floor((s % 3600) / 60), ss = s % 60;
    if (d > 0) return d + "d " + h + "h";
    if (h > 0) return h + "h " + m + "m";
    if (m > 0) return m + "m " + ss + "s";
    return ss + "s";
  }
  function dotFor(state) {
    return state === "healthy" ? "#7dd88a" : state === "warning" || state === "starting" ? "#f0b35c" : "#f06a6a";
  }
  function fetchJson(url, opts, timeoutMs) {
    var ctrl = null, timer = 0;
    try {
      if (typeof AbortController !== "undefined") {
        ctrl = new AbortController();
        timer = setTimeout(function () { try { ctrl.abort(); } catch (_) {} }, timeoutMs || 10000);
      }
      var p = fetch(url, Object.assign({}, opts || {}, ctrl ? { signal: ctrl.signal } : {}))
        .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); });
      return p.finally ? p.finally(function () { if (timer) clearTimeout(timer); }) : p;
    } catch (e) { return Promise.reject(e); }
  }

  // OPSM-004 audit ring buffer + viewer data helpers.
  function auditRead() { return lsJson(LS_AUDIT, []); }
  function auditWrite(entry) {
    try {
      var log = auditRead();
      log.push(Object.assign({ t: new Date().toISOString(), who: "panel-local" }, entry || {}));
      while (log.length > AUDIT_CAP) log.shift();
      lsSet(LS_AUDIT, JSON.stringify(log));
      renderAudit();
    } catch (_) {}
  }

  function css() {
    if (document.getElementById("opsm-styles")) return;
    var st = document.createElement("style");
    st.id = "opsm-styles";
    st.textContent = [
      ":root{--opsm-bg:#0d1420;--opsm-card:#101a2a;--opsm-line:#24344d;--opsm-text:#dbe6f5;--opsm-muted:#8fa1bd;--opsm-ok:#7dd88a;--opsm-warn:#f0b35c;--opsm-bad:#f06a6a;--opsm-acc:#4f8cff;}",
      "#opsm-maintbar{display:none;background:#3a2a10;color:#ffd9a0;border-bottom:1px solid var(--opsm-warn);padding:8px 16px;font-size:13px;text-align:center;}",
      "#opsm-maintbar.is-on{display:block;}",
      "#opsm-sec{margin:18px 0 0;}",
      ".opsm-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;}",
      ".opsm-card{background:var(--opsm-card);border:1px solid var(--opsm-line);border-radius:10px;padding:12px 14px;color:var(--opsm-text);}",
      ".opsm-card h3{margin:0 0 8px;font-size:13px;letter-spacing:.04em;text-transform:uppercase;color:var(--opsm-muted);}",
      ".opsm-card p,.opsm-card li{font-size:12.5px;color:var(--opsm-text);}",
      ".opsm-row{display:flex;align-items:center;gap:8px;flex-wrap:wrap;}",
      ".opsm-dot{width:9px;height:9px;border-radius:50%;display:inline-block;background:var(--opsm-muted);}",
      ".opsm-pidline{font-size:11.5px;color:var(--opsm-muted);margin-top:6px;font-family:ui-monospace,Consolas,monospace;}",
      ".opsm-btn{cursor:pointer;background:#182742;border:1px solid var(--opsm-line);color:var(--opsm-text);border-radius:7px;padding:6px 10px;font-size:12.5px;}",
      ".opsm-btn:hover{border-color:var(--opsm-acc);}",
      ".opsm-btn.is-on{background:#12331f;border-color:var(--opsm-ok);color:var(--opsm-ok);}",
      ".opsm-input{background:#0a1220;border:1px solid var(--opsm-line);color:var(--opsm-text);border-radius:7px;padding:6px 8px;font-size:12.5px;width:100%;box-sizing:border-box;}",
      ".opsm-diff-add{color:var(--opsm-ok);} .opsm-diff-del{color:var(--opsm-bad);} .opsm-diff-ctx{color:var(--opsm-muted);}",
      ".opsm-pre{background:#0a1220;border:1px solid var(--opsm-line);border-radius:8px;padding:8px;max-height:220px;overflow:auto;font-size:11.5px;white-space:pre-wrap;}",
      ".opsm-prog{height:6px;background:#0a1220;border-radius:99px;overflow:hidden;margin-top:8px;}",
      ".opsm-prog>span{display:block;height:100%;width:0;background:var(--opsm-acc);transition:width .3s;}",
    ].join("\n");
    document.head.appendChild(st);
  }

  function mount() {
    var bar = document.createElement("div");
    bar.id = "opsm-maintbar";
    bar.setAttribute("role", "status");
    document.body.insertBefore(bar, document.body.firstChild);
    var sec = document.createElement("section");
    sec.id = "opsm-sec";
    sec.className = "opsm-grid";
    sec.setAttribute("aria-label", "Ops extras");
    var host = document.querySelector("main.shell") || document.querySelector("main") || document.body;
    host.appendChild(sec);
    sec.innerHTML = [
      '<div class="opsm-card" id="opsm-c-graph"><h3>Dependency graph</h3><div id="opsm-graph"></div></div>',
      '<div class="opsm-card" id="opsm-c-portmap"><h3>Port map</h3><div id="opsm-ports"></div></div>',
      '<div class="opsm-card" id="opsm-c-wd"><h3>Watchdog</h3><div class="opsm-row"><button class="opsm-btn" id="opsm-wd-btn" type="button">Pause probes</button><span id="opsm-dry-badge"></span></div><div class="opsm-row" style="margin-top:8px"><button class="opsm-btn" id="opsm-dry-btn" type="button">Dry-run: off</button><button class="opsm-btn" id="opsm-restart-all" type="button">Restart all (ordered)</button></div><div class="opsm-prog" id="opsm-restart-prog" hidden><span></span></div><p id="opsm-restart-msg" style="color:var(--opsm-muted)"></p></div>',
      '<div class="opsm-card" id="opsm-c-maint"><h3>Maintenance window</h3><input class="opsm-input" id="opsm-maint-msg" placeholder="Message, e.g. Library rescan tonight"><div class="opsm-row" style="margin-top:8px"><input class="opsm-input" id="opsm-maint-from" type="datetime-local" style="flex:1"><input class="opsm-input" id="opsm-maint-to" type="datetime-local" style="flex:1"></div><div class="opsm-row" style="margin-top:8px"><button class="opsm-btn" id="opsm-maint-save" type="button">Schedule</button><button class="opsm-btn" id="opsm-maint-clear" type="button">Clear</button></div></div>',
      '<div class="opsm-card" id="opsm-c-env"><h3>Environment</h3><div id="opsm-env"></div></div>',
      '<div class="opsm-card" id="opsm-c-cfg"><h3>Config diff</h3><div class="opsm-row"><button class="opsm-btn" id="opsm-cfg-backup" type="button">Snapshot backup</button><button class="opsm-btn" id="opsm-cfg-diff" type="button">Diff vs live</button></div><div class="opsm-pre" id="opsm-cfg-out">No diff yet.</div></div>',
      '<div class="opsm-card" id="opsm-c-audit"><h3>Action audit</h3><div class="opsm-row"><button class="opsm-btn" id="opsm-audit-clear" type="button">Clear log</button></div><div class="opsm-pre" id="opsm-audit-out">No panel actions recorded yet.</div></div>',
    ].join("");
  }

  // OPSM-001 PID + uptime line per service card, from /api/status fields.
  function renderPidLines(payload) {
    try {
      var svcs = (payload && payload.services) || {};
      Object.keys(svcs).forEach(function (id) {
        var card = document.querySelector('[data-service-id="' + id + '"]');
        if (!card) return;
        var s = svcs[id] || {};
        var bits = [];
        if (Array.isArray(s.pids) && s.pids.length) bits.push("PID " + s.pids.join(","));
        else if (s.process_count > 0) bits.push(s.process_count + " proc");
        if (s.uptime_s != null) bits.push("up " + fmtUptime(s.uptime_s));
        var line = card.querySelector(".opsm-pidline");
        if (!bits.length) { if (line) line.remove(); return; }
        if (!line) {
          line = document.createElement("div");
          line.className = "opsm-pidline";
          card.appendChild(line);
        }
        line.textContent = bits.join(" · ");
      });
    } catch (_) {}
  }

  // OPSM-006 service dependency graph with live dots.
  var DEP_EDGES = [["gdrive", "torboxmount"], ["torboxmount", "proxy"], ["proxy", "bridge"], ["bridge", "jellyfin"], ["jellyfin", "panel"]];
  var DEP_NODES = ["gdrive", "torboxmount", "proxy", "bridge", "jellyfin", "panel"];
  function renderGraph(payload) {
    try {
      var host = document.getElementById("opsm-graph");
      if (!host) return;
      var svcs = (payload && payload.services) || {};
      var x = {}, i;
      DEP_NODES.forEach(function (n, k) { x[n] = 30 + k * 100; });
      var y = 34, svg = '<svg viewBox="0 0 640 68" width="100%" height="68" role="img" aria-label="Service dependency map">';
      DEP_EDGES.forEach(function (e) {
        svg += '<line x1="' + x[e[0]] + '" y1="' + y + '" x2="' + x[e[1]] + '" y2="' + y + '" stroke="#24344d" stroke-width="2"/>';
      });
      DEP_NODES.forEach(function (n) {
        var st = n === "panel" ? "healthy" : String((svcs[n] || {}).state || "stopped");
        svg += '<circle cx="' + x[n] + '" cy="' + y + '" r="7" fill="' + dotFor(st) + '"><title>' + esc(n + ": " + st) + "</title></circle>"
          + '<text x="' + x[n] + '" y="58" fill="#8fa1bd" font-size="10" text-anchor="middle">' + esc(n) + "</text>";
      });
      host.innerHTML = svg + "</svg>";
    } catch (_) {}
  }

  // OPSM-009 port map card from health probes + status fields.
  function renderPorts(payload) {
    try {
      var host = document.getElementById("opsm-ports");
      if (!host) return;
      var svcs = (payload && payload.services) || {};
      var rows = [
        ["TorBox proxy", 8888, (svcs.proxy || {}).state],
        ["Jellyfin", 8096, (svcs.jellyfin || {}).state],
        ["Panel", 18080, payload && payload.panel ? "healthy" : "stopped"],
        ["Bridge", 18099, (svcs.bridge || {}).state],
        ["Rclone RC", 5572, (svcs.torboxmount || {}).rc_ok ? "healthy" : ((svcs.torboxmount || {}).state || "stopped")],
      ];
      host.innerHTML = rows.map(function (r) {
        return '<div class="opsm-row" style="justify-content:space-between;margin:3px 0"><span>' + esc(r[0])
          + ' <span style="color:var(--opsm-muted)">:' + r[1] + "</span></span>"
          + '<span class="opsm-dot" style="background:' + dotFor(r[2]) + '" title="' + esc(String(r[2])) + '"></span></div>';
      }).join("");
    } catch (_) {}
  }

  // OPSM-010 env-check card via existing status fields.
  function renderEnv(payload, cfg) {
    try {
      var host = document.getElementById("opsm-env");
      if (!host) return;
      var svcs = (payload && payload.services) || {};
      var py = (cfg && cfg.versions && cfg.versions.python) || "unknown";
      var rcloneProcs = ["gdrive", "torboxmount"].reduce(function (n, k) { return n + (Number((svcs[k] || {}).process_count) || 0); }, 0);
      var rows = [
        ["python", py !== "unknown" ? "healthy" : "stopped", "v" + py + " (via /api/config)"],
        ["rclone", rcloneProcs > 0 ? "healthy" : "stopped", rcloneProcs > 0 ? rcloneProcs + " mount proc(s) (via /api/status)" : "no mount process (via /api/status)"],
        ["ffmpeg", (svcs.jellyfin || {}).state === "healthy" ? "healthy" : "stopped", "jellyfin " + String((svcs.jellyfin || {}).state || "?") + " (serving implies ffmpeg dir present)"],
      ];
      host.innerHTML = rows.map(function (r) {
        return '<div class="opsm-row" style="justify-content:space-between;margin:3px 0"><span>' + esc(r[0])
          + ' <span style="color:var(--opsm-muted)">' + esc(r[2]) + "</span></span>"
          + '<span class="opsm-dot" style="background:' + dotFor(r[1]) + '"></span></div>';
      }).join("");
    } catch (_) {}
  }

  // OPSM-003 maintenance-mode banner on a localStorage schedule.
  function renderMaint() {
    try {
      var bar = document.getElementById("opsm-maintbar");
      if (!bar) return;
      var m = lsJson(LS_MAINT, null);
      var now = Date.now(), on = false, msg = "";
      if (m && m.message) {
        var from = m.from ? Date.parse(m.from) : NaN, to = m.to ? Date.parse(m.to) : NaN;
        if ((isNaN(from) || now >= from) && (isNaN(to) || now <= to)) { on = true; msg = String(m.message); }
      }
      bar.classList.toggle("is-on", on);
      if (on) bar.textContent = "Maintenance: " + msg;
    } catch (_) {}
  }

  function renderAudit() {
    try {
      var out = document.getElementById("opsm-audit-out");
      if (!out) return;
      var log = auditRead();
      out.textContent = log.length
        ? log.slice(-60).reverse().map(function (e) { return "[" + e.t + "] " + e.who + " " + e.action + " " + (e.service || ""); }).join("\n")
        : "No panel actions recorded yet.";
    } catch (_) {}
  }

  // OPSM-002 watchdog pause/resume toggle (pauses OPSM probes; no backend route exists so this is honestly local).
  function wdPaused() { return lsGet(LS_WD, "0") === "1"; }
  function renderWd() {
    try {
      var b = document.getElementById("opsm-wd-btn");
      if (b) { b.textContent = wdPaused() ? "Resume probes" : "Pause probes"; b.classList.toggle("is-on", wdPaused()); }
    } catch (_) {}
  }

  // OPSM-005 dry-run toggle: appends dry_run where the API accepts extra fields (sync actions); backend ignores it otherwise.
  function dryOn() { return lsGet(LS_DRY, "0") === "1"; }
  function renderDry() {
    try {
      var b = document.getElementById("opsm-dry-btn");
      if (b) { b.textContent = "Dry-run: " + (dryOn() ? "on" : "off"); b.classList.toggle("is-on", dryOn()); }
      var badge = document.getElementById("opsm-dry-badge");
      if (badge) badge.textContent = dryOn() ? "DRY-RUN armed" : "";
    } catch (_) {}
  }
  function maybeDryRun(url, opts) {
    try {
      if (!dryOn() || !opts || !opts.body || String(url).indexOf(ACTION_URL) !== 0) return opts;
      var body = JSON.parse(String(opts.body));
      if (body && body.action === "sync") { body.dry_run = true; opts = Object.assign({}, opts, { body: JSON.stringify(body) }); }
    } catch (_) {}
    return opts;
  }

  // OPSM-007 restart-all-ordered button on the existing ordered route, with confirm + progress.
  function restartAllOrdered() {
    var msg = document.getElementById("opsm-restart-msg");
    var prog = document.getElementById("opsm-restart-prog");
    var bar = prog ? prog.querySelector("span") : null;
    if (!window.confirm("Restart the full stack in dependency order (stop reverse, start gdrive first)?")) return;
    auditWrite({ action: "restart", service: "all" });
    if (prog) prog.hidden = false;
    if (bar) bar.style.width = "15%";
    if (msg) msg.textContent = "Restart requested…";
    fetchJson(ACTION_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ service: "all", action: "restart" }) }, 300000)
      .then(function (d) {
        if (bar) bar.style.width = "70%";
        if (msg) msg.textContent = String((d && d.message) || "Restart accepted — polling for recovery…");
        var n = 0;
        var iv = setInterval(function () {
          n += 1;
          if (bar) bar.style.width = Math.min(95, 70 + n * 5) + "%";
          fetchJson(STATUS_URL, null, 10000).then(function (p) {
            refresh(p);
            var sv = (p && p.services) || {};
            var keys = Object.keys(sv);
            var up = keys.filter(function (k) { return sv[k] && sv[k].state === "healthy"; }).length;
            if ((keys.length && up === keys.length) || n >= 10) {
              clearInterval(iv);
              if (bar) bar.style.width = "100%";
              if (msg) msg.textContent = "Restart pass finished: " + up + "/" + keys.length + " healthy.";
              setTimeout(function () { if (prog) prog.hidden = true; }, 4000);
            }
          }).catch(function () { if (n >= 10) clearInterval(iv); });
        }, 5000);
      })
      .catch(function (e) { if (msg) msg.textContent = "Restart failed: " + (e && e.message || e); if (prog) prog.hidden = true; });
  }

  // OPSM-008 config diff viewer: backup JSON snapshot vs live settings, line diff.
  function cfgLines(o) {
    try { return JSON.stringify(o, null, 2).split("\n"); } catch (_) { return []; }
  }
  function diffLines(a, b) {
    var setA = {}, setB = {}, out = [];
    a.forEach(function (l) { setA[l] = 1; });
    b.forEach(function (l) { setB[l] = 1; });
    b.forEach(function (l) { out.push({ t: setA[l] ? " " : "+", l: l }); });
    a.forEach(function (l) { if (!setB[l]) out.push({ t: "-", l: l }); });
    return out.slice(0, 300);
  }
  function renderCfgDiff(live) {
    try {
      var out = document.getElementById("opsm-cfg-out");
      if (!out) return;
      var bak = lsJson(LS_CFGBAK, null);
      if (!bak) { out.textContent = "No backup snapshot yet — press Snapshot backup first."; return; }
      var d = diffLines(cfgLines(bak), cfgLines(live));
      var changed = d.filter(function (x) { return x.t !== " "; });
      if (!changed.length) { out.textContent = "No differences: live config matches backup."; return; }
      out.innerHTML = d.map(function (x) {
        var cls = x.t === "+" ? "opsm-diff-add" : x.t === "-" ? "opsm-diff-del" : "opsm-diff-ctx";
        return '<span class="' + cls + '">' + esc(x.t + " " + x.l) + "</span>";
      }).join("\n");
    } catch (_) {}
  }

  var lastCfg = null;
  function refresh(payload) {
    renderPidLines(payload);
    renderGraph(payload);
    renderPorts(payload);
    renderEnv(payload, lastCfg);
    renderMaint();
  }
  function poll() {
    if (wdPaused()) return;
    fetchJson(STATUS_URL, null, 10000).then(refresh).catch(function () {});
    fetchJson(CONFIG_URL, null, 8000).then(function (c) { lastCfg = c; }).catch(function () {});
  }

  function wire() {
    try {
      var w = document.getElementById("opsm-wd-btn");
      if (w) w.addEventListener("click", function () { lsSet(LS_WD, wdPaused() ? "0" : "1"); renderWd(); });
      var d = document.getElementById("opsm-dry-btn");
      if (d) d.addEventListener("click", function () { lsSet(LS_DRY, dryOn() ? "0" : "1"); renderDry(); auditWrite({ action: "dryrun", service: dryOn() ? "on" : "off" }); });
      var r = document.getElementById("opsm-restart-all");
      if (r) r.addEventListener("click", restartAllOrdered);
      var ms = document.getElementById("opsm-maint-save");
      if (ms) ms.addEventListener("click", function () {
        var g = function (id) { var el = document.getElementById(id); return el ? el.value : ""; };
        lsSet(LS_MAINT, JSON.stringify({ message: g("opsm-maint-msg"), from: g("opsm-maint-from"), to: g("opsm-maint-to") }));
        renderMaint();
      });
      var mc = document.getElementById("opsm-maint-clear");
      if (mc) mc.addEventListener("click", function () { lsSet(LS_MAINT, JSON.stringify(null)); renderMaint(); });
      var cb = document.getElementById("opsm-cfg-backup");
      if (cb) cb.addEventListener("click", function () {
        fetchJson(CONFIG_URL, null, 8000).then(function (c) { lsSet(LS_CFGBAK, JSON.stringify(c)); lastCfg = c; renderCfgDiff(c); }).catch(function () {});
      });
      var cd = document.getElementById("opsm-cfg-diff");
      if (cd) cd.addEventListener("click", function () {
        fetchJson(CONFIG_URL, null, 8000).then(function (c) { lastCfg = c; renderCfgDiff(c); }).catch(function () {});
      });
      var ac = document.getElementById("opsm-audit-clear");
      if (ac) ac.addEventListener("click", function () { lsSet(LS_AUDIT, JSON.stringify([])); renderAudit(); });
      // OPSM-004 record panel actions via capture listener (never blocks the original click).
      document.addEventListener("click", function (ev) {
        try {
          var b = ev.target && ev.target.closest ? ev.target.closest("button[data-action]") : null;
          if (!b) return;
          auditWrite({ action: String(b.getAttribute("data-action") || ""), service: String(b.getAttribute("data-service") || "") });
        } catch (_) {}
      }, true);
      // OPSM-005 wrap fetch so sync actions carry dry_run when armed (backend ignores unknown fields).
      if (typeof window.fetch === "function" && !window.fetch.__opsmWrapped) {
        var orig = window.fetch.bind(window);
        var wrapped = function (url, opts) { return orig(url, maybeDryRun(url, opts)); };
        try { wrapped.__opsmWrapped = true; } catch (_) {}
        try { window.fetch = wrapped; } catch (_) {}
      }
    } catch (_) {}
  }

  try {
    css();
    mount();
    wire();
    renderWd();
    renderDry();
    renderMaint();
    renderAudit();
    // Prefill maintenance inputs from saved schedule.
    try {
      var m = lsJson(LS_MAINT, null);
      if (m) {
        var set = function (id, v) { var el = document.getElementById(id); if (el && v) el.value = String(v); };
        set("opsm-maint-msg", m.message); set("opsm-maint-from", m.from); set("opsm-maint-to", m.to);
      }
    } catch (_) {}
    poll();
    setInterval(poll, POLL_MS);
  } catch (_) {}
})();
