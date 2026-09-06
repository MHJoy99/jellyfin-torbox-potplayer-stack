"use strict";
(function () {
  var LS = { search: "jellyfin.panel.activity.textSearch", pause: "jellyfin.panel.view.paused", density: "jellyfin.panel.view.density", contrast: "jellyfin.panel.view.contrast", motion: "jellyfin.panel.view.motion", abs: "jellyfin.panel.view.absTime", queue: "jellyfin.panel.offline.queue", tour: "jellyfin.panel.tour.done", offlineDismiss: "jellyfin.panel.offline.dismissed" };
  function lsGet(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) { var n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }
  function announce(msg) { var n = $("ux-announcer"); if (n) { n.textContent = ""; setTimeout(function () { n.textContent = msg; }, 30); } }
  function alertSr(msg) { var n = $("ux-alerts"); if (n) { n.textContent = ""; setTimeout(function () { n.textContent = msg; }, 30); } }
  function toastMsg(msg) { var t = $("toast"); if (t) { t.textContent = msg; t.className = "toast show"; clearTimeout(toastMsg._t); toastMsg._t = setTimeout(function () { t.classList.remove("show"); }, 5200); } else announce(msg); }
  function toastWithAction(msg, label, fn) {
    var t = $("toast"); if (!t) { announce(msg); return; }
    t.textContent = msg; t.className = "toast show has-action";
    if (label) { var b = el("button", "toast-action", label); b.type = "button"; b.addEventListener("click", function () { t.classList.remove("show"); fn && fn(); }); t.appendChild(document.createTextNode(" ")); t.appendChild(b); }
    clearTimeout(toastWithAction._t); toastWithAction._t = setTimeout(function () { t.classList.remove("show"); }, 7000);
  }

  /* Build injected DOM: banners, toolbar, overlays. Keeps index.html diff tiny. */
  function buildDom() {
    var body = document.body;
    var topbar = document.querySelector(".topbar");
    if (!$("offline-banner")) {
      var ob = el("div", "offline-banner"); ob.id = "offline-banner"; ob.setAttribute("role", "alert"); ob.hidden = true;
      ob.appendChild(el("span", "offline-dot")); var s1 = el("span"); s1.innerHTML = "<strong>You are offline.</strong> New actions will be queued and run when you reconnect."; ob.appendChild(s1);
      var qc = el("span", "offline-count", "0 queued"); qc.id = "offline-queue-count"; qc.setAttribute("role", "status"); qc.setAttribute("aria-live", "polite"); ob.appendChild(qc);
      [["offline-view-queue", "View queue", "View queued offline actions"], ["offline-retry", "Retry now", "Retry connection now"], ["offline-dismiss", "Dismiss", "Dismiss offline banner"]].forEach(function (a) { var b = el("button", "ux-btn", a[1]); b.type = "button"; b.id = a[0]; b.setAttribute("aria-label", a[2]); ob.appendChild(b); });
      body.insertBefore(ob, topbar || body.firstChild);
    }
    if (!$("queued-bar")) {
      var qb = el("div", "queued-bar"); qb.id = "queued-bar"; qb.hidden = true;
      var qt = el("span", null, "0 actions queued"); qt.id = "queued-bar-text"; qt.setAttribute("role", "status"); qt.setAttribute("aria-live", "polite"); qb.appendChild(qt);
      [["queued-run", "Run queued", "Run all queued actions now"], ["queued-clear", "Discard", "Discard all queued actions"]].forEach(function (a) { var b = el("button", "ux-btn", a[1]); b.type = "button"; b.id = a[0]; b.setAttribute("aria-label", a[2]); qb.appendChild(b); });
      body.insertBefore(qb, topbar || body.firstChild);
    }
    if (!$("ux-toolbar")) {
      var tb = el("div", "ux-toolbar"); tb.id = "ux-toolbar"; tb.setAttribute("role", "toolbar"); tb.setAttribute("aria-label", "Panel tools");
      var defs = [["ux-palette-btn", "\u2318K Commands", "Open command palette (Control K)", "Command palette (Ctrl+K)", "dialog"], ["ux-shortcuts-btn", "? Shortcuts", "Open keyboard shortcut help (question mark key)", "Keyboard shortcuts (?)", "dialog"], ["ux-tour-btn", "Guided tour", "Start guided tour", "First-run guided tour", null]];
      defs.forEach(function (d) { var b = el("button", "ux-btn", d[1]); b.type = "button"; b.id = d[0]; b.setAttribute("aria-label", d[2]); b.title = d[3]; if (d[4]) b.setAttribute("aria-haspopup", d[4]); tb.appendChild(b); });
      var lab = el("label", "ux-search"); lab.title = "Filter activity by text. Saved automatically. Shortcut: slash.";
      var lens = el("span", null, "\uD83D\uDD0E"); lens.setAttribute("aria-hidden", "true"); lab.appendChild(lens);
      var inp = document.createElement("input"); inp.id = "ux-activity-search"; inp.type = "search"; inp.placeholder = "Search activity (/)"; inp.autocomplete = "off"; inp.setAttribute("aria-label", "Search activity. Shortcut slash."); inp.setAttribute("aria-describedby", "ux-search-hint"); lab.appendChild(inp);
      var clr = el("button", "ux-btn", "\u2715"); clr.type = "button"; clr.id = "ux-search-clear"; clr.setAttribute("aria-label", "Clear activity search"); lab.appendChild(clr); tb.appendChild(lab);
      var rc = el("span", "ux-result-count", "\u2014"); rc.id = "ux-result-count"; rc.setAttribute("role", "status"); rc.setAttribute("aria-live", "polite"); tb.appendChild(rc);
      var sp = el("span", "spacer"); sp.setAttribute("aria-hidden", "true"); tb.appendChild(sp);
      [["ux-pause-btn", "\u23F8 Paused: off", "Pause auto-refresh", "Pause auto-refresh (P). Auto-pauses when the tab is hidden."], ["ux-density-btn", "Density", "Toggle compact density", "Density: comfortable/compact (D)"], ["ux-contrast-btn", "Contrast", "Toggle high contrast mode", "High contrast (C)"], ["ux-motion-btn", "Motion", "Toggle reduced motion", "Reduced motion (M)"], ["ux-timestamps-btn", "Abs time", "Toggle absolute timestamps", "Show absolute timestamps (T)"]].forEach(function (d) { var b = el("button", "ux-btn", d[1]); b.type = "button"; b.id = d[0]; b.setAttribute("aria-label", d[2]); b.title = d[3]; b.setAttribute("aria-pressed", "false"); tb.appendChild(b); });
      var main = $("main") || document.querySelector("main") || document.querySelector(".shell");
      if (main && main.parentElement) main.parentElement.insertBefore(tb, main); else body.insertBefore(tb, body.firstChild);
      var hint = el("p", "ux-inline-help", "Tip: Ctrl+K commands \u00B7 ? shortcuts \u00B7 / search \u00B7 1\u20135 filters \u00B7 E errors-only \u00B7 Esc closes dialogs."); hint.id = "ux-search-hint"; hint.style.cssText = "max-width:1320px;margin:6px auto 0;padding:0 22px;"; tb.parentElement.insertBefore(hint, tb.nextSibling);
    }
    /* ARIA upgrades on existing nodes (additive only). */
    try {
      var tp = $("top-progress"); if (tp && !tp.hasAttribute("role")) { tp.setAttribute("role", "progressbar"); tp.setAttribute("aria-valuemin", "0"); tp.setAttribute("aria-valuemax", "100"); }
      var ga = document.querySelector(".global-actions"); if (ga && !ga.id) ga.id = "global-actions";
      var skip = document.querySelectorAll(".skip-link"); if (skip.length < 3 && ga) { var a = el("a", "skip-link", "Skip to stack actions"); a.href = "#global-actions"; ga.parentElement.insertBefore(a, ga); }
      var sh = document.querySelector(".services-pane h2"); if (sh && !sh.id) { sh.id = "services-heading"; sh.tabIndex = -1; var sp2 = sh.closest("section"); if (sp2) sp2.setAttribute("aria-labelledby", "services-heading"); }
      var ah = document.querySelector(".activity-pane h2"); if (ah && !ah.id) { ah.id = "activity-heading"; ah.tabIndex = -1; var ap = ah.closest("aside"); if (ap) ap.setAttribute("aria-labelledby", "activity-heading"); }
      var ph = document.querySelector(".playback-pane h2"); if (ph && !ph.id) { ph.id = "playback-heading"; ph.tabIndex = -1; }
      var main2 = document.querySelector("main"); if (main2 && !main2.id) main2.id = "main";
      var rb = $("refresh-button"); if (rb) { rb.setAttribute("aria-label", "Refresh status now (shortcut: R)"); rb.title = "Refresh now (R)"; rb.setAttribute("aria-keyshortcuts", "r"); }
      var al = document.querySelector('#activity-log'); if (al) al.setAttribute("aria-label", "Recent activity log");
      var eo = $("activity-errors-only"); if (eo) eo.setAttribute("aria-keyshortcuts", "e");
      var chips = $("activity-chips"); if (chips) chips.setAttribute("aria-label", "Filter activity by source (keys 1 to 5)");
      var sb = document.querySelector(".brand-sub"); if (sb && !$("ux-latency")) { var lat = el("span", null, "\u2014 ms"); lat.id = "ux-latency"; lat.title = "Last successful poll round-trip"; sb.appendChild(document.createTextNode(" \u00B7 ")); sb.appendChild(lat); }
      var fn = document.querySelector(".footer-note"); if (fn && !$("ux-foot-status")) { var fs = el("span", null, "starting\u2026"); fs.id = "ux-foot-status"; fs.setAttribute("role", "status"); fs.setAttribute("aria-live", "polite"); fn.appendChild(document.createTextNode(" \u00B7 ")); fn.appendChild(fs); }
      var fsp = $("fetch-status-pill"); if (fsp) fsp.setAttribute("aria-atomic", "true");
      var sc = $("stack-chip"); if (sc) sc.setAttribute("aria-atomic", "true");
      var t = $("toast"); if (t) t.setAttribute("aria-atomic", "true");
      var stopBtn = document.querySelector('button[data-action="stop"][data-service="all"]'); if (stopBtn && !stopBtn.id) stopBtn.id = "stop-all-btn";
      if (stopBtn) { stopBtn.setAttribute("aria-label", "Stop all services (asks for confirmation)"); stopBtn.title = "Stop every service \u2014 confirmation required"; }
    } catch (_) {}
    /* Bulk bar + empty states injected into services pane. */
    try {
      var svcPane = document.querySelector(".services-pane");
      if (svcPane && !$("ux-bulkbar")) {
        var bb = el("div", "ux-bulkbar"); bb.id = "ux-bulkbar"; bb.setAttribute("role", "group"); bb.setAttribute("aria-label", "Bulk service actions");
        bb.appendChild(el("strong", null, "Bulk:"));
        var bc = el("span", null, "\u2014"); bc.id = "ux-bulk-count"; bc.setAttribute("role", "status"); bc.setAttribute("aria-live", "polite"); bb.appendChild(bc);
        [["start", "Start stopped", "Start every stopped service"], ["restart", "Restart all", "Restart every service"], ["copy", "Copy summary", "Copy service summary to clipboard"]].forEach(function (d) { var b = el("button", "ux-btn", d[1]); b.type = "button"; b.setAttribute("data-ux-bulk", d[0]); b.setAttribute("aria-label", d[2]); bb.appendChild(b); });
        var svcGrid = $("services"); svcPane.insertBefore(bb, svcGrid);
        var se = el("div", "ux-empty"); se.id = "ux-services-empty"; se.hidden = true;
        se.innerHTML = "<strong>No services reported</strong>The panel returned an empty list. This usually means the first poll has not finished yet.";
        var row = el("div", "row"); var rt = el("button", "ux-btn", "Retry now (R)"); rt.type = "button"; rt.id = "ux-services-retry"; row.appendChild(rt);
        var dj = el("a", "ux-btn", "Open Jellyfin directly"); dj.href = "http://127.0.0.1:8096/"; dj.target = "_blank"; dj.rel = "noopener"; row.appendChild(dj); se.appendChild(row);
        svcGrid.parentElement.insertBefore(se, svcGrid.nextSibling);
      }
      var actPane = document.querySelector(".activity-pane");
      if (actPane && !$("ux-logs-empty")) {
        var lleg = actPane.querySelector(".log-legend"); if (lleg && !lleg.querySelector(".ux-inline-help")) { var ih = el("span", "ux-inline-help", "Click any line to copy it."); lleg.appendChild(ih); }
        var paneHint = actPane.querySelector(".pane-hint"); if (paneHint && !$("ux-activity-age")) { var age = el("span", null, "\u2014"); age.id = "ux-activity-age"; paneHint.appendChild(document.createTextNode(" \u00B7 ")); paneHint.appendChild(age); var cvb = el("button", "ux-btn", "Copy visible"); cvb.type = "button"; cvb.id = "ux-copy-visible"; cvb.setAttribute("aria-label", "Copy visible log lines"); paneHint.appendChild(document.createTextNode(" \u00B7 ")); paneHint.appendChild(cvb); }
        var logDetails = actPane.querySelector(".log-details"); var actLog = $("activity-log");
        if (logDetails && actLog) { var le2 = el("div", "ux-empty"); le2.id = "ux-logs-empty"; le2.hidden = true; le2.innerHTML = "<strong>No log lines match</strong><span>Try clearing search or choosing All sources.</span>"; var r2 = el("div", "row"); var rb2 = el("button", "ux-btn", "Reset filters"); rb2.type = "button"; rb2.id = "ux-logs-reset"; r2.appendChild(rb2); le2.appendChild(r2); logDetails.appendChild(le2); }
        var helpText = actPane.querySelector(".log-help-text"); if (helpText && helpText.textContent.indexOf("absolute") < 0) helpText.textContent += " Hover any timestamp for the absolute time; press T to pin absolute times.";
      }
      var footer = document.querySelector(".footer-bar"); if (footer && !$("ux-open-proxy")) { var p1 = el("a", "btn btn-ghost", "Proxy health"); p1.id = "ux-open-proxy"; p1.href = "http://127.0.0.1:8888/health"; p1.target = "_blank"; p1.rel = "noopener"; p1.setAttribute("aria-label", "Open TorBox proxy health in new tab"); footer.appendChild(p1); var p2 = el("a", "btn btn-ghost", "Bridge health"); p2.id = "ux-open-bridge"; p2.href = "http://127.0.0.1:18099/health"; p2.target = "_blank"; p2.rel = "noopener"; p2.setAttribute("aria-label", "Open PotPlayer bridge health in new tab"); footer.appendChild(p2); }
    } catch (_) {}
    /* Overlays + live regions + noscript. */
    if (!$("ux-announcer")) {
      ["ux-alerts|alert", "ux-announcer|status"].forEach(function (p) { var parts = p.split("|"); var n = el("div", "sr-only"); n.id = parts[0]; n.setAttribute("role", parts[1]); if (parts[1] === "status") n.setAttribute("aria-live", "polite"); document.body.appendChild(n); });
    }
    var overlays = [
      ["ux-palette-overlay", "Command palette", "Type to filter \u00B7 \u2191\u2193 navigate \u00B7 Enter run \u00B7 Esc close", '<input id="ux-palette-input" class="ux-palette-input" type="text" placeholder="Start, stop, sync, filter, toggle\u2026" autocomplete="off" role="combobox" aria-expanded="true" aria-controls="ux-palette-list" aria-autocomplete="list" aria-label="Command palette search"><div id="ux-palette-list" role="listbox" aria-label="Commands"></div><div class="ux-empty" id="ux-palette-empty" hidden><strong>No matching commands</strong>Try \u201Cstart\u201D, \u201Csync\u201D, \u201Cerrors\u201D, or \u201Ccontrast\u201D.<div class="row"><button type="button" class="ux-btn" id="ux-palette-reset">Show all</button></div></div>', "<span><kbd class='kbd'>\u2191</kbd><kbd class='kbd'>\u2193</kbd> move</span><span><kbd class='kbd'>Enter</kbd> run</span><span><kbd class='kbd'>Esc</kbd> close</span><span style='margin-left:auto' id='ux-palette-count' role='status' aria-live='polite'></span>"],
      ["ux-shortcuts-overlay", "Keyboard shortcuts", "Press ? anytime \u00B7 Esc closes", "<table class='ux-keys-table'><tr><th scope='col'>Keys</th><th scope='col'>Action</th></tr><tr><td><kbd class='kbd'>Ctrl</kbd>+<kbd class='kbd'>K</kbd></td><td>Open command palette</td></tr><tr><td><kbd class='kbd'>?</kbd></td><td>Open this help</td></tr><tr><td><kbd class='kbd'>/</kbd></td><td>Focus activity search</td></tr><tr><td><kbd class='kbd'>R</kbd></td><td>Refresh status now</td></tr><tr><td><kbd class='kbd'>G</kbd></td><td>Jump to services</td></tr><tr><td><kbd class='kbd'>S</kbd></td><td>Sync TorBox</td></tr><tr><td><kbd class='kbd'>1</kbd>\u2013<kbd class='kbd'>5</kbd></td><td>Activity source filters</td></tr><tr><td><kbd class='kbd'>E</kbd></td><td>Errors-only toggle</td></tr><tr><td><kbd class='kbd'>P</kbd></td><td>Pause / resume auto-refresh</td></tr><tr><td><kbd class='kbd'>D</kbd> <kbd class='kbd'>C</kbd> <kbd class='kbd'>M</kbd> <kbd class='kbd'>T</kbd></td><td>Density, contrast, motion, timestamps</td></tr><tr><td><kbd class='kbd'>Esc</kbd></td><td>Close any dialog</td></tr></table>", "<span>Shortcuts never fire while typing in inputs.</span>"],
      ["ux-confirm-overlay", "Stop all services?", "Confirmation required", "<p style='margin:0 0 8px;'>This stops Jellyfin, proxy, bridge, and both mounts. Playback will interrupt. This is the only destructive bulk action, so it always asks first.</p><p class='ux-inline-help' id='ux-confirm-impact' role='status' aria-live='polite'>Checking service states\u2026</p><label style='display:flex;gap:8px;align-items:center;font-size:13px;'><input type='checkbox' id='ux-confirm-ack' style='accent-color:#f06a6a;width:15px;height:15px;'> I understand playback will stop</label>", "<button type='button' class='ux-btn' data-ux-close aria-label='Cancel stop all'>Cancel (Esc)</button><span style='flex:1'></span><button type='button' class='btn btn-danger' id='ux-confirm-stop' disabled aria-label='Confirm stop all services'>Stop all</button>"],
      ["ux-queue-overlay", "Queued actions", "Stored on this machine only", "<ol id='ux-queue-list' style='margin:0;padding-left:18px;font-size:13px;'></ol><div class='ux-empty' id='ux-queue-empty' hidden><strong>Queue is empty</strong>Actions you press while offline appear here.</div>", "<button type='button' class='ux-btn' id='ux-queue-clear2'>Discard all</button><span style='flex:1'></span><button type='button' class='ux-btn' id='ux-queue-run2'>Run queued now</button>"],
      ["ux-tour-overlay", "Welcome to the panel", "30-second tour", "<div class='ux-steps' aria-hidden='true'><span class='ux-step is-on'></span><span class='ux-step'></span><span class='ux-step'></span></div><p id='ux-tour-text' style='font-size:13.5px;line-height:1.55;margin:0;'></p><label style='display:flex;gap:8px;align-items:center;font-size:12.5px;margin-top:10px;'><input type='checkbox' id='ux-tour-hide' style='accent-color:#4f8cff;'> Don\u2019t show again</label>", "<span id='ux-tour-count' role='status' aria-live='polite'>Step 1 of 3</span><span style='flex:1'></span><button type='button' class='ux-btn' id='ux-tour-back'>Back</button><button type='button' class='ux-btn' id='ux-tour-next'>Next \u2192</button>"]
    ];
    overlays.forEach(function (o) {
      if ($(o[0])) return;
      var ov = el("div", "ux-overlay"); ov.id = o[0]; ov.hidden = true;
      var dlg = el("div", "ux-dialog"); var role = o[0] === "ux-confirm-overlay" ? "alertdialog" : "dialog";
      dlg.setAttribute("role", role); dlg.setAttribute("aria-modal", "true");
      var head = el("div", "ux-dialog-head"); var h2 = el("h2", null, o[1]); h2.id = o[0] + "-title"; dlg.setAttribute("aria-labelledby", h2.id); head.appendChild(h2);
      var sub = el("span", "sub", o[2]); head.appendChild(sub);
      var flex = el("span"); flex.style.flex = "1"; head.appendChild(flex);
      if (o[0] !== "ux-confirm-overlay" && o[0] !== "ux-tour-overlay") { var x = el("button", "ux-btn", "Esc \u2715"); x.type = "button"; x.setAttribute("data-ux-close", ""); x.setAttribute("aria-label", "Close " + o[1].toLowerCase()); head.appendChild(x); }
      if (o[0] === "ux-tour-overlay") { var sk = el("button", "ux-btn", "Skip \u2715"); sk.type = "button"; sk.setAttribute("data-ux-close", ""); sk.setAttribute("aria-label", "Close guided tour"); head.appendChild(sk); }
      if (o[0] === "ux-confirm-overlay") { var cc = el("button", "ux-btn", "Cancel (Esc)"); cc.type = "button"; cc.setAttribute("data-ux-close", ""); cc.setAttribute("aria-label", "Cancel stop all"); var foot0 = el("div", "ux-dialog-foot"); }
      dlg.appendChild(head);
      var bd = el("div", "ux-dialog-body"); bd.innerHTML = o[3]; dlg.appendChild(bd);
      var ft = el("div", "ux-dialog-foot"); ft.innerHTML = o[4]; dlg.appendChild(ft);
      if (o[0] === "ux-confirm-overlay") { var cb2 = el("button", "ux-btn", "Cancel (Esc)"); cb2.type = "button"; cb2.setAttribute("data-ux-close", ""); }
      ov.appendChild(dlg); body.appendChild(ov);
    });
    if (!document.querySelector("noscript")) { var ns = document.createElement("noscript"); ns.innerHTML = "<p>JavaScript powers live health checks. Direct links: Jellyfin :8096, proxy :8888/health, bridge :18099/health.</p>"; body.appendChild(ns); }
  }

  var lastFocus = null;
  function openOverlay(id) {
    var ov = typeof id === "string" ? $(id) : id; if (!ov) return null;
    if (!ov.hidden) return ov;
    lastFocus = document.activeElement;
    ov.hidden = false;
    announce("Dialog opened. Press Escape to close.");
    setTimeout(function () { var f = ov.querySelector("input:not([type=checkbox]), button"); if (f) try { f.focus(); } catch (_) {} }, 20);
    return ov;
  }
  function closeOverlay(ov) {
    if (typeof ov === "string") ov = $(ov); if (!ov) return;
    ov.hidden = true;
    if (lastFocus && document.contains(lastFocus)) try { lastFocus.focus(); } catch (_) {}
    announce("Dialog closed.");
  }
  function wireOverlays() {
    document.querySelectorAll(".ux-overlay").forEach(function (ov) {
      if (ov.dataset.wired) return; ov.dataset.wired = "1";
      ov.addEventListener("mousedown", function (e) { if (e.target === ov) closeOverlay(ov); });
      ov.querySelectorAll("[data-ux-close]").forEach(function (b) { b.addEventListener("click", function () { closeOverlay(ov); }); });
      ov.addEventListener("keydown", function (e) {
        if (e.key === "Tab") {
          var items = Array.prototype.slice.call(ov.querySelectorAll("button, input")).filter(function (x) { return !x.disabled && x.offsetParent !== null; });
          if (!items.length) return; var first = items[0], last = items[items.length - 1];
          if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
          else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
        }
      });
    });
  }

  var COMMANDS = [
    { g: "Services", t: "Start all services", h: "start all", run: function () { clickAction("all", "start"); } },
    { g: "Services", t: "Restart all services", h: "restart all", run: function () { clickAction("all", "restart"); } },
    { g: "Services", t: "Stop all services (confirm)", h: "stop all confirm", run: function () { openConfirm(); } },
    { g: "Services", t: "Start stopped services", h: "bulk start stopped", run: function () { bulkStartStopped(); } },
    { g: "Services", t: "Copy service summary", h: "copy summary clipboard", run: function () { copyServiceSummary(); } },
    { g: "Actions", t: "Sync TorBox now", h: "sync torbox s", run: function () { clickAction("torbox-sync", "sync"); } },
    { g: "Actions", t: "Refresh status now", h: "refresh reload r", run: function () { var b = $("refresh-button"); if (b) b.click(); announce("Refreshing status."); } },
    { g: "Actions", t: "Run queued actions", h: "queue run offline", run: function () { runQueue(); } },
    { g: "Actions", t: "Discard queued actions", h: "queue clear discard", run: function () { clearQueue(); } },
    { g: "Logs", t: "Toggle errors-only", h: "errors only e warn", run: function () { var c = $("activity-errors-only"); if (c) { c.checked = !c.checked; c.dispatchEvent(new Event("change", { bubbles: true })); } } },
    { g: "Logs", t: "Reset log filters", h: "reset clear filters search", run: function () { resetLogFilters(); } },
    { g: "Logs", t: "Copy visible log lines", h: "copy logs clipboard", run: function () { copyVisibleLogs(); } },
    { g: "View", t: "Toggle pause auto-refresh", h: "pause resume p poll", run: function () { togglePause(); } },
    { g: "View", t: "Toggle compact density", h: "density compact d", run: function () { toggleDensity(); } },
    { g: "View", t: "Toggle high contrast", h: "contrast c accessible", run: function () { toggleContrast(); } },
    { g: "View", t: "Toggle reduced motion", h: "motion m animation", run: function () { toggleMotion(); } },
    { g: "View", t: "Toggle absolute timestamps", h: "time absolute t relative", run: function () { toggleAbsTime(); } },
    { g: "View", t: "Open shortcuts help", h: "shortcuts help keys ?", run: function () { openOverlay("ux-shortcuts-overlay"); } },
    { g: "View", t: "Start guided tour", h: "tour onboard help", run: function () { startTour(0); } },
    { g: "Open", t: "Open Jellyfin", h: "open jellyfin watch", run: function () { window.open("http://127.0.0.1:8096/", "_blank", "noopener"); } },
    { g: "Open", t: "Open proxy health", h: "open proxy health 8888", run: function () { window.open("http://127.0.0.1:8888/health", "_blank", "noopener"); } },
    { g: "Open", t: "Open bridge health", h: "open bridge health 18099", run: function () { window.open("http://127.0.0.1:18099/health", "_blank", "noopener"); } }
  ];
  var palIndex = 0, palItems = [];
  function clickAction(service, action) {
    if (navigator.onLine === false) { queueAction(service, action); return; }
    var btn = document.querySelector('button[data-action="' + action + '"][data-service="' + service + '"]');
    if (btn && !btn.disabled) btn.click();
    else { queueAction(service, action); toastWithAction("Panel busy \u2014 action queued.", "View queue", function () { openOverlay("ux-queue-overlay"); renderQueue(); }); }
  }
  function renderPalette(filter) {
    var list = $("ux-palette-list"); if (!list) return;
    var q = String(filter || "").trim().toLowerCase(); var groups = {}; palItems = [];
    COMMANDS.forEach(function (c) { if (q && (c.g + " " + c.t + " " + c.h).toLowerCase().indexOf(q) < 0) return; (groups[c.g] = groups[c.g] || []).push(c); });
    list.innerHTML = "";
    Object.keys(groups).sort().forEach(function (g) {
      var h = el("div", "ux-palette-group", g); list.appendChild(h);
      var ul = el("ul", "ux-palette-list"); list.appendChild(ul);
      groups[g].forEach(function (c) {
        var li = document.createElement("li"); li.setAttribute("role", "option");
        var b = el("button", "ux-palette-item"); b.type = "button";
        var s = el("span", null, c.t); b.appendChild(s); var sm = el("small", null, c.g); b.appendChild(sm);
        b.addEventListener("click", function () { closeOverlay("ux-palette-overlay"); c.run(); });
        li.appendChild(b); ul.appendChild(li); palItems.push({ btn: b, cmd: c });
      });
    });
    palIndex = 0; paintPalActive();
    var empty = $("ux-palette-empty"); if (empty) empty.hidden = palItems.length > 0;
    var cnt = $("ux-palette-count"); if (cnt) cnt.textContent = palItems.length + " commands";
  }
  function paintPalActive() { palItems.forEach(function (p, i) { p.btn.classList.toggle("is-active", i === palIndex); if (i === palIndex) p.btn.setAttribute("aria-selected", "true"); else p.btn.removeAttribute("aria-selected"); }); }
  function openConfirm() {
    var names = []; document.querySelectorAll("#services .service-card[data-service-id] .svc-name").forEach(function (n) { names.push(n.textContent.trim()); });
    var imp = $("ux-confirm-impact"); if (imp) imp.textContent = names.length ? ("Will stop: " + names.join(", ") + ".") : "Service list is still loading \u2014 the action will stop every service.";
    var ack = $("ux-confirm-ack"), go = $("ux-confirm-stop"); if (ack) ack.checked = false; if (go) go.disabled = true;
    openOverlay("ux-confirm-overlay");
  }
  function getQueue() { try { return JSON.parse(lsGet(LS.queue, "[]")); } catch (_) { return []; } }
  function setQueue(q) { lsSet(LS.queue, JSON.stringify(q)); paintQueue(); }
  function queueAction(service, action) {
    var q = getQueue(); q.push({ service: service, action: action, at: new Date().toISOString() });
    setQueue(q);
    toastWithAction("Offline \u2014 queued " + action + " " + service + ".", "View queue", function () { openOverlay("ux-queue-overlay"); renderQueue(); });
    announce("Action queued while offline.");
  }
  function paintQueue() {
    var q = getQueue();
    var a = $("offline-queue-count"); if (a) a.textContent = q.length + " queued";
    var b = $("queued-bar-text"); if (b) b.textContent = q.length + (q.length === 1 ? " action queued" : " actions queued");
    var bar = $("queued-bar"); if (bar) bar.hidden = q.length === 0;
    var banner = $("offline-banner");
    if (banner && navigator.onLine === false && lsGet(LS.offlineDismiss, "0") !== "1") banner.hidden = false;
  }
  function renderQueue() {
    var q = getQueue(); var list = $("ux-queue-list"); var empty = $("ux-queue-empty");
    if (!list) return; list.innerHTML = "";
    q.forEach(function (item, i) {
      var li = el("li", null, item.action + " " + item.service + " \u00B7 " + String(item.at).replace("T", " ").slice(0, 19));
      var rm = el("button", "ux-btn", "Remove"); rm.type = "button"; rm.setAttribute("aria-label", "Remove queued action " + (i + 1));
      rm.addEventListener("click", function () { var nq = getQueue(); nq.splice(i, 1); setQueue(nq); renderQueue(); });
      li.appendChild(document.createTextNode(" ")); li.appendChild(rm); list.appendChild(li);
    });
    if (empty) empty.hidden = q.length > 0;
  }
  function runQueue() {
    var q = getQueue(); if (!q.length) { announce("Queue is empty."); return; }
    if (navigator.onLine === false) { alertSr("Still offline. Queued actions cannot run yet."); return; }
    setQueue([]); renderQueue();
    (function next(i) {
      if (i >= q.length) { announce("Queued actions dispatched."); var b = $("refresh-button"); if (b) b.click(); return; }
      var it = q[i]; var btn = document.querySelector('button[data-action="' + it.action + '"][data-service="' + it.service + '"]');
      if (btn && !btn.disabled) btn.click();
      setTimeout(function () { next(i + 1); }, 900);
    })(0);
  }
  function clearQueue() { setQueue([]); renderQueue(); announce("Queued actions discarded."); }
  function togglePause() { lsSet(LS.pause, lsGet(LS.pause, "0") === "1" ? "0" : "1"); paintPause(); announce(lsGet(LS.pause, "0") === "1" ? "Auto-refresh paused." : "Auto-refresh resumed."); }
  function paintPause() {
    var p = lsGet(LS.pause, "0") === "1"; var b = $("ux-pause-btn");
    if (b) { b.setAttribute("aria-pressed", p ? "true" : "false"); b.textContent = p ? "\u25B6 Paused: on" : "\u23F8 Paused: off"; b.setAttribute("aria-label", p ? "Resume auto-refresh" : "Pause auto-refresh"); }
    var f = $("ux-foot-status"); if (f) f.textContent = p ? "paused \u00B7 manual" : "live \u00B7 auto-refresh";
  }
  function toggleDensity() { var v = document.documentElement.getAttribute("data-density") === "compact" ? "comfortable" : "compact"; document.documentElement.setAttribute("data-density", v); lsSet(LS.density, v); paintDensity(); }
  function paintDensity() { var v = lsGet(LS.density, "comfortable"); document.documentElement.setAttribute("data-density", v); var b = $("ux-density-btn"); if (b) { b.setAttribute("aria-pressed", v === "compact" ? "true" : "false"); b.textContent = v === "compact" ? "Density: compact" : "Density: cozy"; } }
  function toggleContrast() { if (document.documentElement.getAttribute("data-contrast") === "high") { document.documentElement.removeAttribute("data-contrast"); lsSet(LS.contrast, ""); } else { document.documentElement.setAttribute("data-contrast", "high"); lsSet(LS.contrast, "high"); } paintContrast(); }
  function paintContrast() { var v = lsGet(LS.contrast, ""); if (v) document.documentElement.setAttribute("data-contrast", v); var b = $("ux-contrast-btn"); if (b) b.setAttribute("aria-pressed", v === "high" ? "true" : "false"); }
  function toggleMotion() { if (document.documentElement.getAttribute("data-motion") === "reduced") { document.documentElement.removeAttribute("data-motion"); lsSet(LS.motion, ""); } else { document.documentElement.setAttribute("data-motion", "reduced"); lsSet(LS.motion, "reduced"); } paintMotion(); }
  function paintMotion() { var v = lsGet(LS.motion, ""); if (v) document.documentElement.setAttribute("data-motion", v); var b = $("ux-motion-btn"); if (b) b.setAttribute("aria-pressed", v === "reduced" ? "true" : "false"); }
  function toggleAbsTime() { lsSet(LS.abs, lsGet(LS.abs, "0") === "1" ? "0" : "1"); paintAbsTime(); }
  function paintAbsTime() {
    var abs = lsGet(LS.abs, "0") === "1"; var b = $("ux-timestamps-btn"); if (b) { b.setAttribute("aria-pressed", abs ? "true" : "false"); b.textContent = abs ? "Abs time: on" : "Abs time: off"; }
    document.querySelectorAll(".act-item[data-ts]").forEach(function (li) {
      var rel = li.querySelector(".act-rel"), clk = li.querySelector(".act-clock");
      if (abs && clk) { if (rel) rel.style.display = "none"; }
      else if (rel) rel.style.display = "";
    });
  }
  function applySearch() {
    var search = $("ux-activity-search"); var q = search ? search.value.trim().toLowerCase() : "";
    var items = document.querySelectorAll("#activity-log .act-item"); var vis = 0;
    items.forEach(function (li) { var hit = !q || li.textContent.toLowerCase().indexOf(q) >= 0; li.style.display = hit ? "" : "none"; if (hit) vis++; });
    var countN = $("ux-result-count"); if (countN) countN.textContent = items.length ? (q ? vis + " / " + items.length + " shown" : items.length + " lines") : "\u2014";
    var empty = $("ux-logs-empty"); if (empty) empty.hidden = !(items.length && vis === 0);
    var age = $("ux-activity-age"); if (age && items.length) { var ts = items[0].getAttribute("data-ts"); if (ts) age.textContent = "newest " + relMini(Number(ts)); }
    paintAbsTime();
  }
  function relMini(ts) { var s = Math.max(0, Math.round((Date.now() - ts) / 1000)); if (s < 60) return s + "s ago"; var m = Math.floor(s / 60); if (m < 60) return m + "m ago"; return Math.floor(m / 60) + "h ago"; }
  function resetLogFilters() {
    var search = $("ux-activity-search"); if (search) { search.value = ""; lsSet(LS.search, ""); }
    var e = $("activity-errors-only"); if (e && e.checked) { e.checked = false; e.dispatchEvent(new Event("change", { bubbles: true })); }
    var all = document.querySelector('#activity-chips [data-source="all"]'); if (all) all.click();
    applySearch(); announce("Log filters reset.");
  }
  function paintBulkCount() {
    var cards = document.querySelectorAll('#services .service-card[data-service-id]'); var stopped = 0;
    cards.forEach(function (c) { if (c.className.indexOf("st-stopped") >= 0 || c.className.indexOf("st-starting") >= 0) stopped++; });
    var n = $("ux-bulk-count"); if (n) n.textContent = cards.length ? cards.length + " services \u00B7 " + stopped + " need start" : "\u2014";
  }
  function paintEmptyStates() {
    var cards = document.querySelectorAll('#services .service-card[data-service-id]').length;
    var se = $("ux-services-empty"); if (se) se.hidden = cards > 0;
    var items = document.querySelectorAll("#activity-log .act-item").length;
    var le = $("ux-logs-empty"); if (le && items === 0 && !le.hidden) le.hidden = false;
  }
  function bulkStartStopped() {
    var started = 0;
    document.querySelectorAll('#services .service-card[data-service-id]').forEach(function (c) {
      if (c.className.indexOf("st-stopped") >= 0 || c.className.indexOf("st-starting") >= 0) {
        var btn = c.querySelector('button[data-action="start"]');
        if (btn && !btn.disabled) { btn.click(); started++; }
      }
    });
    announce(started ? ("Starting " + started + " stopped services.") : "Nothing stopped \u2014 all services already up.");
    if (!started) toastMsg("All services already running.");
  }
  function copyText(text, okMsg) {
    function done(ok) { toastMsg(ok ? okMsg : "Copy failed."); announce(ok ? okMsg : "Copy failed."); }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
    else { var ta = document.createElement("textarea"); ta.value = text; document.body.appendChild(ta); ta.select(); try { document.execCommand("copy"); done(true); } catch (_) { done(false); } ta.remove(); }
  }
  function copyServiceSummary() {
    var rows = [];
    document.querySelectorAll('#services .service-card[data-service-id]').forEach(function (c) {
      var n = c.querySelector(".svc-name"), d = c.querySelector(".svc-detail"), badge = c.querySelector(".badge");
      rows.push(((n && n.textContent.trim()) || "?") + " \u2014 " + ((badge && badge.textContent.trim()) || "") + " \u2014 " + ((d && d.textContent.trim()) || ""));
    });
    copyText(rows.join("\n") || "No services reported", "Service summary copied");
  }
  function copyVisibleLogs() {
    var rows = []; document.querySelectorAll("#activity-log .act-item").forEach(function (li) { if (li.style.display !== "none") rows.push(li.textContent.trim()); });
    copyText(rows.slice(0, 80).join("\n") || "No visible log lines", rows.length + " log lines copied");
  }
  var STEPS = [
    "Press Ctrl+K for every action: start, restart, sync, filter logs, toggle views. You never have to hunt for buttons.",
    "Hover any timestamp for the absolute time, or press T to pin absolute times. Click any log line to copy it with its timestamp.",
    "Stopping everything always asks first, offline presses queue up, and every toast tells you what to do next. Press ? to see all shortcuts."
  ];
  var tourI = 0;
  function startTour(i) {
    tourI = Math.max(0, Math.min(STEPS.length - 1, i));
    var t = $("ux-tour-text"); if (t) t.textContent = STEPS[tourI];
    var c = $("ux-tour-count"); if (c) c.textContent = "Step " + (tourI + 1) + " of " + STEPS.length;
    document.querySelectorAll(".ux-step").forEach(function (s, j) { s.classList.toggle("is-on", j <= tourI); });
    openOverlay("ux-tour-overlay");
  }
  function paintOffline() {
    var off = navigator.onLine === false; var banner = $("offline-banner");
    if (banner) banner.hidden = !off || lsGet(LS.offlineDismiss, "0") === "1";
    paintQueue();
    if (off) alertSr("You are offline. Actions will be queued.");
    else { lsSet(LS.offlineDismiss, "0"); if (getQueue().length) runQueue(); }
  }
  function wire() {
    wireOverlays();
    var on = function (id, ev, fn) { var n = $(id); if (n && !n.dataset.uxw) { n.dataset.uxw = "1"; n.addEventListener(ev, fn); } };
    on("ux-palette-btn", "click", function () { openOverlay("ux-palette-overlay"); var i = $("ux-palette-input"); if (i) { i.value = ""; renderPalette(""); setTimeout(function () { i.focus(); }, 20); } });
    on("ux-shortcuts-btn", "click", function () { openOverlay("ux-shortcuts-overlay"); });
    on("ux-services-help", "click", function () { openOverlay("ux-shortcuts-overlay"); });
    on("ux-tour-btn", "click", function () { startTour(0); });
    on("ux-pause-btn", "click", togglePause);
    on("ux-density-btn", "click", toggleDensity);
    on("ux-contrast-btn", "click", toggleContrast);
    on("ux-motion-btn", "click", toggleMotion);
    on("ux-timestamps-btn", "click", toggleAbsTime);
    on("ux-search-clear", "click", function () { var s = $("ux-activity-search"); if (s) { s.value = ""; lsSet(LS.search, ""); applySearch(); s.focus(); } });
    on("ux-copy-visible", "click", copyVisibleLogs);
    on("ux-services-retry", "click", function () { var b = $("refresh-button"); if (b) b.click(); });
    on("ux-logs-reset", "click", resetLogFilters);
    on("ux-palette-reset", "click", function () { var i = $("ux-palette-input"); if (i) { i.value = ""; renderPalette(""); i.focus(); } });
    on("ux-tour-next", "click", function () { if (tourI >= STEPS.length - 1) { var h = $("ux-tour-hide"); if (h && h.checked) lsSet(LS.tour, "1"); closeOverlay("ux-tour-overlay"); announce("Tour done. Press ? anytime for help."); } else startTour(tourI + 1); });
    on("ux-tour-back", "click", function () { startTour(tourI - 1); });
    on("queued-run", "click", runQueue); on("ux-queue-run2", "click", runQueue);
    on("queued-clear", "click", clearQueue); on("ux-queue-clear2", "click", clearQueue);
    on("offline-view-queue", "click", function () { openOverlay("ux-queue-overlay"); renderQueue(); });
    on("offline-dismiss", "click", function () { lsSet(LS.offlineDismiss, "1"); $("offline-banner").hidden = true; });
    on("offline-retry", "click", function () { announce("Retrying connection."); var b = $("refresh-button"); if (b) b.click(); });
    on("ux-confirm-stop", "click", function () {
      closeOverlay("ux-confirm-overlay");
      var btn = $("stop-all-btn") || document.querySelector('button[data-action="stop"][data-service="all"]');
      if (btn && !btn.disabled) btn.click();
      toastWithAction("Stopping all services\u2026", "Undo (start all)", function () { clickAction("all", "start"); });
      announce("Stop-all requested. Undo available for seven seconds.");
    });
    on("ux-playback-copy", "click", function () { var f = document.querySelector(".playback-file"); copyText(f ? f.textContent.trim() : "No playlist file", "Playlist filename copied"); });
    var ack = $("ux-confirm-ack"); if (ack && !ack.dataset.uxw) { ack.dataset.uxw = "1"; ack.addEventListener("change", function () { var go = $("ux-confirm-stop"); if (go) go.disabled = !ack.checked; }); }
    var search = $("ux-activity-search");
    if (search && !search.dataset.uxw) { search.dataset.uxw = "1"; search.value = lsGet(LS.search, ""); search.addEventListener("input", function () { lsSet(LS.search, search.value); applySearch(); }); }
    var palInput = $("ux-palette-input");
    if (palInput && !palInput.dataset.uxw) {
      palInput.dataset.uxw = "1";
      palInput.addEventListener("input", function () { renderPalette(palInput.value); });
      palInput.addEventListener("keydown", function (e) {
        if (e.key === "ArrowDown") { e.preventDefault(); palIndex = Math.min(palItems.length - 1, palIndex + 1); paintPalActive(); }
        else if (e.key === "ArrowUp") { e.preventDefault(); palIndex = Math.max(0, palIndex - 1); paintPalActive(); }
        else if (e.key === "Enter") { e.preventDefault(); var p = palItems[palIndex]; closeOverlay("ux-palette-overlay"); if (p) p.cmd.run(); }
      });
    }
    document.querySelectorAll("[data-ux-bulk]").forEach(function (b) {
      if (b.dataset.uxw) return; b.dataset.uxw = "1";
      b.addEventListener("click", function () { var k = b.getAttribute("data-ux-bulk"); if (k === "start") bulkStartStopped(); else if (k === "restart") clickAction("all", "restart"); else if (k === "copy") copyServiceSummary(); });
    });
    /* Stop-all intercept: capture phase, works with other crews' modal too. */
    var stopBtn = $("stop-all-btn") || document.querySelector('button[data-action="stop"][data-service="all"]');
    if (stopBtn && !stopBtn.dataset.uxConfirm) {
      stopBtn.dataset.uxConfirm = "1";
      stopBtn.addEventListener("click", function (e) { e.preventDefault(); e.stopImmediatePropagation(); openConfirm(); }, true);
    }
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") { document.querySelectorAll(".ux-overlay").forEach(function (ov) { if (!ov.hidden) closeOverlay(ov); }); return; }
      if (e.ctrlKey || e.metaKey) { if (String(e.key).toLowerCase() === "k") { e.preventDefault(); openOverlay("ux-palette-overlay"); var i = $("ux-palette-input"); if (i) { i.value = ""; renderPalette(""); setTimeout(function () { i.focus(); }, 20); } } return; }
      var t = e.target; if (t) { var tag = String(t.tagName || "").toLowerCase(); if (tag === "input" || tag === "textarea" || tag === "select" || t.isContentEditable) return; }
      var k = String(e.key || "");
      if (k === "?") { e.preventDefault(); openOverlay("ux-shortcuts-overlay"); }
      else if (k === "/") { e.preventDefault(); var s = $("ux-activity-search"); if (s) s.focus(); }
      else if (k === "g" || k === "G") { var h = $("services-heading"); if (h) { h.focus(); h.scrollIntoView({ block: "start" }); } }
      else if (k === "s" || k === "S") { clickAction("torbox-sync", "sync"); }
      else if (k === "p" || k === "P") { togglePause(); }
      else if (k === "d" || k === "D") { toggleDensity(); }
      else if (k === "c" || k === "C") { toggleContrast(); }
      else if (k === "m" || k === "M") { toggleMotion(); }
      else if (k === "t" || k === "T") { toggleAbsTime(); }
      else if (k >= "1" && k <= "5") { var chips = document.querySelectorAll("#activity-chips .act-filter-chip"); var i2 = Number(k) - 1; if (chips[i2]) chips[i2].click(); }
    });
    window.addEventListener("offline", paintOffline); window.addEventListener("online", paintOffline);
    var al = $("activity-log"); if (al) new MutationObserver(function () { applySearch(); paintBulkCount(); paintEmptyStates(); }).observe(al, { childList: true });
    var sg = $("services"); if (sg) new MutationObserver(function () { paintBulkCount(); paintEmptyStates(); }).observe(sg, { childList: true, subtree: true });
  }
  function init() {
    buildDom(); wire();
    paintDensity(); paintContrast(); paintMotion(); paintPause(); paintQueue(); renderPalette(""); paintOffline(); paintBulkCount();
    if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches && !lsGet(LS.motion, "")) { document.documentElement.setAttribute("data-motion", "reduced"); paintMotion(); }
    if (lsGet(LS.tour, "0") !== "1") setTimeout(function () { if (!$("ux-tour-overlay").hidden) return; startTour(0); }, 1500);
    setInterval(function () { var f = $("ux-foot-status"); if (f && lsGet(LS.pause, "0") !== "1") { var l = $("last-checked-text"); f.textContent = "updated " + (l ? l.textContent : "\u2014"); } }, 5000);
    /* Latency probe label on each successful poll (passive observer). */
    setInterval(function () { var lat = $("ux-latency"); var lc = $("last-checked-text"); if (lat && lc && lc.textContent && lc.textContent !== "\u2014" && lc.textContent !== "stale") lat.textContent = "poll ok"; }, 5000);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
