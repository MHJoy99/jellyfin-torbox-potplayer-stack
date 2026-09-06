/* opsu-pack.js — additive ops-UI wins (IIFE, guarded, no deps, dark vars). */
(function () {
  "use strict";
  if (typeof window === "undefined" || typeof document === "undefined") return;
  if (window.__opsuPackLoaded) return;
  window.__opsuPackLoaded = true;

  var LS_RULES = "opsu.alertRules.v1";
  var LS_DISK = "opsu.diskThresholds.v1";
  var LS_HEALTH = "opsu.healthSamples.v1";
  var DOCK_ID = "opsu-panel";
  var STYLE_ID = "opsu-pack-styles";

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
    } catch (_) { /* noop */ }
  }
  function getJSON(url, timeoutMs) {
    var ctrl = null, timer = null;
    try {
      if (typeof AbortController !== "undefined") {
        ctrl = new AbortController();
        timer = setTimeout(function () { try { ctrl.abort(); } catch (_) {} }, timeoutMs || 15000);
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
  function loadLS(key, fb) {
    try {
      var raw = localStorage.getItem(key);
      if (!raw) return fb;
      return JSON.parse(raw);
    } catch (_) { return fb; }
  }
  function saveLS(key, val) {
    try { localStorage.setItem(key, JSON.stringify(val)); } catch (_) {}
  }
  function download(name, text, mime) {
    try {
      var blob = new Blob([text], { type: mime || "application/json" });
      var a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = name;
      document.body.appendChild(a);
      a.click();
      setTimeout(function () { try { URL.revokeObjectURL(a.href); a.remove(); } catch (_) {} }, 800);
    } catch (e) { toast("Download failed: " + e.message, "error"); }
  }

  function ensureStyles() {
    if (document.getElementById(STYLE_ID)) return;
    var st = document.createElement("style");
    st.id = STYLE_ID;
    st.textContent = [
      "#opsu-banner{display:none;margin:10px auto 0;max-width:1180px;padding:8px 12px;border-radius:10px;border:1px solid rgba(240,179,92,.5);background:rgba(240,179,92,.10);color:var(--text,#e8eef7);font-size:12.5px;}",
      "#opsu-banner.is-show{display:flex;gap:10px;align-items:center;justify-content:space-between;flex-wrap:wrap;}",
      "#opsu-panel{margin:18px auto 0;max-width:1180px;padding:0 16px;}",
      ".opsu-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:12px;}",
      ".opsu-card{background:var(--panel,#0e1522);border:1px solid var(--line,rgba(255,255,255,.08));border-radius:12px;padding:12px;color:var(--text,#e8eef7);}",
      ".opsu-card h3{margin:0 0 4px;font-size:13px;}",
      ".opsu-card p{margin:0 0 8px;font-size:12px;color:var(--muted,#9aa7bd);}",
      ".opsu-row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;}",
      ".opsu-btn{font:inherit;font-size:12px;padding:6px 10px;border-radius:8px;border:1px solid var(--line,rgba(255,255,255,.12));background:var(--accent-soft,rgba(79,140,255,.14));color:var(--text,#e8eef7);cursor:pointer;}",
      ".opsu-btn:hover{border-color:var(--accent-ring,#4f8cff);}",
      ".opsu-btn.danger{background:rgba(240,106,106,.12);}",
      ".opsu-input{font:inherit;font-size:12px;padding:5px 8px;border-radius:8px;border:1px solid var(--line,rgba(255,255,255,.12));background:var(--bg,#070b12);color:var(--text,#e8eef7);}",
      ".opsu-log{max-height:300px;overflow:auto;background:#05080e;border:1px solid var(--line,rgba(255,255,255,.1));border-radius:8px;padding:8px;font:11.5px/1.5 ui-monospace,Consolas,monospace;white-space:pre-wrap;}",
      "#opsu-modal{position:fixed;inset:0;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.6);z-index:60;padding:16px;}",
      "#opsu-modal.is-open{display:flex;}",
      "#opsu-modal .opsu-card{width:min(760px,100%);max-height:86vh;display:flex;flex-direction:column;}",
      ".opsu-restart{margin-left:6px;}",
      "#opsu-disk-badge{display:inline-flex;margin-left:8px;font-size:11px;padding:2px 8px;border-radius:999px;border:1px solid var(--line,rgba(255,255,255,.12));color:var(--muted,#9aa7bd);}",
      "#opsu-disk-badge.is-warn{color:#f0b35c;border-color:rgba(240,179,92,.5);}",
      "canvas.opsu-canvas{width:100%;height:90px;background:#05080e;border:1px solid var(--line,rgba(255,255,255,.1));border-radius:8px;}"
    ].join("\n");
    document.head.appendChild(st);
  }

  // OPSU-001 Per-service quick-restart buttons on service cards (POST /api/restart with confirm).
  function enhanceRestartButtons() {
    try {
      var grid = document.getElementById("services");
      if (!grid) return;
      Array.prototype.forEach.call(grid.querySelectorAll(".service-card[data-service-id]"), function (card) {
        if (card.querySelector("[data-opsu-restart]")) return;
        var id = card.getAttribute("data-service-id");
        if (!id || id === "all") return;
        var bar = card.querySelector(".svc-actions");
        if (!bar) return;
        var b = document.createElement("button");
        b.type = "button";
        b.className = "btn btn-sm btn-secondary opsu-restart";
        b.setAttribute("data-opsu-restart", id);
        b.title = "Quick restart via POST /api/restart";
        b.textContent = "⟳ Restart (ops)";
        b.addEventListener("click", function (ev) {
          ev.preventDefault(); ev.stopPropagation();
          if (!window.confirm("Restart service '" + id + "' now? (POST /api/restart)")) return;
          b.disabled = true;
          postJSON("/api/restart", { service: id }).then(function (res) {
            if (res.body && res.body.ok) toast(res.body.message || ("Restarted " + id), "info");
            else {
              // Fallback: legacy restart path POST /api/action (same allowlist + "all").
              return postJSON("/api/action", { action: "restart", service: id }).then(function (r2) {
                toast(r2.body && (r2.body.message || r2.body.error) || ("Restart " + id + " done"), r2.body && r2.body.ok ? "info" : "error");
              });
            }
          }).catch(function (e) { toast("Restart failed: " + e.message, "error"); })
          .then(function () { b.disabled = false; });
        });
        bar.appendChild(b);
      });
    } catch (_) {}
  }

  // OPSU-002 Live log-tail viewer modal (polls GET /api/activity, pause + scroll-lock).
  var logState = { open: false, paused: false, lock: true, timer: 0 };
  function ensureLogModal() {
    if (document.getElementById("opsu-modal")) return;
    var ov = document.createElement("div");
    ov.id = "opsu-modal";
    ov.setAttribute("role", "dialog");
    ov.setAttribute("aria-modal", "true");
    ov.setAttribute("aria-label", "Live log tail");
    ov.innerHTML = '<div class="opsu-card"><h3>Live log tail <span style="color:var(--muted,#9aa7bd)">(GET /api/activity)</span></h3>'
      + '<p>Polls the existing activity endpoint every 3s. Pause freezes updates; scroll-lock keeps the newest lines pinned.</p>'
      + '<div class="opsu-row"><label><input type="checkbox" id="opsu-log-pause"> Pause</label>'
      + '<label><input type="checkbox" id="opsu-log-lock" checked> Scroll-lock</label>'
      + '<button class="opsu-btn" id="opsu-log-close" type="button">Close</button></div>'
      + '<div style="height:8px"></div><div class="opsu-log" id="opsu-log-view" aria-live="polite">Loading…</div>'
      + '<p>Sources: <a href="/api/activity" target="_blank" rel="noopener">/api/activity</a> · <a href="/api/timeline" target="_blank" rel="noopener">/api/timeline</a></p></div>';
    document.body.appendChild(ov);
    ov.addEventListener("click", function (e) { if (e.target === ov) closeLogModal(); });
    document.getElementById("opsu-log-close").addEventListener("click", closeLogModal);
    document.getElementById("opsu-log-pause").addEventListener("change", function (e) { logState.paused = !!e.target.checked; });
    document.getElementById("opsu-log-lock").addEventListener("change", function (e) { logState.lock = !!e.target.checked; });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") closeLogModal(); });
  }
  function openLogModal() {
    ensureLogModal();
    logState.open = true;
    document.getElementById("opsu-modal").classList.add("is-open");
    pollLogTail();
    clearInterval(logState.timer);
    logState.timer = setInterval(function () { if (logState.open && !logState.paused && !document.hidden) pollLogTail(); }, 3000);
  }
  function closeLogModal() {
    logState.open = false;
    clearInterval(logState.timer);
    var m = document.getElementById("opsu-modal");
    if (m) m.classList.remove("is-open");
  }
  function pollLogTail() {
    getJSON("/api/activity", 15000).then(function (j) {
      var view = document.getElementById("opsu-log-view");
      if (!view || logState.paused) return;
      var lines = Array.isArray(j.activity) ? j.activity.slice(-120) : [];
      view.textContent = lines.length ? lines.join("\n") : "(no activity lines)";
      if (logState.lock) view.scrollTop = view.scrollHeight;
    }).catch(function (e) {
      var view = document.getElementById("opsu-log-view");
      if (view) view.textContent = "Log poll failed: " + e.message;
    });
  }

  // OPSU-003 24h health-timeline mini graph (canvas, sampled from GET /api/health + /api/status).
  function recordHealthSample(okCount, total) {
    try {
      var arr = loadLS(LS_HEALTH, []);
      arr.push({ t: Date.now(), ok: okCount, total: total });
      var cutoff = Date.now() - 24 * 3600 * 1000;
      arr = arr.filter(function (s) { return s.t >= cutoff; }).slice(-288);
      saveLS(LS_HEALTH, arr);
      drawHealthGraph();
    } catch (_) {}
  }
  function drawHealthGraph() {
    try {
      var cv = document.getElementById("opsu-health-canvas");
      if (!cv) return;
      var dpr = Math.min(2, window.devicePixelRatio || 1);
      var w = cv.clientWidth || 260, h = 90;
      cv.width = Math.max(1, Math.round(w * dpr)); cv.height = Math.round(h * dpr);
      var ctx = cv.getContext("2d");
      ctx.scale(dpr, dpr);
      ctx.clearRect(0, 0, w, h);
      var arr = loadLS(LS_HEALTH, []);
      ctx.fillStyle = "#7dd88a"; ctx.strokeStyle = "rgba(125,216,138,.6)";
      if (!arr.length) { ctx.fillStyle = "#9aa7bd"; ctx.font = "11px system-ui"; ctx.fillText("Collecting samples…", 8, 20); return; }
      var n = arr.length, bw = Math.max(1, w / Math.max(n, 24));
      arr.forEach(function (s, i) {
        var frac = s.total ? s.ok / s.total : 0;
        var bh = Math.max(2, Math.round(frac * (h - 14)));
        ctx.fillRect(i * bw, h - 6 - bh, Math.max(1, bw - 1), bh);
      });
      ctx.fillStyle = "#9aa7bd"; ctx.font = "10px system-ui";
      ctx.fillText("24h samples: " + n + " (GET /api/health)", 8, 12);
    } catch (_) {}
  }

  // OPSU-004 Alert rules (mount-down toasts, rule list persisted in localStorage).
  function defaultRules() {
    return [
      { id: "mount-down", name: "Mount down (gdrive / torboxmount)", enabled: true },
      { id: "stack-down", name: "Whole stack stopped", enabled: true }
    ];
  }
  function getRules() {
    var r = loadLS(LS_RULES, null);
    if (!Array.isArray(r) || !r.length) { r = defaultRules(); saveLS(LS_RULES, r); }
    return r;
  }
  function renderRules() {
    try {
      var box = document.getElementById("opsu-rules");
      if (!box) return;
      var rules = getRules();
      box.innerHTML = rules.map(function (r) {
        return '<label class="opsu-row" style="gap:6px"><input type="checkbox" data-rule="' + esc(r.id) + '"' + (r.enabled ? " checked" : "") + '> <span>' + esc(r.name) + '</span></label>';
      }).join("");
      Array.prototype.forEach.call(box.querySelectorAll("[data-rule]"), function (cb) {
        cb.addEventListener("change", function () {
          var rules2 = getRules();
          rules2.forEach(function (x) { if (x.id === cb.getAttribute("data-rule")) x.enabled = cb.checked; });
          saveLS(LS_RULES, rules2);
          toast("Alert rule updated", "info");
        });
      });
    } catch (_) {}
  }
  var lastAlertAt = {};
  function evalAlertRules(health) {
    try {
      var rules = getRules();
      var byId = {};
      (health && health.services ? Object.keys(health.services) : []).forEach(function (k) { byId[k] = health.services[k]; });
      var mountsDown = ["gdrive", "torboxmount"].filter(function (m) { return byId[m] && byId[m].ok === false; });
      var allDown = health && health.services && Object.keys(health.services).length && Object.keys(health.services).every(function (k) { return !health.services[k].ok; });
      function fire(key, msg) {
        var now = Date.now();
        if (now - (lastAlertAt[key] || 0) < 60000) return;
        lastAlertAt[key] = now;
        toast(msg, "error");
      }
      rules.forEach(function (r) {
        if (!r.enabled) return;
        if (r.id === "mount-down" && mountsDown.length) fire("mount-down", "Mount down: " + mountsDown.join(", ") + " (see /api/health)");
        if (r.id === "stack-down" && allDown) fire("stack-down", "Stack stopped — all health checks failing");
      });
    } catch (_) {}
  }

  // OPSU-009 Safe-mode banner (panel-only degraded notice when mounts are down).
  function ensureBanner() {
    if (document.getElementById("opsu-banner")) return;
    var b = document.createElement("div");
    b.id = "opsu-banner";
    b.setAttribute("role", "status");
    document.querySelector("main.shell, main, body").prepend(b);
  }
  function updateSafeBanner(health) {
    try {
      ensureBanner();
      var b = document.getElementById("opsu-banner");
      var svcs = (health && health.services) || {};
      var down = ["gdrive", "torboxmount"].filter(function (m) { return svcs[m] && svcs[m].ok === false; });
      if (!down.length) { b.classList.remove("is-show"); b.innerHTML = ""; return; }
      b.classList.add("is-show");
      b.innerHTML = "<span><strong>Safe mode (panel-only):</strong> mount(s) down — " + esc(down.join(", "))
        + ". Playback may be degraded. Use Ops remount buttons below or check <a href=\"/api/health\" target=\"_blank\" rel=\"noopener\">/api/health</a>.</span>"
        + '<span class="opsu-row"><button class="opsu-btn" id="opsu-banner-remount" type="button">Remount now</button>'
        + '<button class="opsu-btn" id="opsu-banner-hide" type="button">Dismiss</button></span>';
      document.getElementById("opsu-banner-hide").addEventListener("click", function () { b.classList.remove("is-show"); });
      document.getElementById("opsu-banner-remount").addEventListener("click", function () {
        var t = document.getElementById("opsu-panel");
        if (t && t.scrollIntoView) t.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    } catch (_) {}
  }

  // OPSU-005 One-click remount for gdrive/torbox (existing start/restart action routes).
  function remount(id) {
    if (!window.confirm("Remount '" + id + "'? (POST /api/action start, fallback restart)")) return;
    postJSON("/api/action", { action: "start", service: id }).then(function (res) {
      var ok = res.body && res.body.ok;
      toast((res.body && (res.body.message || res.body.error)) || ("Remount " + id), ok ? "info" : "error");
      if (!ok) return postJSON("/api/action", { action: "restart", service: id }).then(function (r2) {
        toast((r2.body && (r2.body.message || r2.body.error)) || "retry done", r2.body && r2.body.ok ? "info" : "error");
      });
    }).catch(function (e) { toast("Remount failed: " + e.message, "error"); });
  }

  // OPSU-006 Disk-space warning thresholds with header badge (reads existing /api/metrics + /api/status only).
  function getThresholds() {
    var t = loadLS(LS_DISK, null);
    if (!t || typeof t.warnPct !== "number") { t = { warnPct: 85, critPct: 95 }; saveLS(LS_DISK, t); }
    return t;
  }
  function ensureDiskBadge() {
    if (document.getElementById("opsu-disk-badge")) return document.getElementById("opsu-disk-badge");
    var badge = document.createElement("span");
    badge.id = "opsu-disk-badge";
    badge.title = "Disk/mount badge from GET /api/metrics (thresholds in Ops panel)";
    badge.textContent = "Disk: …";
    var anchor = document.getElementById("stack-chip") || document.getElementById("last-checked");
    if (anchor && anchor.parentElement) anchor.parentElement.appendChild(badge);
    else document.body.appendChild(badge);
    return badge;
  }
  function refreshDiskBadge() {
    var badge = ensureDiskBadge();
    getJSON("/api/metrics", 15000).then(function (m) {
      var t = getThresholds();
      var found = [];
      try {
        // Best-effort scan of known metrics shapes; never invents a new endpoint.
        ["mount", "vfs", "disk", "diskCache"].forEach(function (k) {
          if (m && m[k] && typeof m[k] === "object") found.push(k);
        });
      } catch (_) {}
      var label = "Disk: ok", warn = false;
      // If torbox mount state is warning, surface it; thresholds apply when a pct field exists.
      var pct = null;
      try {
        pct = m && (m.use_pct || m.used_pct || (m.mount && (m.mount.use_pct || m.mount.pct)));
        if (typeof pct === "string" && pct.indexOf("%") >= 0) pct = parseFloat(pct);
        if (typeof pct === "number" && isFinite(pct)) {
          if (pct >= t.critPct) { label = "Disk: CRIT " + pct + "%"; warn = true; }
          else if (pct >= t.warnPct) { label = "Disk: warn " + pct + "%"; warn = true; }
          else label = "Disk: " + pct + "%";
        } else {
          var st = (m && (m.mount_state || m.state)) || "";
          label = st ? ("Mount: " + st) : "Disk: n/a (see /api/metrics)";
          warn = /warn/i.test(String(st));
        }
      } catch (_) { label = "Disk: n/a (see /api/metrics)"; }
      badge.textContent = label;
      badge.classList.toggle("is-warn", !!warn);
      if (warn) toast(label + " — threshold ≥ " + t.warnPct + "%", "error");
    }).catch(function () { badge.textContent = "Disk: unreachable"; });
  }

  // OPSU-007 Backup/restore panel config (export/import one JSON file; config API is read-only).
  function exportBackup() {
    getJSON("/api/config", 15000).then(function (cfg) {
      var prefs = {};
      ["opsu.alertRules.v1", "opsu.diskThresholds.v1", "opsu.healthSamples.v1",
       "jellyfin.panel.activity.sourceFilter", "jellyfin.panel.activity.errorsOnly",
       "jellyfin.panel.ui.density"].forEach(function (k) {
        try { var v = localStorage.getItem(k); if (v !== null) prefs[k] = v; } catch (_) {}
      });
      download("panel-backup-" + new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-") + ".json",
        JSON.stringify({ exported_at: new Date().toISOString(), config: cfg, prefs: prefs }, null, 2));
      toast("Backup exported (GET /api/config + local prefs)", "info");
    }).catch(function (e) { toast("Backup export failed: " + e.message, "error"); });
  }
  function importBackup(file) {
    var rd = new FileReader();
    rd.onload = function () {
      try {
        var j = JSON.parse(String(rd.result || "{}"));
        var prefs = (j && j.prefs) || {};
        Object.keys(prefs).forEach(function (k) { try { localStorage.setItem(k, String(prefs[k])); } catch (_) {} });
        renderRules(); refreshDiskBadge(); drawHealthGraph();
        toast("Backup imported to local prefs (config API is read-only; no POST attempted)", "info");
      } catch (e) { toast("Import failed: " + e.message, "error"); }
    };
    rd.readAsText(file);
  }

  // OPSU-008 Update checker card (local version reads only, no auto-install).
  function refreshVersions() {
    var box = document.getElementById("opsu-versions");
    if (box) box.textContent = "Checking GET /api/config + /api/status…";
    Promise.all([getJSON("/api/config", 15000).catch(function (e) { return { _err: String(e.message || e) }; }),
                 getJSON("/api/status", 15000).catch(function (e) { return { _err: String(e.message || e) }; })])
      .then(function (pair) {
        var cfg = pair[0], st = pair[1];
        var rows = [];
        try {
          var vers = (cfg && cfg.versions) || {};
          Object.keys(vers).forEach(function (k) { rows.push(["config." + k, String(vers[k])]); });
          var svcs = (st && st.services) || {};
          Object.keys(svcs).forEach(function (k) { if (svcs[k] && svcs[k].version) rows.push([k + " (status)", String(svcs[k].version)]); });
        } catch (_) {}
        if (box) {
          box.innerHTML = rows.length
            ? "<ul>" + rows.map(function (r) { return "<li><code>" + esc(r[0]) + "</code>: " + esc(r[1]) + "</li>"; }).join("") + "</ul>"
              + '<p>No auto-install. Compare against upstream release pages; open <a href="http://127.0.0.1:8096/" target="_blank" rel="noopener">Jellyfin</a> · <a href="/api/config" target="_blank" rel="noopener">/api/config</a>.</p>'
            : "<p>No version fields exposed by existing reads.</p>";
        }
      });
  }

  // OPSU-010 Forensics-bundle download (assembled client-side from existing GET endpoints only).
  function downloadForensics() {
    var urls = ["/api/health", "/api/status", "/api/activity", "/api/timeline", "/api/metrics", "/api/config"];
    Promise.all(urls.map(function (u) { return getJSON(u, 15000).then(function (j) { return [u, j]; }).catch(function (e) { return [u, { _error: String(e.message || e) }]; }); }))
      .then(function (pairs) {
        var bundle = { exported_at: new Date().toISOString(), sources: {} };
        pairs.forEach(function (p) { bundle.sources[p[0]] = p[1]; });
        download("forensics-bundle-" + Date.now() + ".json", JSON.stringify(bundle, null, 2));
        toast("Forensics bundle downloaded (existing GETs only)", "info");
      });
  }

  function buildPanel() {
    if (document.getElementById(DOCK_ID)) return;
    var host = document.querySelector("main.shell") || document.body;
    var sec = document.createElement("section");
    sec.id = DOCK_ID;
    sec.setAttribute("aria-label", "Ops extras");
    sec.innerHTML =
      '<div class="pane-heading"><h2>Ops extras</h2><span class="pane-hint">Additive wins · existing endpoints only</span></div>'
      + '<div class="opsu-grid">'
      + '<div class="opsu-card"><h3>Log tail</h3><p>Modal polling <code>/api/activity</code>.</p><div class="opsu-row"><button class="opsu-btn" id="opsu-open-logs" type="button">Open log tail</button></div></div>'
      + '<div class="opsu-card"><h3>Health timeline (24h)</h3><p>Canvas from <code>/api/health</code> samples.</p><canvas class="opsu-canvas" id="opsu-health-canvas" width="260" height="90"></canvas></div>'
      + '<div class="opsu-card"><h3>Alert rules</h3><p>Mount-down toasts; stored in localStorage.</p><div id="opsu-rules"></div></div>'
      + '<div class="opsu-card"><h3>Remount</h3><p>One-click via existing <code>/api/action</code> start.</p><div class="opsu-row"><button class="opsu-btn" id="opsu-remount-gdrive" type="button">Remount gdrive</button><button class="opsu-btn" id="opsu-remount-tb" type="button">Remount torbox</button></div></div>'
      + '<div class="opsu-card"><h3>Disk thresholds</h3><p>Badge reads <code>/api/metrics</code> only.</p><div class="opsu-row"><label>Warn % <input class="opsu-input" id="opsu-warn" type="number" min="1" max="100" style="width:64px"></label><label>Crit % <input class="opsu-input" id="opsu-crit" type="number" min="1" max="100" style="width:64px"></label><button class="opsu-btn" id="opsu-disk-save" type="button">Save</button></div></div>'
      + '<div class="opsu-card"><h3>Backup / restore</h3><p>One JSON file (<code>/api/config</code> is read-only).</p><div class="opsu-row"><button class="opsu-btn" id="opsu-export" type="button">Export</button><label class="opsu-btn">Import <input type="file" id="opsu-import" accept="application/json" hidden></label></div></div>'
      + '<div class="opsu-card"><h3>Update checker</h3><p>Local reads only; no auto-install.</p><div class="opsu-row"><button class="opsu-btn" id="opsu-versions-btn" type="button">Check versions</button></div><div id="opsu-versions"></div></div>'
      + '<div class="opsu-card"><h3>Forensics bundle</h3><p>Client-side zip-free JSON from existing GETs.</p><div class="opsu-row"><button class="opsu-btn" id="opsu-forensics" type="button">Download bundle</button></div><p>Sources: <a href="/api/activity" target="_blank" rel="noopener">activity</a> · <a href="/api/timeline" target="_blank" rel="noopener">timeline</a> · <a href="/api/status" target="_blank" rel="noopener">status</a> · <a href="/api/metrics" target="_blank" rel="noopener">metrics</a></p></div>'
      + "</div>";
    host.appendChild(sec);
    document.getElementById("opsu-open-logs").addEventListener("click", openLogModal);
    document.getElementById("opsu-remount-gdrive").addEventListener("click", function () { remount("gdrive"); });
    document.getElementById("opsu-remount-tb").addEventListener("click", function () { remount("torboxmount"); });
    document.getElementById("opsu-export").addEventListener("click", exportBackup);
    document.getElementById("opsu-import").addEventListener("change", function (e) { if (e.target.files && e.target.files[0]) importBackup(e.target.files[0]); });
    document.getElementById("opsu-versions-btn").addEventListener("click", refreshVersions);
    document.getElementById("opsu-forensics").addEventListener("click", downloadForensics);
    var th = getThresholds();
    document.getElementById("opsu-warn").value = th.warnPct;
    document.getElementById("opsu-crit").value = th.critPct;
    document.getElementById("opsu-disk-save").addEventListener("click", function () {
      var w = Math.max(1, Math.min(100, parseInt(document.getElementById("opsu-warn").value, 10) || 85));
      var c = Math.max(1, Math.min(100, parseInt(document.getElementById("opsu-crit").value, 10) || 95));
      saveLS(LS_DISK, { warnPct: w, critPct: c });
      toast("Disk thresholds saved", "info");
      refreshDiskBadge();
    });
    renderRules();
  }

  function pollHealth() {
    getJSON("/api/health", 15000).then(function (h) {
      var svcs = (h && h.services) || {};
      var keys = Object.keys(svcs);
      var ok = keys.filter(function (k) { return svcs[k] && svcs[k].ok; }).length;
      recordHealthSample(ok, keys.length || 5);
      evalAlertRules(h);
      updateSafeBanner(h);
    }).catch(function () {});
  }

  try {
    ensureStyles();
    buildPanel();
    enhanceRestartButtons();
    refreshDiskBadge();
    drawHealthGraph();
    pollHealth();
    setInterval(enhanceRestartButtons, 4000);
    setInterval(function () { if (!document.hidden) { refreshDiskBadge(); pollHealth(); drawHealthGraph(); } }, 30000);
    window.addEventListener("resize", drawHealthGraph);
  } catch (_) { /* additive only: never break host panel */ }
})();
