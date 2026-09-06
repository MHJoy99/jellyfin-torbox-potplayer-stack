"use strict";
/* OPSO pack: 10 additive ops wins. IIFE, no deps, guarded, dark vars.
 * Reads real endpoints only: GET /api/status, /api/health, /api/config,
 * /api/activity, /api/timeline, /api/metrics, POST /api/action, POST /api/restart.
 * Creates one section #opso-panel. Touches no existing files. No wiring. */
(function () {
  if (typeof document === "undefined" || typeof window === "undefined") return;
  if (window.__opsoLoaded) return;
  window.__opsoLoaded = true;

  var STATUS_URL = "/api/status";
  var HEALTH_URL = "/api/health";
  var CONFIG_URL = "/api/config";
  var ACTIVITY_URL = "/api/activity";
  var RESTART_URL = "/api/restart";
  var ACTION_URL = "/api/action";
  var LS_AUDIT = "opso.audit.v1";
  var LS_MAINT = "opso.maint.v1";
  var LS_SAFE = "opso.safemode.v1";
  var AUDIT_CAP = 200;

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c];
    });
  }
  function toast(msg, kind) {
    try {
      var t = document.getElementById("toast");
      if (!t) return;
      t.textContent = String(msg);
      t.className = "toast toast-" + (kind || "info") + " show";
      clearTimeout(toast._t);
      toast._t = setTimeout(function () { t.classList.remove("show"); }, 5200);
    } catch (_) {}
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
  function getJSON(url, ms) {
    var ctrl = null, timer = null;
    try {
      if (typeof AbortController !== "undefined") {
        ctrl = new AbortController();
        timer = setTimeout(function () { try { ctrl.abort(); } catch (_) {} }, ms || 15000);
      }
    } catch (_) { ctrl = null; }
    var opts = ctrl ? { signal: ctrl.signal, credentials: "same-origin" } : { credentials: "same-origin" };
    return fetch(url, opts).then(function (r) {
      if (timer) clearTimeout(timer);
      if (!r.ok) throw new Error("HTTP " + r.status + " for " + url);
      return r.json();
    }, function (e) { if (timer) clearTimeout(timer); throw e; });
  }
  function postJSON(url, body) {
    return fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin",
      body: JSON.stringify(body || {})
    }).then(function (r) { return r.json().then(function (j) { return { http: r.status, body: j }; }); });
  }
  function download(name, text) {
    try {
      var blob = new Blob([text], { type: "application/json" });
      var a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = name;
      document.body.appendChild(a);
      a.click();
      setTimeout(function () { try { URL.revokeObjectURL(a.href); a.remove(); } catch (_) {} }, 800);
    } catch (e) { toast("Download failed: " + e.message, "error"); }
  }
  function fmtDur(s) {
    s = Math.max(0, Math.floor(Number(s) || 0));
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    if (d > 0) return d + "d " + h + "h";
    if (h > 0) return h + "h " + m + "m";
    if (m > 0) return m + "m " + (s % 60) + "s";
    return s + "s";
  }
  function svcUptime(sv) {
    if (!sv || typeof sv !== "object") return 0;
    var c = ["uptime_seconds", "uptime_s", "uptime", "uptimeSec"];
    for (var i = 0; i < c.length; i++) {
      var v = sv[c[i]];
      if (typeof v === "number" && isFinite(v)) return v;
    }
    return 0;
  }
  function svcState(sv) {
    if (!sv) return "unknown";
    if (typeof sv === "string") return sv;
    return String(sv.state || sv.status || sv.health || "unknown").toLowerCase();
  }

  function ensureStyles() {
    if (document.getElementById("opso-pack-styles")) return;
    var st = document.createElement("style");
    st.id = "opso-pack-styles";
    st.textContent = [
      ":root{--opso-bg:#0c1322;--opso-card:#101b30;--opso-line:#243650;--opso-text:#dbe6f5;--opso-muted:#8fa1bd;--opso-ok:#7dd88a;--opso-warn:#f0b35c;--opso-bad:#f06a6a;--opso-acc:#4f8cff;}",
      "#opso-panel{max-width:1180px;margin:14px auto 0;padding:0 12px;}",
      "#opso-panel .opso-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px;}",
      "#opso-panel .opso-card{background:var(--opso-card);border:1px solid var(--opso-line);border-radius:10px;padding:10px 12px;color:var(--opso-text);font-size:12.5px;}",
      "#opso-panel .opso-card h3{margin:0 0 6px;font-size:13px;}",
      "#opso-panel .opso-card p{margin:0 0 8px;color:var(--opso-muted);}",
      "#opso-panel .opso-row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;}",
      "#opso-panel .opso-btn{background:#16263f;border:1px solid var(--opso-line);color:var(--opso-text);border-radius:8px;padding:6px 10px;cursor:pointer;font-size:12.5px;}",
      "#opso-panel .opso-btn:disabled{opacity:.45;cursor:not-allowed;}",
      "#opso-panel .opso-input{background:#0b1425;border:1px solid var(--opso-line);color:var(--opso-text);border-radius:8px;padding:6px 8px;font-size:12.5px;}",
      "#opso-panel .opso-list{list-style:none;margin:8px 0 0;padding:0;max-height:160px;overflow:auto;font-size:12px;}",
      "#opso-panel .opso-list li{padding:3px 0;border-top:1px solid var(--opso-line);}",
      "#opso-panel canvas.opso-spark{width:100%;height:64px;background:#0b1425;border:1px solid var(--opso-line);border-radius:8px;}",
      "#opso-confirm-ov{display:none;position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;align-items:center;justify-content:center;padding:16px;}",
      "#opso-confirm-ov.is-open{display:flex;}",
      "#opso-confirm-ov .opso-modal{background:var(--opso-card);border:1px solid var(--opso-bad);border-radius:12px;padding:16px;max-width:420px;width:100%;color:var(--opso-text);}",
      "body.opso-safe-mode button[data-action],body.opso-safe-mode .opso-needs-write{display:none !important;}"
    ].join("\n");
    document.head.appendChild(st);
  }

  function auditRead() { var a = lsJson(LS_AUDIT, []); return Array.isArray(a) ? a : []; }
  function auditAdd(entry) {
    try {
      var log = auditRead();
      log.push(Object.assign({ t: new Date().toISOString(), who: "panel-local" }, entry || {}));
      while (log.length > AUDIT_CAP) log.shift();
      lsSet(LS_AUDIT, JSON.stringify(log));
      renderAudit();
    } catch (_) {}
  }
  function renderAudit() {
    var box = document.getElementById("opso-audit-list");
    if (!box) return;
    var log = auditRead().slice().reverse().slice(0, 60);
    box.innerHTML = log.length
      ? log.map(function (e) {
          return "<li><code>" + esc(e.t) + "</code> " + esc(e.action || e.kind || "event")
            + " <code>" + esc(e.service || "-") + "</code> " + esc(e.result || e.note || "") + "</li>";
        }).join("")
      : "<li>No audited actions yet this browser.</li>";
  }

  // OPSO-001 bulk restart unhealthy only (derives unhealthy set from /api/health, fallback /api/status).
  function restartUnhealthy() {
    var out = document.getElementById("opso-unhealthy-out");
    if (out) out.textContent = "Checking /api/health…";
    function pickUnhealthy(health, status) {
      var bad = [];
      try {
        var map = (health && (health.services || health.checks || health.components)) || null;
        if (map && typeof map === "object") {
          Object.keys(map).forEach(function (k) {
            var st = svcState(map[k]);
            if (st !== "healthy" && st !== "ok" && st !== "up") bad.push(k);
          });
        }
        if (!bad.length && status && status.services && typeof status.services === "object") {
          Object.keys(status.services).forEach(function (k) {
            var st = svcState(status.services[k]);
            if (st !== "healthy" && st !== "ok" && st !== "up" && st !== "running") bad.push(k);
          });
        }
      } catch (_) {}
      return bad.filter(function (v, i, a) { return a.indexOf(v) === i; });
    }
    Promise.all([
      getJSON(HEALTH_URL, 15000).catch(function () { return null; }),
      getJSON(STATUS_URL, 15000).catch(function () { return null; })
    ]).then(function (pair) {
      var bad = pickUnhealthy(pair[0], pair[1]);
      if (!bad.length) {
        if (out) out.textContent = "All services healthy — nothing to restart.";
        toast("All services healthy — nothing to restart", "info");
        return;
      }
      if (out) out.textContent = "Restarting unhealthy: " + bad.join(", ") + "…";
      if (!window.confirm("Restart unhealthy only (" + bad.join(", ") + ")?")) {
        if (out) out.textContent = "Cancelled.";
        return;
      }
      var chain = Promise.resolve(0);
      bad.forEach(function (svc) {
        chain = chain.then(function (n) {
          return postJSON(RESTART_URL, { service: svc }).then(function (res) {
            var ok = res && (res.body && (res.body.ok === true || res.body.success === true));
            if (!ok) {
              return postJSON(ACTION_URL, { action: "restart", service: svc }).then(function (r2) {
                var ok2 = r2 && (r2.body && (r2.body.ok === true || r2.body.success === true));
                auditAdd({ action: "restart-unhealthy", service: svc, result: ok2 ? "ok" : "fail", via: "/api/action" });
                return n + (ok2 ? 1 : 0);
              });
            }
            auditAdd({ action: "restart-unhealthy", service: svc, result: "ok", via: "/api/restart" });
            return n + 1;
          }).catch(function (e) {
            auditAdd({ action: "restart-unhealthy", service: svc, result: "error: " + String(e.message || e) });
            return n;
          });
        });
      });
      chain.then(function (n) {
        if (out) out.textContent = "Restarted " + n + "/" + bad.length + " unhealthy: " + bad.join(", ");
        toast("Restarted " + n + "/" + bad.length + " unhealthy", n === bad.length ? "info" : "error");
      });
    }).catch(function (e) {
      if (out) out.textContent = "Check failed: " + String(e.message || e);
    });
  }

  // OPSO-002 confirm-modal with type-to-confirm for stop-all (intercepts stop/all clicks).
  function ensureStopConfirm() {
    if (document.getElementById("opso-confirm-ov")) return;
    var ov = document.createElement("div");
    ov.id = "opso-confirm-ov";
    ov.innerHTML = '<div class="opso-modal" role="dialog" aria-modal="true" aria-labelledby="opso-confirm-t">'
      + '<h3 id="opso-confirm-t">Stop ALL services?</h3>'
      + '<p>Type <code>STOP</code> to enable confirmation. This halts services until you start them again.</p>'
      + '<div class="opso-row"><input class="opso-input" id="opso-confirm-input" type="text" autocomplete="off" placeholder="Type STOP" aria-label="Type STOP to confirm">'
      + '<button class="opso-btn" id="opso-confirm-no" type="button">Cancel</button>'
      + '<button class="opso-btn" id="opso-confirm-yes" type="button" disabled>Confirm stop-all</button></div></div>';
    document.body.appendChild(ov);
    var input = ov.querySelector("#opso-confirm-input");
    var yes = ov.querySelector("#opso-confirm-yes");
    var no = ov.querySelector("#opso-confirm-no");
    var pending = null;
    function close() {
      pending = null;
      ov.classList.remove("is-open");
      try { if (input) input.value = ""; if (yes) yes.disabled = true; } catch (_) {}
    }
    input.addEventListener("input", function () { yes.disabled = (input.value !== "STOP"); });
    no.addEventListener("click", close);
    ov.addEventListener("click", function (e) { if (e.target === ov) close(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && ov.classList.contains("is-open")) close(); });
    yes.addEventListener("click", function () {
      if (!pending) { close(); return; }
      var el = pending; pending = null; close();
      auditAdd({ action: "stop", service: "all", result: "confirmed-type-STOP" });
      try { el.click(); } catch (_) {}
    });
    document.addEventListener("click", function (e) {
      var b = e.target && e.target.closest ? e.target.closest("button[data-action='stop'][data-service='all']") : null;
      if (!b || !ov) return;
      if (ov.classList.contains("is-open")) return;
      e.preventDefault();
      e.stopPropagation();
      pending = b;
      try { input.value = ""; yes.disabled = true; } catch (_) {}
      ov.classList.add("is-open");
      try { input.focus(); } catch (_) {}
    }, true);
  }

  // OPSO-004 config snapshot download (GET /api/config + local prefs, client-side file).
  function snapshotConfig() {
    getJSON(CONFIG_URL, 15000).then(function (cfg) {
      var prefs = {};
      ["opso.maint.v1", "opso.safemode.v1", "opso.audit.v1",
       "jellyfin.panel.activity.sourceFilter", "jellyfin.panel.activity.errorsOnly",
       "jellyfin.panel.ui.density"].forEach(function (k) {
        try { var v = localStorage.getItem(k); if (v !== null) prefs[k] = v; } catch (_) {}
      });
      download("opso-config-snapshot-" + new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-") + ".json",
        JSON.stringify({ exported_at: new Date().toISOString(), config: cfg, prefs: prefs }, null, 2));
      auditAdd({ action: "config-snapshot", service: "-", result: "downloaded" });
      toast("Config snapshot downloaded (GET /api/config)", "info");
    }).catch(function (e) { toast("Snapshot failed: " + e.message, "error"); });
  }

  // OPSO-005 restore prefs from file (localStorage only; config API is read-only, no POST).
  function restorePrefs(file) {
    var rd = new FileReader();
    rd.onload = function () {
      try {
        var j = JSON.parse(String(rd.result || "{}"));
        var prefs = (j && j.prefs) || (j && j.config ? {} : j) || {};
        var keys = Object.keys(prefs);
        if (!keys.length) { toast("No prefs found in file", "error"); return; }
        keys.forEach(function (k) {
          try { localStorage.setItem(k, typeof prefs[k] === "string" ? prefs[k] : JSON.stringify(prefs[k])); } catch (_) {}
        });
        applySafeMode();
        renderMaint();
        renderAudit();
        auditAdd({ action: "restore-prefs", service: "-", result: "ok:" + keys.length + " keys" });
        toast("Restored " + keys.length + " pref key(s) locally (no POST attempted)", "info");
      } catch (e) { toast("Restore failed: " + e.message, "error"); }
    };
    rd.readAsText(file);
  }

  // OPSO-006 webhook test button (client-only ping display; no network write).
  function webhookPing() {
    var box = document.getElementById("opso-webhook-out");
    var t0 = Date.now();
    var stamp = new Date().toISOString();
    if (box) {
      box.innerHTML = "ping (client-only) <code>" + esc(stamp) + "</code> · "
        + (Date.now() - t0) + "ms render · no request sent · configure webhooks server-side";
    }
    auditAdd({ action: "webhook-ping", service: "-", result: "client-only display" });
  }

  // OPSO-007 uptime leaderboard (sorted by /api/status uptime fields).
  function refreshLeaderboard() {
    var box = document.getElementById("opso-leader-list");
    if (box) box.innerHTML = "<li>Loading GET /api/status…</li>";
    getJSON(STATUS_URL, 15000).then(function (st) {
      var rows = [];
      try {
        var svcs = (st && st.services) || {};
        Object.keys(svcs).forEach(function (k) {
          rows.push({ name: k, up: svcUptime(svcs[k]), state: svcState(svcs[k]) });
        });
      } catch (_) {}
      rows.sort(function (a, b) { return b.up - a.up; });
      if (!box) return;
      box.innerHTML = rows.length
        ? rows.map(function (r, i) {
            return "<li>#" + (i + 1) + " <code>" + esc(r.name) + "</code> — " + esc(fmtDur(r.up)) + " (" + esc(r.state) + ")</li>";
          }).join("")
        : "<li>No service uptime fields in /api/status.</li>";
    }).catch(function (e) {
      if (box) box.innerHTML = "<li>Load failed: " + esc(e.message || e) + "</li>";
    });
  }

  // OPSO-008 error-rate sparkline from activity (buckets GET /api/activity entries).
  function refreshSparkline() {
    var cv = document.getElementById("opso-spark");
    var label = document.getElementById("opso-spark-label");
    getJSON(ACTIVITY_URL, 15000).then(function (j) {
      var items = [];
      try {
        if (Array.isArray(j)) items = j;
        else if (j && Array.isArray(j.items)) items = j.items;
        else if (j && Array.isArray(j.events)) items = j.events;
        else if (j && Array.isArray(j.activity)) items = j.activity;
      } catch (_) { items = []; }
      var N = 24, buckets = [];
      for (var i = 0; i < N; i++) buckets.push({ tot: 0, err: 0 });
      items.slice(-600).forEach(function (it, idx) {
        var b = Math.floor((idx / Math.max(1, Math.min(600, items.length))) * N);
        if (b < 0) b = 0; if (b >= N) b = N - 1;
        buckets[b].tot++;
        var s = "";
        try { s = JSON.stringify(it).toLowerCase(); } catch (_) { s = String(it).toLowerCase(); }
        if (s.indexOf("error") >= 0 || s.indexOf("fail") >= 0 || s.indexOf("crit") >= 0) buckets[b].err++;
      });
      var rates = buckets.map(function (b) { return b.tot ? b.err / b.tot : 0; });
      var avg = rates.reduce(function (a, v) { return a + v; }, 0) / Math.max(1, rates.length);
      if (label) label.textContent = "error-rate avg " + Math.round(avg * 100) + "% over " + items.length + " entries (GET /api/activity)";
      if (!cv) return;
      try {
        var ctx = cv.getContext("2d");
        var W = cv.width = 260, H = cv.height = 64;
        ctx.clearRect(0, 0, W, H);
        var bw = W / N;
        for (var k = 0; k < N; k++) {
          var h = Math.round(rates[k] * (H - 8));
          ctx.fillStyle = rates[k] >= 0.5 ? "#f06a6a" : rates[k] >= 0.2 ? "#f0b35c" : "#7dd88a";
          ctx.fillRect(k * bw + 1, H - 4 - h, bw - 2, Math.max(1, h));
        }
      } catch (_) {}
    }).catch(function (e) {
      if (label) label.textContent = "sparkline failed: " + String(e.message || e);
    });
  }

  // OPSO-009 maintenance window scheduler UI (localStorage only, banner when active).
  function maintRead() { return lsJson(LS_MAINT, null); }
  function renderMaint() {
    var box = document.getElementById("opso-maint-out");
    var banner = document.getElementById("opso-maint-banner");
    var m = maintRead();
    var active = false;
    try {
      if (m && m.start && m.end) {
        var now = Date.now(), s = Date.parse(m.start), e = Date.parse(m.end);
        active = isFinite(s) && isFinite(e) && now >= s && now <= e;
      }
    } catch (_) { active = false; }
    if (box) box.textContent = m && m.start ? ("Window: " + m.start + " → " + m.end + (m.note ? " · " + m.note : "")) : "No window scheduled.";
    if (banner) {
      banner.style.display = active ? "block" : "none";
      if (active) banner.textContent = "Maintenance window active until " + (m.end || "?") + (m.note ? " — " + m.note : "");
    }
  }
  function saveMaint() {
    var s = document.getElementById("opso-maint-start");
    var e = document.getElementById("opso-maint-end");
    var n = document.getElementById("opso-maint-note");
    var m = { start: s && s.value ? s.value : "", end: e && e.value ? e.value : "", note: n && n.value ? n.value : "" };
    if (!m.start || !m.end) { toast("Set both start and end", "error"); return; }
    lsSet(LS_MAINT, JSON.stringify(m));
    renderMaint();
    auditAdd({ action: "maint-save", service: "-", result: m.start + "->" + m.end });
    toast("Maintenance window saved locally", "info");
  }
  function clearMaint() {
    try { localStorage.removeItem(LS_MAINT); } catch (_) {}
    renderMaint();
    toast("Maintenance window cleared", "info");
  }

  // OPSO-010 read-only safe-mode toggle (hides action buttons via body class).
  function applySafeMode() {
    var on = lsGet(LS_SAFE, "0") === "1";
    try { document.body.classList.toggle("opso-safe-mode", !!on); } catch (_) {}
    var t = document.getElementById("opso-safe-toggle");
    if (t) t.checked = !!on;
    var note = document.getElementById("opso-safe-note");
    if (note) note.textContent = on ? "Safe-mode ON: action buttons hidden (read-only)." : "Safe-mode OFF.";
  }

  // OPSO-003 action audit trail view (local ring buffer + capture of [data-action] clicks).
  function ensureAuditCapture() {
    document.addEventListener("click", function (e) {
      var b = e.target && e.target.closest ? e.target.closest("button[data-action]") : null;
      if (!b) return;
      auditAdd({ action: b.getAttribute("data-action"), service: b.getAttribute("data-service") || "?", result: "clicked" });
    }, true);
  }

  function buildPanel() {
    if (document.getElementById("opso-panel")) return;
    ensureStyles();
    var host = document.querySelector("main.shell") || document.body;
    var sec = document.createElement("section");
    sec.id = "opso-panel";
    sec.setAttribute("aria-label", "Ops wins");
    sec.innerHTML =
      '<div class="pane-heading"><h2>Ops wins</h2><span class="pane-hint">Additive · existing endpoints only</span></div>'
      + '<div id="opso-maint-banner" style="display:none;background:#3a2a10;color:#ffd9a0;border:1px solid var(--opso-warn);border-radius:8px;padding:8px 12px;margin-bottom:10px;font-size:12.5px;"></div>'
      + '<div class="opso-grid">'
      + '<div class="opso-card"><h3>Bulk restart unhealthy</h3><p>From <code>/api/health</code> + <code>/api/status</code>.</p><div class="opso-row"><button class="opso-btn opso-needs-write" id="opso-restart-bad" type="button">Restart unhealthy only</button></div><div id="opso-unhealthy-out"></div></div>'
      + '<div class="opso-card"><h3>Type-to-confirm stop-all</h3><p>Intercepts <code>stop/all</code>; type STOP.</p><div class="opso-row"><span>Armed automatically.</span></div></div>'
      + '<div class="opso-card"><h3>Audit trail</h3><p>Local ring buffer of actions.</p><div class="opso-row"><button class="opso-btn" id="opso-audit-clear" type="button">Clear audit</button></div><ul class="opso-list" id="opso-audit-list"></ul></div>'
      + '<div class="opso-card"><h3>Config snapshot</h3><p>Download <code>/api/config</code> + prefs.</p><div class="opso-row"><button class="opso-btn" id="opso-snap" type="button">Download snapshot</button></div></div>'
      + '<div class="opso-card"><h3>Restore prefs</h3><p>File → localStorage (read-only API).</p><div class="opso-row"><label class="opso-btn">Choose file <input type="file" id="opso-restore" accept="application/json" hidden></label></div></div>'
      + '<div class="opso-card"><h3>Webhook test</h3><p>Client-only ping display.</p><div class="opso-row"><button class="opso-btn" id="opso-webhook" type="button">Send test ping</button></div><div id="opso-webhook-out"></div></div>'
      + '<div class="opso-card"><h3>Uptime leaderboard</h3><p>Sorted by <code>/api/status</code>.</p><div class="opso-row"><button class="opso-btn" id="opso-leader-btn" type="button">Refresh</button></div><ul class="opso-list" id="opso-leader-list"></ul></div>'
      + '<div class="opso-card"><h3>Error-rate sparkline</h3><p id="opso-spark-label">From <code>/api/activity</code>.</p><canvas class="opso-spark" id="opso-spark" width="260" height="64"></canvas><div class="opso-row"><button class="opso-btn" id="opso-spark-btn" type="button">Refresh</button></div></div>'
      + '<div class="opso-card"><h3>Maintenance window</h3><p>Local schedule + banner.</p><div class="opso-row"><input class="opso-input" id="opso-maint-start" type="datetime-local" aria-label="Window start"><input class="opso-input" id="opso-maint-end" type="datetime-local" aria-label="Window end"></div><div class="opso-row" style="margin-top:6px"><input class="opso-input" id="opso-maint-note" type="text" placeholder="Note (optional)" style="flex:1;min-width:120px"><button class="opso-btn" id="opso-maint-save" type="button">Save</button><button class="opso-btn" id="opso-maint-clear" type="button">Clear</button></div><div id="opso-maint-out"></div></div>'
      + '<div class="opso-card"><h3>Safe mode</h3><p>Read-only: hides action buttons.</p><div class="opso-row"><label><input type="checkbox" id="opso-safe-toggle"> Hide action buttons</label></div><div id="opso-safe-note"></div></div>'
      + "</div>";
    host.appendChild(sec);
    document.getElementById("opso-restart-bad").addEventListener("click", restartUnhealthy);
    document.getElementById("opso-snap").addEventListener("click", snapshotConfig);
    document.getElementById("opso-restore").addEventListener("change", function (e) {
      if (e.target.files && e.target.files[0]) restorePrefs(e.target.files[0]);
    });
    document.getElementById("opso-webhook").addEventListener("click", webhookPing);
    document.getElementById("opso-leader-btn").addEventListener("click", refreshLeaderboard);
    document.getElementById("opso-spark-btn").addEventListener("click", refreshSparkline);
    document.getElementById("opso-maint-save").addEventListener("click", saveMaint);
    document.getElementById("opso-maint-clear").addEventListener("click", clearMaint);
    document.getElementById("opso-safe-toggle").addEventListener("change", function (e) {
      lsSet(LS_SAFE, e.target.checked ? "1" : "0");
      applySafeMode();
    });
    document.getElementById("opso-audit-clear").addEventListener("click", function () {
      try { localStorage.removeItem(LS_AUDIT); } catch (_) {}
      renderAudit();
    });
    var m = maintRead();
    try {
      if (m) {
        if (m.start && document.getElementById("opso-maint-start")) document.getElementById("opso-maint-start").value = m.start;
        if (m.end && document.getElementById("opso-maint-end")) document.getElementById("opso-maint-end").value = m.end;
        if (m.note && document.getElementById("opso-maint-note")) document.getElementById("opso-maint-note").value = m.note;
      }
    } catch (_) {}
    applySafeMode();
    renderMaint();
    renderAudit();
    refreshLeaderboard();
    refreshSparkline();
  }

  function boot() {
    ensureStyles();
    ensureStopConfirm();
    ensureAuditCapture();
    buildPanel();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
