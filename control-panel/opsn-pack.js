/* opsn-pack.js — Wave-2 additive ops wins (IIFE, guarded, no deps, own style).
 * Real routes only: GET /api/status|health|metrics|config|activity|timeline,
 * POST /api/action (incl. torbox-sync/sync), POST /api/restart (allowlist).
 * Touches no existing files; renders its own dock panel. */
(function () {
  "use strict";
  if (typeof window === "undefined" || typeof document === "undefined") return;
  if (window.__opsnLoaded) return;
  window.__opsnLoaded = true;

  var DOCK_ID = "opsn-panel";
  var STYLE_ID = "opsn-pack-styles";
  var POLL_MS = 20000;
  var LS_BACKUP = "opsn.lastBackup.v1";
  var LS_PEAK = "opsn.cachePeakBytes.v1";
  var LS_RESTART = "opsn.restartAt.v1";
  var RESTART_ALLOW = ["jellyfin", "proxy", "bridge", "gdrive", "torboxmount"];
  var START_ORDER = ["gdrive", "torboxmount", "proxy", "bridge", "jellyfin"];

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c];
    });
  }
  function lsGet(k, fb) {
    try { var v = localStorage.getItem(k); return v == null ? fb : v; }
    catch (_) { return fb; }
  }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
  function lsDel(k) { try { localStorage.removeItem(k); } catch (_) {} }
  function fmtBytes(n) {
    n = Number(n);
    if (!isFinite(n) || n < 0) return "n/a";
    if (n < 1024) return n + " B";
    var u = ["KB", "MB", "GB", "TB"];
    var i = -1;
    do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
    return n.toFixed(1) + " " + u[i];
  }
  function fmtTime(ms) {
    var s = Math.max(0, Math.floor(ms / 1000));
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
    if (h > 0) return h + "h " + m + "m " + r + "s";
    if (m > 0) return m + "m " + r + "s";
    return r + "s";
  }
  function getJSON(url, timeoutMs) {
    var ctrl = null, timer = null;
    try {
      if (typeof AbortController !== "undefined") {
        ctrl = new AbortController();
        timer = setTimeout(function () { try { ctrl.abort(); } catch (_) {} }, timeoutMs || 12000);
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
    }).then(function (r) {
      return r.json().then(function (j) { return { http: r.status, body: j }; });
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

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    var st = document.createElement("style");
    st.id = STYLE_ID;
    st.textContent = [
      "#opsn-panel{position:fixed;right:12px;bottom:12px;z-index:60;width:300px;",
      "background:#10151d;border:1px solid #2a3547;border-radius:10px;color:#dbe4f0;",
      "font:12px/1.45 system-ui,sans-serif;box-shadow:0 8px 28px rgba(0,0,0,.45)}",
      "#opsn-panel header{display:flex;justify-content:space-between;align-items:center;",
      "padding:8px 10px;border-bottom:1px solid #2a3547;font-weight:600}",
      "#opsn-panel .opsn-body{padding:8px 10px;display:grid;gap:8px;max-height:46vh;overflow:auto}",
      "#opsn-panel .opsn-row{background:#161e29;border:1px solid #263145;border-radius:8px;padding:6px 8px}",
      "#opsn-panel .opsn-lbl{color:#9fb0c7;font-size:11px;margin-bottom:4px}",
      "#opsn-panel .opsn-btns{display:flex;flex-wrap:wrap;gap:4px}",
      "#opsn-panel button{background:#223149;color:#dbe4f0;border:1px solid #33445e;border-radius:6px;",
      "padding:3px 8px;font-size:11px;cursor:pointer}",
      "#opsn-panel button:hover{background:#2c3f5c}",
      "#opsn-panel .opsn-bar{height:8px;background:#0b1119;border-radius:5px;overflow:hidden;border:1px solid #2a3547}",
      "#opsn-panel .opsn-fill{height:100%;background:#5aa9ff;width:0%}",
      "#opsn-panel .opsn-chip{display:inline-block;padding:1px 8px;border-radius:20px;font-size:11px}",
      "#opsn-panel input,#opsn-panel select{background:#0b1119;color:#dbe4f0;border:1px solid #33445e;border-radius:6px;padding:2px 6px;font-size:11px}",
      "#opsn-panel .opsn-warn{color:#f0b35c}#opsn-panel .opsn-ok{color:#7dd88a}#opsn-panel .opsn-bad{color:#f06a6a}"
    ].join("\n");
    document.head.appendChild(st);
  }

  function ensureDock() {
    var d = document.getElementById(DOCK_ID);
    if (d) return d;
    d = document.createElement("section");
    d.id = DOCK_ID;
    d.setAttribute("aria-label", "OpsN Wave-2 panel (additive)");
    d.innerHTML =
      "<header><span>OpsN Wave-2</span><span class='opsn-lbl'>additive · real routes only</span></header>" +
      "<div class='opsn-body'>" +
      "<div class='opsn-row' id='opsn-logtail'><div class='opsn-lbl'>Log tail shortcut (client-side filter of GET /api/timeline + /api/activity)</div><div class='opsn-btns' data-opsn='svc-btns'></div><div data-opsn='svc-out'>idle</div></div>" +
      "<div class='opsn-row' id='opsn-disk'><div class='opsn-lbl'>Cache usage bar (torbox_vfs.bytes_used from GET /api/metrics — no disk % exposed)</div><div class='opsn-bar'><div class='opsn-fill' data-opsn='disk-fill'></div></div><div data-opsn='disk-txt'>idle</div></div>" +
      "<div class='opsn-row' id='opsn-mount'><div class='opsn-lbl'>Mount latency chip (round-trip of GET /api/health)</div><div data-opsn='mount-out'>idle</div></div>" +
      "<div class='opsn-row' id='opsn-retry'><div class='opsn-lbl'>Failed-sync retry (existing POST /api/action torbox-sync/sync)</div><div class='opsn-btns'><button type='button' data-opsn='retry-btn'>Retry sync now</button></div><div data-opsn='retry-out'>idle</div></div>" +
      "<div class='opsn-row' id='opsn-queue'><div class='opsn-lbl'>Queue depth (proxy.active_streams from GET /api/metrics)</div><div data-opsn='queue-out'>idle</div></div>" +
      "<div class='opsn-row' id='opsn-backup'><div class='opsn-lbl'>Last-backup timestamp (localStorage only, no endpoint)</div><div data-opsn='backup-out'>idle</div><div class='opsn-btns'><button type='button' data-opsn='backup-btn'>Mark backup now</button></div></div>" +
      "<div class='opsn-row' id='opsn-drift'><div class='opsn-lbl'>Env drift alert (GET /api/config vs live GET /api/health)</div><div data-opsn='drift-out'>idle</div></div>" +
      "<div class='opsn-row' id='opsn-diag'><div class='opsn-lbl'>One-click diag copy (health+status+metrics+config JSON)</div><div class='opsn-btns'><button type='button' data-opsn='diag-btn'>Copy diag JSON</button></div><div data-opsn='diag-out'>idle</div></div>" +
      "<div class='opsn-row' id='opsn-restart'><div class='opsn-lbl'>Scheduled restart countdown (POST /api/restart on fire)</div><div class='opsn-btns'><select data-opsn='restart-svc'></select><input data-opsn='restart-min' type='number' min='1' max='720' value='30' style='width:56px'><button type='button' data-opsn='restart-set'>Set</button><button type='button' data-opsn='restart-clear'>Clear</button></div><div data-opsn='restart-out'>no restart scheduled</div></div>" +
      "<div class='opsn-row' id='opsn-deps'><div class='opsn-lbl'>Dependency chain (hover for start/stop order)</div><div data-opsn='deps-out'>idle</div></div>" +
      "</div>";
    document.body.appendChild(d);
    return d;
  }

  function q(root, sel) { try { return root.querySelector(sel); } catch (_) { return null; } }
  function qa(root, sel) { try { return Array.prototype.slice.call(root.querySelectorAll(sel)); } catch (_) { return []; } }
  function setOut(root, key, html) { var el = q(root, "[data-opsn='" + key + "']"); if (el) el.innerHTML = html; }

  // OPSN-001 per-service log-tail shortcut (client-side filter; GET /api/timeline + GET /api/activity only)
  function initLogTail(root) {
    var box = q(root, "[data-opsn='svc-btns']");
    if (!box || box.dataset.done) return;
    box.dataset.done = "1";
    var svcs = ["proxy", "bridge", "jellyfin", "torboxmount", "gdrive", "sync"];
    svcs.forEach(function (s) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = s;
      b.addEventListener("click", function () {
        setOut(root, "svc-out", "loading " + esc(s) + "…");
        getJSON("/api/timeline?per_page=100", 12000).then(function (tl) {
          return getJSON("/api/activity", 12000).then(function (ac) {
            return { tl: tl, ac: ac };
          }, function () { return { tl: tl, ac: null }; });
        }).then(function (both) {
          var rows = [];
          try {
            var list = both.tl && both.tl.timeline ? both.tl.timeline : (Array.isArray(both.tl) ? both.tl : []);
            rows = rows.concat(list.map(function (e) {
              try { return JSON.stringify(e); } catch (_) { return String(e); }
            }));
          } catch (_) {}
          try {
            var al = both.ac && both.ac.activity ? both.ac.activity : (both.ac && both.ac.timeline ? both.ac.timeline : []);
            if (Array.isArray(al)) rows = rows.concat(al.map(String));
          } catch (_) {}
          var key = s === "torboxmount" ? "torbox" : s;
          var hits = rows.filter(function (line) { return line.toLowerCase().indexOf(key) !== -1; }).slice(-5);
          if (!hits.length) setOut(root, "svc-out", "no recent lines mention <b>" + esc(s) + "</b> (last 100 timeline + activity).");
          else setOut(root, "svc-out", "<b>" + esc(s) + "</b> latest (" + hits.length + "):<br>" + hits.map(function (h) { return esc(h.slice(0, 220)); }).join("<br>"));
        }, function (e) {
          setOut(root, "svc-out", "<span class='opsn-bad'>timeline/activity fetch failed: " + esc(e && e.message || e) + "</span>");
        });
      });
      box.appendChild(b);
    });
  }

  // OPSN-002 disk usage bar from /api/metrics (torbox_vfs.bytes_used; peak-normalised, honestly labelled)
  function refreshDisk(root) {
    getJSON("/api/metrics?light=1", 12000).then(function (m) {
      var vfs = (m && m.torbox_vfs) || {};
      var used = (vfs.bytes_used == null) ? null : Number(vfs.bytes_used);
      if (used == null || !isFinite(used)) {
        setOut(root, "disk-txt", "cache bytes_used: n/a (proxy /metrics unreachable or null)");
        var f0 = q(root, "[data-opsn='disk-fill']"); if (f0) f0.style.width = "0%";
        return;
      }
      var peak = Number(lsGet(LS_PEAK, "0")) || 0;
      if (used > peak) { peak = used; lsSet(LS_PEAK, String(peak)); }
      var pct = peak > 0 ? Math.min(100, Math.round((used / peak) * 100)) : 0;
      var f = q(root, "[data-opsn='disk-fill']"); if (f) f.style.width = pct + "%";
      var extra = "files=" + esc(vfs.files == null ? "n/a" : vfs.files) + " dirs=" + esc(vfs.dirs == null ? "n/a" : vfs.dirs);
      setOut(root, "disk-txt", "cache " + esc(fmtBytes(used)) + " · peak " + esc(fmtBytes(peak)) + " · " + pct + "% of peak · " + extra);
    }, function (e) {
      setOut(root, "disk-txt", "<span class='opsn-bad'>/api/metrics failed: " + esc(e && e.message || e) + "</span>");
    });
  }

  // OPSN-003 mount latency chip (times GET /api/health; reads torboxmount state)
  function refreshMount(root) {
    var t0 = (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now();
    getJSON("/api/health", 12000).then(function (h) {
      var t1 = (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now();
      var ms = Math.round(t1 - t0);
      var svc = h && h.services && h.services.torboxmount ? h.services.torboxmount : null;
      var state = svc ? String(svc.state || "unknown") : "unknown";
      var cls = state === "healthy" ? "opsn-ok" : (state === "stopped" ? "opsn-bad" : "opsn-warn");
      var col = ms < 800 ? "#7dd88a" : (ms < 2000 ? "#f0b35c" : "#f06a6a");
      setOut(root, "mount-out", "<span class='opsn-chip' style='background:" + col + ";color:#10151d'>mount probe " + ms + " ms</span> " +
        "<span class='" + cls + "'>torboxmount: " + esc(state) + "</span><br><span class='opsn-lbl'>" + esc(svc && svc.detail || "") + "</span>");
    }, function (e) {
      setOut(root, "mount-out", "<span class='opsn-bad'>/api/health failed: " + esc(e && e.message || e) + "</span>");
    });
  }

  // OPSN-004 failed-sync retry button (existing sync action: POST /api/action torbox-sync/sync)
  function initRetry(root) {
    var b = q(root, "[data-opsn='retry-btn']");
    if (!b || b.dataset.done) return;
    b.dataset.done = "1";
    b.addEventListener("click", function () {
      setOut(root, "retry-out", "requesting sync…");
      postJSON("/api/action", { service: "torbox-sync", action: "sync" }).then(function (res) {
        var ok = res && res.http === 200 && res.body && res.body.ok !== false;
        setOut(root, "retry-out", ok ? "<span class='opsn-ok'>sync requested: " + esc(res.body.message || "ok") + "</span>"
          : "<span class='opsn-bad'>sync rejected (HTTP " + esc(res.http) + "): " + esc((res.body && (res.body.error || res.body.message)) || "unknown") + "</span>");
        if (ok) toast("Sync requested", "ok"); else toast("Sync retry rejected", "error");
      }, function (e) {
        setOut(root, "retry-out", "<span class='opsn-bad'>sync request failed: " + esc(e && e.message || e) + "</span>");
      });
    });
  }
  function refreshRetryHint(root) {
    getJSON("/api/metrics?light=1", 12000).then(function (m) {
      var sync = (m && m.sync) || {};
      var state = String(sync.state || "unknown");
      var age = sync.age_seconds;
      var hint = state === "healthy" ? "<span class='opsn-ok'>sync healthy</span>" : "<span class='opsn-warn'>sync state: " + esc(state) + " — retry available</span>";
      var cur = q(root, "[data-opsn='retry-out']");
      var txt = cur ? cur.textContent : "";
      if (!txt || txt === "idle" || txt.indexOf("sync") === 0) {
        setOut(root, "retry-out", hint + (age != null ? " · last run age " + esc(String(age)) + "s (GET /api/metrics)" : ""));
      }
    }, function () {});
  }

  // OPSN-005 queue depth indicator (proxy.active_streams from GET /api/metrics)
  function refreshQueue(root) {
    getJSON("/api/metrics?light=1", 12000).then(function (m) {
      var p = (m && m.proxy) || {};
      var a = p.active_streams;
      if (a == null) setOut(root, "queue-out", "active_streams: n/a (logscan fallback — no live queue)");
      else {
        var n = Number(a);
        var lbl = !isFinite(n) ? "n/a" : (n === 0 ? "<span class='opsn-ok'>idle (0 active)</span>" : (n < 5 ? "<span class='opsn-warn'>" + n + " active</span>" : "<span class='opsn-bad'>" + n + " active (busy)</span>"));
        setOut(root, "queue-out", "queue depth ≈ " + lbl + " <span class='opsn-lbl'>(live proxy.active_streams)</span>");
      }
    }, function (e) {
      setOut(root, "queue-out", "<span class='opsn-bad'>/api/metrics failed: " + esc(e && e.message || e) + "</span>");
    });
  }

  // OPSN-006 last-backup timestamp (localStorage only — honestly no endpoint)
  function initBackup(root) {
    var render = function () {
      var v = lsGet(LS_BACKUP, "");
      setOut(root, "backup-out", v ? "last backup marked: <b>" + esc(v) + "</b> (localStorage)" : "no backup marked yet (localStorage empty)");
    };
    render();
    var b = q(root, "[data-opsn='backup-btn']");
    if (b && !b.dataset.done) {
      b.dataset.done = "1";
      b.addEventListener("click", function () {
        var now = new Date().toISOString();
        lsSet(LS_BACKUP, now);
        render();
        toast("Backup timestamp saved locally", "ok");
      });
    }
    root._opsnBackupRender = render;
  }

  // OPSN-007 env drift alert (GET /api/config vs live GET /api/health)
  function refreshDrift(root) {
    getJSON("/api/config", 12000).then(function (cfg) {
      return getJSON("/api/health", 12000).then(function (h) {
        return { cfg: cfg, h: h };
      }, function (e) { return { cfg: cfg, herr: e }; });
    }).then(function (both) {
      if (!both || !both.cfg) { setOut(root, "drift-out", "<span class='opsn-bad'>/api/config unreachable</span>"); return; }
      if (both.herr) { setOut(root, "drift-out", "<span class='opsn-warn'>live /api/health unreachable — cannot compare (config loaded)</span>"); return; }
      var ports = both.cfg.ports || {};
      var svcs = both.h.services || {};
      var map = { proxy: "proxy", bridge: "bridge", jellyfin: "jellyfin" };
      var probs = [];
      Object.keys(map).forEach(function (k) {
        var want = ports[map[k]];
        var live = svcs[k];
        if (want != null && live && live.port != null && Number(want) !== Number(live.port)) {
          probs.push(esc(k) + " port config=" + esc(want) + " live=" + esc(live.port));
        }
        if (live && String(live.state) !== "healthy") probs.push(esc(k) + " live state=" + esc(live.state));
      });
      var cfgT = both.cfg.paths && both.cfg.paths.mount_t;
      var liveM = svcs.torboxmount;
      if (cfgT && liveM && liveM.mount_path && cfgT !== liveM.mount_path) probs.push("mount path config=" + esc(cfgT) + " live=" + esc(liveM.mount_path));
      if (!probs.length) setOut(root, "drift-out", "<span class='opsn-ok'>no drift: config ports/paths match live /api/health</span>");
      else setOut(root, "drift-out", "<span class='opsn-warn'>drift:</span> " + probs.join(" · "));
    }, function (e) {
      setOut(root, "drift-out", "<span class='opsn-bad'>drift check failed: " + esc(e && e.message || e) + "</span>");
    });
  }

  // OPSN-008 one-click diag copy (GET health+status+metrics+config → clipboard JSON)
  function initDiag(root) {
    var b = q(root, "[data-opsn='diag-btn']");
    if (!b || b.dataset.done) return;
    b.dataset.done = "1";
    b.addEventListener("click", function () {
      setOut(root, "diag-out", "collecting…");
      var out = { collected_at: new Date().toISOString(), sources: ["GET /api/health", "GET /api/status?light=1", "GET /api/metrics?light=1", "GET /api/config"] };
      getJSON("/api/health", 12000).then(function (h) { out.health = h; return getJSON("/api/status?light=1", 12000); })
        .then(function (s) { out.status = s; return getJSON("/api/metrics?light=1", 12000); })
        .then(function (m) { out.metrics = m; return getJSON("/api/config", 12000); })
        .then(function (c) {
          out.config = c;
          var txt = JSON.stringify(out, null, 2);
          var done = function (ok) {
            setOut(root, "diag-out", ok ? "<span class='opsn-ok'>diag JSON copied (" + txt.length + " chars)</span>" : "<span class='opsn-warn'>copy blocked — JSON ready in console</span>");
            if (!ok) try { console.log("[opsn-diag]", txt); } catch (_) {}
          };
          if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(txt).then(function () { done(true); }, function () { done(false); });
          else {
            try {
              var ta = document.createElement("textarea");
              ta.value = txt; document.body.appendChild(ta); ta.select();
              var ok2 = document.execCommand("copy"); document.body.removeChild(ta); done(!!ok2);
            } catch (_) { done(false); }
          }
        }, function (e) {
          setOut(root, "diag-out", "<span class='opsn-bad'>diag collect failed: " + esc(e && e.message || e) + "</span>");
        });
    });
  }

  // OPSN-009 scheduled restart countdown display (localStorage target; fires POST /api/restart)
  function initRestart(root) {
    var sel = q(root, "[data-opsn='restart-svc']");
    if (sel && !sel.dataset.done) {
      sel.dataset.done = "1";
      RESTART_ALLOW.forEach(function (s) {
        var o = document.createElement("option");
        o.value = s; o.textContent = s; sel.appendChild(o);
      });
    }
    var setB = q(root, "[data-opsn='restart-set']");
    var clrB = q(root, "[data-opsn='restart-clear']");
    if (setB && !setB.dataset.done) {
      setB.dataset.done = "1";
      setB.addEventListener("click", function () {
        var svc = sel ? sel.value : "proxy";
        var minEl = q(root, "[data-opsn='restart-min']");
        var mins = Math.max(1, Math.min(720, Number(minEl ? minEl.value : 30) || 30));
        if (RESTART_ALLOW.indexOf(svc) === -1) { toast("Unknown restartable service", "error"); return; }
        lsSet(LS_RESTART, JSON.stringify({ service: svc, at: Date.now() + mins * 60000 }));
        tickRestart(root);
        toast("Restart scheduled: " + svc + " in " + mins + "m", "info");
      });
    }
    if (clrB && !clrB.dataset.done) {
      clrB.dataset.done = "1";
      clrB.addEventListener("click", function () { lsDel(LS_RESTART); setOut(root, "restart-out", "no restart scheduled"); });
    }
    if (!root._opsnRestartTimer) {
      root._opsnRestartTimer = setInterval(function () { tickRestart(root); }, 1000);
    }
    tickRestart(root);
  }
  function tickRestart(root) {
    var raw = lsGet(LS_RESTART, "");
    if (!raw) return;
    var obj;
    try { obj = JSON.parse(raw); } catch (_) { lsDel(LS_RESTART); return; }
    if (!obj || !obj.at || RESTART_ALLOW.indexOf(obj.service) === -1) { lsDel(LS_RESTART); return; }
    var left = obj.at - Date.now();
    if (left <= 0) {
      setOut(root, "restart-out", "firing POST /api/restart {" + esc(obj.service) + "}…");
      lsDel(LS_RESTART);
      postJSON("/api/restart", { service: obj.service }).then(function (res) {
        var ok = res && res.http === 200 && res.body && res.body.ok !== false;
        setOut(root, "restart-out", ok ? "<span class='opsn-ok'>restart sent: " + esc(obj.service) + "</span>"
          : "<span class='opsn-bad'>restart rejected (HTTP " + esc(res.http) + "): " + esc((res.body && res.body.error) || "unknown") + "</span>");
      }, function (e) {
        setOut(root, "restart-out", "<span class='opsn-bad'>restart failed: " + esc(e && e.message || e) + "</span>");
      });
      return;
    }
    setOut(root, "restart-out", "restart <b>" + esc(obj.service) + "</b> in <b>" + esc(fmtTime(left)) + "</b> (POST /api/restart on fire)");
  }

  // OPSN-010 dependency chain tooltip (start/stop order from POST /api/action service=all behaviour)
  function initDeps(root) {
    var startTxt = START_ORDER.join(" → ");
    var stopTxt = START_ORDER.slice().reverse().join(" → ");
    setOut(root, "deps-out",
      "<span title='Start order (POST /api/action service=all start): " + esc(startTxt) +
      " — Stop order is reverse: " + esc(stopTxt) + ". Hover = chain.' style='cursor:help;text-decoration:underline dotted'>" +
      "⛓ " + esc(startTxt) + "</span><br><span class='opsn-lbl'>hover for stop order · order matches backend dispatch</span>");
  }

  function refreshAll(root) {
    refreshDisk(root);
    refreshMount(root);
    refreshQueue(root);
    refreshDrift(root);
    refreshRetryHint(root);
  }

  function boot() {
    try {
      ensureStyle();
      var root = ensureDock();
      initLogTail(root);
      initRetry(root);
      initBackup(root);
      initDiag(root);
      initRestart(root);
      initDeps(root);
      refreshAll(root);
      if (!boot._timer) boot._timer = setInterval(function () {
        try { refreshAll(root); } catch (_) {}
      }, POLL_MS);
    } catch (_) {}
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
