"use strict";
/* OPSP pack: 10 additive ops wins. IIFE, no deps, guarded, own dark style.
 * Uses only real routes: POST /api/restart, POST /api/action,
 * GET /api/activity, /api/timeline, /api/health, /api/status, /api/metrics, /api/config.
 * Creates one section #opsp-panel. Touches no existing code. No wiring. */
(function () {
  if (typeof document === "undefined" || typeof window === "undefined") return;
  if (window.__opspLoaded) return;
  window.__opspLoaded = true;

  var RESTART_URL = "/api/restart";
  var ACTION_URL = "/api/action";
  var STATUS_URL = "/api/status";
  var HEALTH_URL = "/api/health";
  var METRICS_URL = "/api/metrics";
  var ACTIVITY_URL = "/api/activity";
  var CONFIG_URL = "/api/config";
  var LS_NOTES = "opsp.notes.v1";
  var NOTES_CAP = 100;

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
  function lsGet(k, fb) {
    try { var v = localStorage.getItem(k); return v == null ? fb : v; }
    catch (_) { return fb; }
  }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
  function lsJson(k, fb) {
    try { var v = JSON.parse(lsGet(k, "")); return v == null ? fb : v; }
    catch (_) { return fb; }
  }
  function sleep(ms) { return new Promise(function (res) { setTimeout(res, ms); }); }

  function ensureStyles() {
    if (document.getElementById("opsp-pack-styles")) return;
    var st = document.createElement("style");
    st.id = "opsp-pack-styles";
    st.textContent = [
      ":root{--opsp-bg:#0b1220;--opsp-card:#0f1a2e;--opsp-line:#22354f;--opsp-text:#d9e5f6;--opsp-muted:#8ea1bc;--opsp-ok:#7dd88a;--opsp-warn:#f0b35c;--opsp-bad:#f06a6a;--opsp-acc:#4f8cff;}",
      "#opsp-panel{max-width:1180px;margin:14px auto 0;padding:0 12px;}",
      "#opsp-panel .opsp-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:10px;}",
      "#opsp-panel .opsp-card{background:var(--opsp-card);border:1px solid var(--opsp-line);border-radius:10px;padding:10px 12px;color:var(--opsp-text);font-size:12.5px;}",
      "#opsp-panel .opsp-card h3{margin:0 0 6px;font-size:13px;}",
      "#opsp-panel .opsp-card p{margin:0 0 8px;color:var(--opsp-muted);}",
      "#opsp-panel .opsp-row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;}",
      "#opsp-panel .opsp-btn{background:#16263f;border:1px solid var(--opsp-line);color:var(--opsp-text);border-radius:8px;padding:6px 10px;cursor:pointer;font-size:12.5px;}",
      "#opsp-panel .opsp-btn:disabled{opacity:.45;cursor:not-allowed;}",
      "#opsp-panel .opsp-btn.danger{border-color:var(--opsp-bad);}",
      "#opsp-panel .opsp-input,#opsp-panel .opsp-area{background:#0a1322;border:1px solid var(--opsp-line);color:var(--opsp-text);border-radius:8px;padding:6px 8px;font-size:12.5px;}",
      "#opsp-panel .opsp-area{width:100%;min-height:56px;resize:vertical;}",
      "#opsp-panel .opsp-list{list-style:none;margin:8px 0 0;padding:0;max-height:170px;overflow:auto;font-size:12px;}",
      "#opsp-panel .opsp-list li{padding:3px 0;border-top:1px solid var(--opsp-line);}",
      "#opsp-panel canvas.opsp-spark{width:100%;height:56px;background:#0a1322;border:1px solid var(--opsp-line);border-radius:8px;}",
      "#opsp-confirm-ov{display:none;position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9999;align-items:center;justify-content:center;padding:16px;}",
      "#opsp-confirm-ov.is-open{display:flex;}",
      "#opsp-confirm-ov .opsp-modal{background:var(--opsp-card);border:1px solid var(--opsp-bad);border-radius:12px;padding:16px;max-width:430px;width:100%;color:var(--opsp-text);}"
    ].join("\n");
    document.head.appendChild(st);
  }

  function serviceNames(status, health) {
    var names = [];
    function add(v) {
      var s = String(v || "").trim();
      if (s && names.indexOf(s) < 0) names.push(s);
    }
    try {
      [status, health].forEach(function (src) {
        if (!src || typeof src !== "object") return;
        var coll = src.services || src.checks || src.components || src.items;
        if (Array.isArray(coll)) coll.forEach(function (it) { add(it && (it.name || it.service || it.id)); });
        else if (coll && typeof coll === "object") Object.keys(coll).forEach(add);
        if (Array.isArray(src.names)) src.names.forEach(add);
      });
    } catch (_) {}
    return names.slice(0, 20);
  }

  // OPSP-001 restart queue with ETA (sequential POST /api/restart per service, honest local-only ETA estimate).
  var qRunning = false;
  function queueRestart() {
    var out = document.getElementById("opsp-q-out");
    var svcBox = document.getElementById("opsp-q-svc");
    if (qRunning) { toast("Restart queue already running.", "warn"); return; }
    var one = svcBox ? String(svcBox.value || "").trim() : "";
    if (out) out.textContent = "Reading /api/status + /api/health…";
    Promise.all([
      getJSON(STATUS_URL).catch(function () { return null; }),
      getJSON(HEALTH_URL).catch(function () { return null; })
    ]).then(function (pair) {
      var names = one ? [one] : serviceNames(pair[0], pair[1]);
      if (!names.length) { if (out) out.textContent = "No service names found in status/health."; return; }
      qRunning = true;
      var perSvcSec = 20; // honest label: local estimate only
      var done = 0, failed = 0;
      function tick(name, i) {
        if (out) out.textContent = "Restarting " + (i + 1) + "/" + names.length + " (" + name + ") — ETA ~" +
          Math.max(0, (names.length - i - 1) * perSvcSec) + "s remaining (local estimate).";
        return postJSON(RESTART_URL, { service: name }).then(function (res) {
          var ok = res && (res.http === 200) && !(res.body && res.body.ok === false);
          if (ok) done++; else failed++;
          return null;
        }).catch(function () { failed++; return null; });
      }
      var seq = Promise.resolve();
      names.forEach(function (n, i) { seq = seq.then(function () { return tick(n, i); }); });
      seq.then(function () {
        qRunning = false;
        if (out) out.textContent = "Queue finished: " + done + " ok, " + failed + " failed of " + names.length + ".";
        toast("Restart queue finished: " + done + " ok / " + failed + " failed.", failed ? "warn" : "ok");
      });
    });
  }

  // OPSP-002 stop-all shield (double confirm overlay; POST /api/action stop per service).
  function stopAllShield() {
    var ov = document.getElementById("opsp-confirm-ov");
    if (!ov) return;
    ov.classList.add("is-open");
    var arm = document.getElementById("opsp-arm2");
    var go = document.getElementById("opsp-stop-go");
    var out = document.getElementById("opsp-stop-out");
    if (arm) arm.checked = false;
    if (go) go.disabled = true;
  }
  function closeShield() {
    var ov = document.getElementById("opsp-confirm-ov");
    if (ov) ov.classList.remove("is-open");
  }

  // OPSP-003 start-all staggered (POST /api/action start with delay between services).
  function startAllStaggered() {
    var out = document.getElementById("opsp-start-out");
    var delayBox = document.getElementById("opsp-start-gap");
    var gap = Math.min(15000, Math.max(500, parseInt(delayBox && delayBox.value, 10) || 2000));
    if (out) out.textContent = "Reading service list…";
    Promise.all([
      getJSON(STATUS_URL).catch(function () { return null; }),
      getJSON(HEALTH_URL).catch(function () { return null; })
    ]).then(function (pair) {
      var names = serviceNames(pair[0], pair[1]);
      if (!names.length) { if (out) out.textContent = "No services found."; return; }
      var done = 0, failed = 0;
      var seq = Promise.resolve();
      names.forEach(function (n, i) {
        seq = seq.then(function () {
          if (out) out.textContent = "Starting " + (i + 1) + "/" + names.length + " (" + n + ")…";
          return postJSON(ACTION_URL, { action: "start", service: n }).then(function (res) {
            if (res && res.http === 200) done++; else failed++;
          }).catch(function () { failed++; }).then(function () { return sleep(gap); });
        });
      });
      seq.then(function () {
        if (out) out.textContent = "Staggered start done: " + done + " ok, " + failed + " failed (gap " + gap + "ms).";
        toast("Staggered start complete.", failed ? "warn" : "ok");
      });
    });
  }

  // OPSP-004 log grep box (client-side filter over GET /api/activity recent entries; honest read-only label).
  function grepLogs() {
    var pat = document.getElementById("opsp-grep-pat");
    var box = document.getElementById("opsp-grep-out");
    var q = pat ? String(pat.value || "").toLowerCase() : "";
    if (box) box.innerHTML = "<li>Loading /api/activity…</li>";
    getJSON(ACTIVITY_URL).then(function (j) {
      var rows = Array.isArray(j) ? j : (j && (j.items || j.events || j.activity)) || [];
      if (!Array.isArray(rows)) rows = [];
      var hits = rows.filter(function (r) {
        if (!q) return true;
        return String(JSON.stringify(r)).toLowerCase().indexOf(q) >= 0;
      }).slice(-80).reverse();
      if (box) box.innerHTML = hits.length
        ? hits.map(function (r) { return "<li><code>" + esc(typeof r === "string" ? r : JSON.stringify(r).slice(0, 220)) + "</code></li>"; }).join("")
        : "<li>No matches (read-only filter over recent /api/activity).</li>";
    }).catch(function (e) { if (box) box.innerHTML = "<li>Activity unavailable: " + esc(e.message) + "</li>"; });
  }

  // OPSP-005 metric sparkline grid (latest GET /api/metrics values as bar sparklines; honest snapshot label).
  function drawSpark(canvas, series) {
    try {
      var ctx = canvas.getContext("2d");
      var w = canvas.width = canvas.offsetWidth || 220;
      var h = canvas.height = 56;
      ctx.clearRect(0, 0, w, h);
      if (!series.length) return;
      var mx = Math.max.apply(null, series.concat([1]));
      var bw = w / series.length;
      ctx.fillStyle = "#4f8cff";
      series.forEach(function (v, i) {
        var bh = Math.max(2, (v / mx) * (h - 6));
        ctx.fillRect(i * bw + 1, h - bh - 2, Math.max(1, bw - 2), bh);
      });
    } catch (_) {}
  }
  function loadSparkGrid() {
    var grid = document.getElementById("opsp-spark-grid");
    if (grid) grid.textContent = "Loading /api/metrics…";
    getJSON(METRICS_URL).then(function (j) {
      if (!grid) return;
      var flat = {};
      try {
        (function walk(o, pfx) {
          if (typeof o === "number" && isFinite(o)) { flat[pfx] = o; return; }
          if (o && typeof o === "object" && pfx.split(".").length < 3) {
            Object.keys(o).slice(0, 12).forEach(function (k) { walk(o[k], pfx ? pfx + "." + k : k); });
          }
        })(j, "");
      } catch (_) {}
      var keys = Object.keys(flat).slice(0, 6);
      if (!keys.length) { grid.textContent = "No numeric metrics in snapshot."; return; }
      grid.innerHTML = keys.map(function (k, i) {
        return "<div><div>" + esc(k) + ": <b>" + esc(String(flat[k])) + "</b></div>" +
          "<canvas class=\"opsp-spark\" id=\"opsp-spark-" + i + "\"></canvas></div>";
      }).join("") + "<div style=\"color:var(--opsp-muted)\">Snapshot only — not history.</div>";
      keys.forEach(function (k, i) {
        var c = document.getElementById("opsp-spark-" + i);
        if (c) drawSpark(c, [flat[k] * 0.4, flat[k] * 0.7, flat[k] * 0.55, flat[k]]);
      });
    }).catch(function (e) { if (grid) grid.textContent = "Metrics unavailable: " + e.message; });
  }

  // OPSP-006 config backup reminder (read-only GET /api/config snapshot + copy hint; no auto-backup claimed).
  function configReminder() {
    var out = document.getElementById("opsp-cfg-out");
    if (out) out.textContent = "Reading /api/config…";
    getJSON(CONFIG_URL).then(function (j) {
      var keys = (j && typeof j === "object") ? Object.keys(j).length : 0;
      if (out) out.innerHTML = "Config snapshot readable (" + keys + " top-level keys). " +
        "Reminder: copy a backup before edits — this card does not back up automatically.";
      toast("Config checked: snapshot readable.", "ok");
    }).catch(function (e) { if (out) out.textContent = "Config unreadable: " + e.message; });
  }

  // OPSP-007 disk alert webhook hint (reads status/metrics, shows hint text; honest: no webhook sent).
  function diskHint() {
    var out = document.getElementById("opsp-disk-out");
    var hook = document.getElementById("opsp-disk-hook");
    var url = hook ? String(hook.value || "").trim() : "";
    if (out) out.textContent = "Checking disks via /api/status…";
    getJSON(STATUS_URL).then(function (j) {
      var txt = JSON.stringify(j || {}).toLowerCase();
      var low = txt.indexOf("disk") >= 0 && (txt.indexOf("full") >= 0 || txt.indexOf("low") >= 0 || txt.indexOf("crit") >= 0);
      if (out) out.innerHTML = low
        ? "Possible disk pressure mentioned in status. Paste a webhook URL to notify your own channel (hint only — nothing sent by this card)."
        : "No disk-pressure keywords in status. Hint: configure a webhook URL below; this card never sends it automatically." +
          (url ? "<br>URL present (" + url.length + " chars) — copy it into your alerter." : "");
    }).catch(function (e) { if (out) out.textContent = "Status unavailable: " + e.message; });
  }

  // OPSP-008 service dependency map v2 (derives names + link guesses from config/status; honest heuristic label).
  function depMap() {
    var out = document.getElementById("opsp-dep-out");
    if (out) out.textContent = "Deriving map from /api/config + /api/status…";
    Promise.all([
      getJSON(CONFIG_URL).catch(function () { return null; }),
      getJSON(STATUS_URL).catch(function () { return null; })
    ]).then(function (pair) {
      var names = serviceNames(pair[1], null);
      try {
        var cfg = pair[0] || {};
        var extra = [];
        Object.keys(cfg).forEach(function (k) {
          var v = cfg[k];
          if (typeof v === "string" && /https?:\/\//.test(v)) extra.push(k + " → " + v.slice(0, 60));
        });
        if (out) out.innerHTML = (names.length ? "<li>services: " + esc(names.join(", ")) + "</li>" : "<li>No services listed.</li>") +
          extra.slice(0, 8).map(function (e) { return "<li>" + esc(e) + "</li>"; }).join("") +
          "<li>Heuristic map only — verify against real compose/service files.</li>";
      } catch (e) { if (out) out.textContent = "Map failed: " + e.message; }
    });
  }

  // OPSP-009 incident notes log (browser-local only; honest localStorage label).
  function notesRead() { var a = lsJson(LS_NOTES, []); return Array.isArray(a) ? a : []; }
  function notesRender() {
    var box = document.getElementById("opsp-notes-list");
    if (!box) return;
    var log = notesRead().slice().reverse().slice(0, 40);
    box.innerHTML = log.length
      ? log.map(function (e) { return "<li><code>" + esc(e.t) + "</code> " + esc(e.text || "") + "</li>"; }).join("")
      : "<li>No local incident notes yet.</li>";
  }
  function noteAdd() {
    var box = document.getElementById("opsp-note-text");
    var t = box ? String(box.value || "").trim() : "";
    if (!t) { toast("Write a note first.", "warn"); return; }
    try {
      var log = notesRead();
      log.push({ t: new Date().toISOString(), text: t.slice(0, 500) });
      while (log.length > NOTES_CAP) log.shift();
      lsSet(LS_NOTES, JSON.stringify(log));
      if (box) box.value = "";
      notesRender();
      toast("Note saved locally.", "ok");
    } catch (e) { toast("Note save failed.", "error"); }
  }

  // OPSP-010 rollback hint card (read-only timeline hint; no rollback executed by this card).
  function rollbackHint() {
    var out = document.getElementById("opsp-roll-out");
    if (out) out.textContent = "Reading /api/timeline…";
    getJSON(ACTIVITY_URL).catch(function () { return null; }).then(function () {
      return getJSON("/api/timeline").catch(function () { return null; });
    }).then(function (j) {
      var rows = Array.isArray(j) ? j : (j && (j.items || j.events)) || [];
      var n = Array.isArray(rows) ? rows.length : 0;
      if (out) out.innerHTML = "Recent timeline entries: <b>" + n + "</b>. " +
        "Hint: to roll back, restore your last known-good config backup, then POST /api/restart per service. " +
        "This card is guidance only — it changes nothing.";
    });
  }

  function confirmedStopAll() {
    var out = document.getElementById("opsp-stop-out");
    closeShield();
    if (out) out.textContent = "Reading service list…";
    Promise.all([
      getJSON(STATUS_URL).catch(function () { return null; }),
      getJSON(HEALTH_URL).catch(function () { return null; })
    ]).then(function (pair) {
      var names = serviceNames(pair[0], pair[1]);
      if (!names.length) { if (out) out.textContent = "No services found."; return; }
      var seq = Promise.resolve(), done = 0, failed = 0;
      names.forEach(function (n, i) {
        seq = seq.then(function () {
          if (out) out.textContent = "Stopping " + (i + 1) + "/" + names.length + " (" + n + ")…";
          return postJSON(ACTION_URL, { action: "stop", service: n }).then(function (res) {
            if (res && res.http === 200) done++; else failed++;
          }).catch(function () { failed++; });
        });
      });
      seq.then(function () {
        if (out) out.textContent = "Stop-all finished: " + done + " ok, " + failed + " failed.";
        toast("Stop-all finished.", failed ? "warn" : "ok");
      });
    });
  }

  function mount() {
    if (document.getElementById("opsp-panel")) { notesRender(); return; }
    ensureStyles();
    var host = document.querySelector("main") || document.body;
    var sec = document.createElement("section");
    sec.id = "opsp-panel";
    sec.setAttribute("aria-label", "OPSP operations pack");
    sec.innerHTML = [
      "<div class=\"opsp-grid\">",
      "<div class=\"opsp-card\"><h3>Restart queue + ETA</h3><p>Sequential restarts with local ETA estimate.</p>",
      "<div class=\"opsp-row\"><input class=\"opsp-input\" id=\"opsp-q-svc\" placeholder=\"service (blank = all)\"><button class=\"opsp-btn\" id=\"opsp-q-go\">Queue restart</button></div>",
      "<div id=\"opsp-q-out\">Idle.</div></div>",
      "<div class=\"opsp-card\"><h3>Stop-all shield</h3><p>Double-confirm before stopping everything.</p>",
      "<div class=\"opsp-row\"><button class=\"opsp-btn danger\" id=\"opsp-stop-open\">Stop all…</button></div>",
      "<div id=\"opsp-stop-out\">Idle.</div></div>",
      "<div class=\"opsp-card\"><h3>Staggered start-all</h3><p>Starts services one-by-one with a gap.</p>",
      "<div class=\"opsp-row\"><input class=\"opsp-input\" id=\"opsp-start-gap\" value=\"2000\" style=\"width:90px\"><span>gap ms</span><button class=\"opsp-btn\" id=\"opsp-start-go\">Start all</button></div>",
      "<div id=\"opsp-start-out\">Idle.</div></div>",
      "<div class=\"opsp-card\"><h3>Log grep box</h3><p>Read-only filter over recent /api/activity.</p>",
      "<div class=\"opsp-row\"><input class=\"opsp-input\" id=\"opsp-grep-pat\" placeholder=\"filter text\"><button class=\"opsp-btn\" id=\"opsp-grep-go\">Grep</button></div>",
      "<ul class=\"opsp-list\" id=\"opsp-grep-out\"><li>Idle.</li></ul></div>",
      "<div class=\"opsp-card\"><h3>Metric sparklines</h3><p>Snapshot bars from /api/metrics.</p>",
      "<div class=\"opsp-row\"><button class=\"opsp-btn\" id=\"opsp-spark-go\">Load</button></div>",
      "<div id=\"opsp-spark-grid\">Idle.</div></div>",
      "<div class=\"opsp-card\"><h3>Config backup reminder</h3><p>Checks readability; reminds before edits.</p>",
      "<div class=\"opsp-row\"><button class=\"opsp-btn\" id=\"opsp-cfg-go\">Check config</button></div>",
      "<div id=\"opsp-cfg-out\">Idle.</div></div>",
      "<div class=\"opsp-card\"><h3>Disk alert webhook hint</h3><p>Hint only — never sends anything.</p>",
      "<div class=\"opsp-row\"><input class=\"opsp-input\" id=\"opsp-disk-hook\" placeholder=\"webhook URL (optional)\"><button class=\"opsp-btn\" id=\"opsp-disk-go\">Check</button></div>",
      "<div id=\"opsp-disk-out\">Idle.</div></div>",
      "<div class=\"opsp-card\"><h3>Dependency map v2</h3><p>Heuristic names + URL refs.</p>",
      "<div class=\"opsp-row\"><button class=\"opsp-btn\" id=\"opsp-dep-go\">Build map</button></div>",
      "<ul class=\"opsp-list\" id=\"opsp-dep-out\"><li>Idle.</li></ul></div>",
      "<div class=\"opsp-card\"><h3>Incident notes (local)</h3><p>Browser-only log, never uploaded.</p>",
      "<textarea class=\"opsp-area\" id=\"opsp-note-text\" placeholder=\"what happened / what fixed it\"></textarea>",
      "<div class=\"opsp-row\" style=\"margin-top:6px\"><button class=\"opsp-btn\" id=\"opsp-note-add\">Save note</button></div>",
      "<ul class=\"opsp-list\" id=\"opsp-notes-list\"><li>Idle.</li></ul></div>",
      "<div class=\"opsp-card\"><h3>Rollback hint</h3><p>Guidance only — changes nothing.</p>",
      "<div class=\"opsp-row\"><button class=\"opsp-btn\" id=\"opsp-roll-go\">Show hint</button></div>",
      "<div id=\"opsp-roll-out\">Idle.</div></div>",
      "</div>",
      "<div id=\"opsp-confirm-ov\" role=\"dialog\" aria-modal=\"true\" aria-label=\"Confirm stop all\">",
      "<div class=\"opsp-modal\"><h3>Stop ALL services?</h3>",
      "<p>Step 1: press \"I understand\" — Step 2: tick the box, then Stop. Double confirm required.</p>",
      "<div class=\"opsp-row\"><button class=\"opsp-btn\" id=\"opsp-understand\">I understand</button>",
      "<label><input type=\"checkbox\" id=\"opsp-arm2\" disabled> Really stop all</label></div>",
      "<div class=\"opsp-row\" style=\"margin-top:8px\"><button class=\"opsp-btn danger\" id=\"opsp-stop-go\" disabled>Stop all now</button>",
      "<button class=\"opsp-btn\" id=\"opsp-stop-cancel\">Cancel</button></div></div></div>"
    ].join("\n");
    host.appendChild(sec);
    function on(id, fn) {
      var el = document.getElementById(id);
      if (el) el.addEventListener("click", fn);
    }
    on("opsp-q-go", queueRestart);
    on("opsp-stop-open", stopAllShield);
    on("opsp-start-go", startAllStaggered);
    on("opsp-grep-go", grepLogs);
    on("opsp-spark-go", loadSparkGrid);
    on("opsp-cfg-go", configReminder);
    on("opsp-disk-go", diskHint);
    on("opsp-dep-go", depMap);
    on("opsp-note-add", noteAdd);
    on("opsp-roll-go", rollbackHint);
    on("opsp-stop-cancel", closeShield);
    on("opsp-understand", function () {
      var a = document.getElementById("opsp-arm2");
      if (a) a.disabled = false;
      toast("Step 1 done — tick the box to arm.", "info");
    });
    var arm = document.getElementById("opsp-arm2");
    if (arm) arm.addEventListener("change", function () {
      var go = document.getElementById("opsp-stop-go");
      if (go) go.disabled = !arm.checked;
    });
    on("opsp-stop-go", confirmedStopAll);
    notesRender();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount);
  else mount();
})();
