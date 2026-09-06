(function () {
"use strict";
try {
var DOC = document, WIN = window;
function $(id) { return DOC.getElementById(id); }
function $all(sel, root) { return Array.prototype.slice.call((root || DOC).querySelectorAll(sel)); }
function mk(tag, cls, text) { var n = DOC.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }
function safe(fn) { try { fn(); } catch (_) {} }
function onFirstFocusability() { return null; }

// A11Y-001 inject skip link targeting services pane
safe(function () {
  if ($("a11y-skip-services") || DOC.querySelector('a.a11y-skip[href="#services-pane"]')) return;
  var a = mk("a", "a11y-skip", "Skip to services");
  a.id = "a11y-skip-services"; a.href = "#services-pane";
  DOC.body.insertBefore(a, DOC.body.firstChild);
});
// A11Y-002 inject skip link targeting activity log
safe(function () {
  if ($("a11y-skip-activity2") || DOC.querySelector('a.a11y-skip[href="#activity-log-x"]')) return;
  var a = mk("a", "a11y-skip", "Skip to activity log");
  a.id = "a11y-skip-activity2"; a.href = "#activity-log";
  DOC.body.insertBefore(a, DOC.body.firstChild);
});
// A11Y-003 inject skip link targeting footer status
safe(function () {
  if ($("a11y-skip-status")) return;
  var foot = DOC.querySelector(".footer-bar, footer, #last-checked");
  var a = mk("a", "a11y-skip", "Skip to connection status");
  a.id = "a11y-skip-status"; a.href = foot && foot.id ? "#" + foot.id : "#main";
  DOC.body.insertBefore(a, DOC.body.firstChild);
});
// A11Y-004 reveal skip links while keyboard focused
safe(function () {
  $all("a.a11y-skip").forEach(function (a) {
    a.addEventListener("focus", function () { a.classList.add("is-focused"); });
    a.addEventListener("blur", function () { a.classList.remove("is-focused"); });
  });
});
// A11Y-005 ensure main landmark exists for skip targets
safe(function () {
  var m = $("main") || DOC.querySelector("main");
  if (m && !m.hasAttribute("role")) m.setAttribute("role", "main");
  if (m && !m.hasAttribute("aria-label")) m.setAttribute("aria-label", "Control panel main content");
});
// A11Y-006 create dedicated polite live region
safe(function () {
  if ($("a11y-live-polite")) return;
  var n = mk("div", "a11y-sr-only", "");
  n.id = "a11y-live-polite"; n.setAttribute("role", "status"); n.setAttribute("aria-live", "polite");
  DOC.body.appendChild(n);
});
// A11Y-007 create dedicated assertive live region
safe(function () {
  if ($("a11y-live-assertive")) return;
  var n = mk("div", "a11y-sr-only", "");
  n.id = "a11y-live-assertive"; n.setAttribute("role", "alert"); n.setAttribute("aria-live", "assertive");
  DOC.body.appendChild(n);
});
// A11Y-008 polite announce helper with DOM clearing
safe(function () {
  WIN.__a11yAnnounce = function (msg) {
    var n = $("a11y-live-polite"); if (!n) return;
    n.textContent = ""; setTimeout(function () { n.textContent = String(msg); }, 40);
  };
});
// A11Y-009 assertive announce helper for errors
safe(function () {
  WIN.__a11yAnnounceAssertive = function (msg) {
    var n = $("a11y-live-assertive"); if (!n) return;
    n.textContent = ""; setTimeout(function () { n.textContent = String(msg); }, 40);
  };
});
// A11Y-010 mirror fetch pill text into polite announcer
safe(function () {
  var pill = $("fetch-status-pill"); if (!pill || pill.__a11yMirrored) return;
  pill.__a11yMirrored = true; var last = pill.textContent;
  new MutationObserver(function () {
    var t = pill.textContent.trim();
    if (t && t !== last) { last = t; if (WIN.__a11yAnnounce) WIN.__a11yAnnounce("Fetch status: " + t); }
  }).observe(pill, { childList: true, characterData: true, subtree: true });
});
// A11Y-011 mirror stack chip text into polite announcer
safe(function () {
  var chip = $("stack-chip-label") || $("stack-chip"); if (!chip || chip.__a11yMirrored) return;
  chip.__a11yMirrored = true; var last = chip.textContent;
  new MutationObserver(function () {
    var t = chip.textContent.trim();
    if (t && t !== last) { last = t; if (WIN.__a11yAnnounce) WIN.__a11yAnnounce("Stack status: " + t); }
  }).observe(chip, { childList: true, characterData: true, subtree: true });
});
// A11Y-012 throttle rapid announcements to avoid SR spam
safe(function () {
  var lastAt = 0, pending = null;
  var base = WIN.__a11yAnnounce;
  WIN.__a11yAnnounce = function (msg) {
    var now = Date.now();
    if (now - lastAt < 900) { pending = msg; return; }
    lastAt = now; if (base) base(msg);
    setTimeout(function () { if (pending) { var p = pending; pending = null; lastAt = Date.now(); if (base) base(p); } }, 950);
  };
});
// A11Y-013 fallback label for refresh icon button
safe(function () {
  var b = $("refresh-button");
  if (b && !b.getAttribute("aria-label")) b.setAttribute("aria-label", "Refresh status now");
});
// A11Y-014 name service action buttons by service plus action
safe(function () {
  $all("button[data-action][data-service]").forEach(function (b) {
    if (!b.getAttribute("aria-label")) {
      var txt = (b.textContent || "").trim().replace(/\s+/g, " ");
      b.setAttribute("aria-label", (txt || b.getAttribute("data-action") + " service") + " (" + b.getAttribute("data-service") + ")");
    }
  });
});
// A11Y-015 label overlay close buttons per dialog title
safe(function () {
  $all("[data-ux-close], .ux-dialog-head button").forEach(function (b) {
    if (!b.getAttribute("aria-label")) {
      var dlg = b.closest('[role="dialog"]');
      var t = dlg ? (dlg.querySelector("h2") || {}).textContent || "dialog" : "dialog";
      b.setAttribute("aria-label", "Close " + String(t).trim());
    }
  });
});
// A11Y-016 give toast container status semantics
safe(function () {
  var t = $("toast");
  if (t && !t.getAttribute("role")) t.setAttribute("role", "status");
  if (t && !t.getAttribute("aria-live")) t.setAttribute("aria-live", "polite");
});
// A11Y-017 label queued-action remove buttons by position
safe(function () {
  $all("#offline-queue button, .ux-queue button").forEach(function (b, i) {
    if (!b.getAttribute("aria-label") && /remove|dismiss|clear/i.test(b.textContent || "")) {
      b.setAttribute("aria-label", "Remove queued action " + (i + 1));
    }
  });
});
// A11Y-018 hide decorative inline SVGs from assistive tech
safe(function () {
  $all("svg").forEach(function (s) {
    var labelled = s.getAttribute("aria-label") || s.getAttribute("title");
    if (!labelled && !s.hasAttribute("aria-hidden")) s.setAttribute("aria-hidden", "true");
  });
});
// A11Y-019 tag external links for new-tab styling hook
safe(function () {
  $all('a[target="_blank"]').forEach(function (a) { a.classList.add("a11y-ext"); });
});
// A11Y-020 sync disabled state into aria-disabled
safe(function () {
  $all("button[disabled]").forEach(function (b) { b.setAttribute("aria-disabled", "true"); });
  new MutationObserver(function (muts) {
    muts.forEach(function (m) {
      var b = m.target;
      if (b.disabled) b.setAttribute("aria-disabled", "true"); else b.removeAttribute("aria-disabled");
    });
  }).observe(DOC.body, { subtree: true, attributes: true, attributeFilter: ["disabled"] });
});
// A11Y-021 fetch pill fallback status role
safe(function () {
  var p = $("fetch-status-pill");
  if (p && !p.getAttribute("role")) p.setAttribute("role", "status");
});
// A11Y-022 activity log list semantics
safe(function () {
  var log = $("activity-log");
  if (log && !log.getAttribute("role")) log.setAttribute("role", "log");
  if (log && !log.getAttribute("aria-label")) log.setAttribute("aria-label", "Service activity, newest first");
});
// A11Y-023 result counts announced politely
safe(function () {
  ["ux-result-count", "queued-bar-text", "offline-queue-count"].forEach(function (id) {
    var n = $(id);
    if (n && !n.getAttribute("aria-live")) n.setAttribute("aria-live", "polite");
  });
});
// A11Y-024 top progressbar range semantics
safe(function () {
  var tp = $("top-progress");
  if (tp) {
    if (!tp.getAttribute("role")) tp.setAttribute("role", "progressbar");
    if (!tp.getAttribute("aria-valuemin")) tp.setAttribute("aria-valuemin", "0");
    if (!tp.getAttribute("aria-valuemax")) tp.setAttribute("aria-valuemax", "100");
    if (!tp.getAttribute("aria-label")) tp.setAttribute("aria-label", "Loading progress");
  }
});
// A11Y-025 expose busy state during background fetch
safe(function () {
  var m = $("main") || DOC.body;
  new MutationObserver(function () {
    var pill = $("fetch-status-pill");
    var busy = !!pill && /fetching|loading/i.test(pill.textContent || "");
    m.setAttribute("aria-busy", busy ? "true" : "false");
  }).observe(DOC.body, { childList: true, characterData: true, subtree: true });
});
// A11Y-026 wire aria-modal on dialog overlays
safe(function () {
  $all('[id$="-overlay"]').forEach(function (ov) {
    var dlg = ov.querySelector('[role="dialog"]') || ov;
    if (ov.querySelector('[role="dialog"]') && !dlg.hasAttribute("aria-modal")) dlg.setAttribute("aria-modal", "true");
  });
});
// A11Y-027 wire dialog labelledby from visible headings
safe(function () {
  $all('[role="dialog"]').forEach(function (dlg, i) {
    if (!dlg.getAttribute("aria-labelledby")) {
      var h = dlg.querySelector("h1, h2, h3");
      if (h) { if (!h.id) h.id = "a11y-dlg-title-" + i; dlg.setAttribute("aria-labelledby", h.id); }
    }
  });
});
// A11Y-028 wire dialog describedby from hint text
safe(function () {
  $all('[role="dialog"]').forEach(function (dlg, i) {
    if (!dlg.getAttribute("aria-describedby")) {
      var hint = dlg.querySelector(".ux-inline-help, .dlg-sub, p");
      if (hint) { if (!hint.id) hint.id = "a11y-dlg-desc-" + i; dlg.setAttribute("aria-describedby", hint.id); }
    }
  });
});
// A11Y-029 roving tabindex across service cards
safe(function () {
  var cards = $all(".service-card");
  if (cards.length < 2) return;
  cards.forEach(function (c, i) { c.setAttribute("tabindex", i === 0 ? "0" : "-1"); });
  cards.forEach(function (c, i) {
    c.addEventListener("keydown", function (e) {
      var n = null;
      if (e.key === "ArrowDown" || e.key === "ArrowRight") n = cards[(i + 1) % cards.length];
      if (e.key === "ArrowUp" || e.key === "ArrowLeft") n = cards[(i - 1 + cards.length) % cards.length];
      if (n) { e.preventDefault(); cards.forEach(function (x) { x.setAttribute("tabindex", "-1"); }); n.setAttribute("tabindex", "0"); n.focus(); }
    });
  });
});
// A11Y-030 roving tabindex across activity filter chips
safe(function () {
  var chips = $all("#activity-chips button, .act-filter-chip");
  if (chips.length < 2) return;
  var active = chips.findIndex(function (c) { return c.classList.contains("is-active"); });
  chips.forEach(function (c, i) { c.setAttribute("tabindex", i === (active < 0 ? 0 : active) ? "0" : "-1"); });
});
// A11Y-031 arrow-key navigation between filter chips
safe(function () {
  var chips = $all("#activity-chips button, .act-filter-chip");
  chips.forEach(function (c, i) {
    c.addEventListener("keydown", function (e) {
      var n = null;
      if (e.key === "ArrowRight") n = chips[(i + 1) % chips.length];
      if (e.key === "ArrowLeft") n = chips[(i - 1 + chips.length) % chips.length];
      if (n) { e.preventDefault(); chips.forEach(function (x) { x.setAttribute("tabindex", "-1"); }); n.setAttribute("tabindex", "0"); n.focus(); }
    });
  });
});
// A11Y-032 Home End keys jump roving group edges
safe(function () {
  [$all(".service-card"), $all("#activity-chips button, .act-filter-chip")].forEach(function (group) {
    if (group.length < 2) return;
    group.forEach(function (n) {
      n.addEventListener("keydown", function (e) {
        var edge = e.key === "Home" ? group[0] : e.key === "End" ? group[group.length - 1] : null;
        if (edge) { e.preventDefault(); group.forEach(function (x) { x.setAttribute("tabindex", "-1"); }); edge.setAttribute("tabindex", "0"); edge.focus(); }
      });
    });
  });
});
// A11Y-033 arrow navigation across panel toolbar buttons
safe(function () {
  var bars = $all("#ux-toolbar, .global-actions");
  bars.forEach(function (bar) {
    var btns = $all("button, a", bar); if (btns.length < 2) return;
    btns.forEach(function (b, i) {
      b.addEventListener("keydown", function (e) {
        var n = e.key === "ArrowRight" ? btns[(i + 1) % btns.length] : e.key === "ArrowLeft" ? btns[(i - 1 + btns.length) % btns.length] : null;
        if (n) { e.preventDefault(); n.focus(); }
      });
    });
  });
});
// A11Y-034 Escape closes topmost open overlay
safe(function () {
  DOC.addEventListener("keydown", function (e) {
    if (e.key !== "Escape") return;
    var open = $all('[id$="-overlay"]').filter(function (ov) { return !ov.hidden && ov.style.display !== "none" && ov.offsetParent !== null; });
    if (open.length) { var top = open[open.length - 1]; var closer = top.querySelector("[data-ux-close]"); if (closer) closer.click(); else top.hidden = true; }
  });
});
// A11Y-035 Escape clears activity search
safe(function () {
  DOC.addEventListener("keydown", function (e) {
    if (e.key !== "Escape") return;
    var s = $("ux-activity-search");
    if (s && DOC.activeElement === s && s.value) { s.value = ""; s.dispatchEvent(new Event("input", { bubbles: true })); if (WIN.__a11yAnnounce) WIN.__a11yAnnounce("Search cleared."); }
  });
});
// A11Y-036 Escape dismisses hover tooltips
safe(function () {
  DOC.addEventListener("keydown", function (e) {
    if (e.key !== "Escape") return;
    $all(".a11y-tip.is-open, [role='tooltip'].is-open").forEach(function (t) { t.classList.remove("is-open"); t.hidden = true; });
  });
});
// A11Y-037 announce overlay closures for orientation
safe(function () {
  DOC.addEventListener("click", function (e) {
    var c = e.target.closest ? e.target.closest("[data-ux-close]") : null;
    if (c && WIN.__a11yAnnounce) WIN.__a11yAnnounce("Dialog closed.");
  });
});
// A11Y-038 generic Tab focus trap inside open modals
safe(function () {
  DOC.addEventListener("keydown", function (e) {
    if (e.key !== "Tab") return;
    var ov = $all('[role="dialog"]').filter(function (d) { return d.offsetParent !== null; })[0];
    if (!ov) return;
    var f = $all('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])', ov).filter(function (n) { return !n.disabled && n.offsetParent !== null; });
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    if (e.shiftKey && DOC.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && DOC.activeElement === last) { e.preventDefault(); first.focus(); }
  });
});
// A11Y-039 remember trigger to return focus after dialogs
safe(function () {
  WIN.__a11yLastTrigger = null;
  DOC.addEventListener("click", function (e) {
    var opener = e.target.closest ? e.target.closest("[data-ux-open], #ux-palette-btn, [data-action='stop']") : null;
    if (opener) WIN.__a11yLastTrigger = opener;
  }, true);
});
// A11Y-040 restore focus to dialog trigger on close
safe(function () {
  DOC.addEventListener("click", function (e) {
    var c = e.target.closest ? e.target.closest("[data-ux-close]") : null;
    if (c && WIN.__a11yLastTrigger && DOC.contains(WIN.__a11yLastTrigger)) {
      setTimeout(function () { try { WIN.__a11yLastTrigger.focus(); } catch (_) {} }, 30);
    }
  });
});
// A11Y-041 move focus into dialogs when opened
safe(function () {
  new MutationObserver(function (muts) {
    muts.forEach(function (m) {
      $all('[role="dialog"]').forEach(function (dlg) {
        if (dlg.offsetParent !== null && !dlg.__a11yFocused) {
          dlg.__a11yFocused = true;
          var f = dlg.querySelector("input:not([type=checkbox]), button");
          setTimeout(function () { try { (f || dlg).focus(); } catch (_) {} }, 25);
        } else if (dlg.offsetParent === null) { dlg.__a11yFocused = false; }
      });
    });
  }).observe(DOC.body, { subtree: true, attributes: true, attributeFilter: ["style", "hidden", "class"] });
});
// A11Y-042 guard trap so background keeps tab order when shut
safe(function () {
  WIN.__a11yTrapActive = function () { return $all('[role="dialog"]').some(function (d) { return d.offsetParent !== null; }); };
});
// A11Y-043 release background inert marking after close
safe(function () {
  DOC.addEventListener("click", function (e) {
    var c = e.target.closest ? e.target.closest("[data-ux-close]") : null;
    if (!c) return;
    setTimeout(function () {
      if (!WIN.__a11yTrapActive || !WIN.__a11yTrapActive()) {
        ["main", ".services-pane", ".activity-pane"].forEach(function (s) {
          var n = s.charAt(0) === "#" || s === "main" ? DOC.querySelector(s) : DOC.querySelector(s);
          if (n) n.removeAttribute("aria-hidden");
        });
      }
    }, 60);
  });
});
// A11Y-044 detect keyboard modality on Tab key
safe(function () {
  DOC.addEventListener("keydown", function (e) {
    if (e.key === "Tab") DOC.body.classList.add("a11y-kb");
  }, true);
});
// A11Y-045 detect pointer modality on mousedown
safe(function () {
  DOC.addEventListener("mousedown", function () { DOC.body.classList.remove("a11y-kb"); }, true);
});
// A11Y-046 expose focus source attribute for styling hooks
safe(function () {
  DOC.addEventListener("keydown", function (e) { if (e.key === "Tab") DOC.body.setAttribute("data-a11y-focus-source", "keyboard"); }, true);
  DOC.addEventListener("mousedown", function () { DOC.body.setAttribute("data-a11y-focus-source", "pointer"); }, true);
});
// A11Y-047 follow OS reduced-motion preference live
safe(function () {
  var mq = WIN.matchMedia ? WIN.matchMedia("(prefers-reduced-motion: reduce)") : null;
  if (!mq) return;
  var apply = function () { DOC.body.classList.toggle("a11y-reduced-motion", !!mq.matches); DOC.body.setAttribute("data-a11y-motion", mq.matches ? "reduced" : "full"); };
  apply();
  if (mq.addEventListener) mq.addEventListener("change", apply);
});
// A11Y-048 disable smooth scrolling under reduced motion
safe(function () {
  var mq = WIN.matchMedia ? WIN.matchMedia("(prefers-reduced-motion: reduce)") : null;
  if (mq && mq.matches) DOC.documentElement.style.scrollBehavior = "auto";
});
// A11Y-049 expose reduced-motion flag for other packs
safe(function () {
  var mq = WIN.matchMedia ? WIN.matchMedia("(prefers-reduced-motion: reduce)") : null;
  WIN.__a11yReducedMotion = !!(mq && mq.matches);
});
// A11Y-050 pause decorative orbs under reduced motion
safe(function () {
  var mq = WIN.matchMedia ? WIN.matchMedia("(prefers-reduced-motion: reduce)") : null;
  if (mq && mq.matches) DOC.body.classList.add("a11y-reduced-motion");
});
// A11Y-051 fallback accessible name for activity search
safe(function () {
  var s = $("ux-activity-search");
  if (s && !s.getAttribute("aria-label") && !s.getAttribute("aria-labelledby")) s.setAttribute("aria-label", "Search activity log");
});
// A11Y-052 hint association for activity search
safe(function () {
  var s = $("ux-activity-search");
  if (!s || s.getAttribute("aria-describedby")) return;
  var hint = $("ux-search-hint");
  if (!hint) { hint = mk("span", "a11y-sr-only", "Type to filter. Slash focuses, Escape clears."); hint.id = "ux-search-hint"; s.parentElement.appendChild(hint); }
  s.setAttribute("aria-describedby", hint.id);
});
// A11Y-053 label errors-only checkbox accessibly
safe(function () {
  var c = $("activity-errors-only");
  if (c && !c.getAttribute("aria-label")) c.setAttribute("aria-label", "Show errors only");
});
// A11Y-054 fallback names for any unlabeled text inputs
safe(function () {
  $all('input[type="text"], input[type="search"], input:not([type])').forEach(function (inp) {
    if (!inp.getAttribute("aria-label") && !inp.getAttribute("aria-labelledby") && !(inp.id && DOC.querySelector("label[for='" + inp.id + "']"))) {
      inp.setAttribute("aria-label", inp.placeholder || inp.name || "Text input");
    }
  });
});
// A11Y-055 reflect required inputs to assistive tech
safe(function () {
  $all("input[required]").forEach(function (inp) { inp.setAttribute("aria-required", "true"); });
});
// A11Y-056 assertive announcements for toast errors
safe(function () {
  var t = $("toast"); if (!t || t.__a11yErrObs) return;
  t.__a11yErrObs = true; var last = "";
  new MutationObserver(function () {
    var txt = (t.textContent || "").trim();
    if (txt && txt !== last && /fail|error|offline|unreachable|denied/i.test(txt)) {
      last = txt;
      if (WIN.__a11yAnnounceAssertive) WIN.__a11yAnnounceAssertive(txt);
    }
  }).observe(t, { childList: true, characterData: true, subtree: true });
});
// A11Y-057 announce connectivity transitions
safe(function () {
  WIN.addEventListener("offline", function () { if (WIN.__a11yAnnounceAssertive) WIN.__a11yAnnounceAssertive("Connection lost. Actions will queue."); });
  WIN.addEventListener("online", function () { if (WIN.__a11yAnnounce) WIN.__a11yAnnounce("Connection restored."); });
});
// A11Y-058 announce queued-action dispatch results
safe(function () {
  DOC.addEventListener("click", function (e) {
    var b = e.target.closest ? e.target.closest("#queued-run, #offline-retry") : null;
    if (b && WIN.__a11yAnnounce) WIN.__a11yAnnounce("Retrying queued actions.");
  });
});
// A11Y-059 dedicated alert container for form errors
safe(function () {
  if ($("a11y-alerts")) return;
  var n = mk("div", "a11y-sr-only", "");
  n.id = "a11y-alerts"; n.setAttribute("role", "alert");
  DOC.body.appendChild(n);
});
// A11Y-060 dedupe repeated identical error announcements
safe(function () {
  var seen = {}, base = WIN.__a11yAnnounceAssertive;
  WIN.__a11yAnnounceAssertive = function (msg) {
    var k = String(msg), now = Date.now();
    if (seen[k] && now - seen[k] < 4000) return;
    seen[k] = now; if (base) base(msg);
  };
});
// A11Y-061 header scope for shortcut key tables
safe(function () {
  $all("table.ux-keys-table").forEach(function (tbl) {
    $all("th", tbl).forEach(function (th) { if (!th.getAttribute("scope")) th.setAttribute("scope", "col"); });
  });
});
// A11Y-062 captions for shortcut key tables
safe(function () {
  $all("table.ux-keys-table").forEach(function (tbl) {
    if (!tbl.querySelector("caption") && !tbl.getAttribute("aria-label")) {
      var cap = DOC.createElement("caption");
      cap.className = "a11y-sr-only"; cap.textContent = "Keyboard shortcuts grouped by keys and action";
      tbl.insertBefore(cap, tbl.firstChild);
    }
  });
});
// A11Y-063 row scope for first-column row headers
safe(function () {
  $all("table.ux-keys-table").forEach(function (tbl) {
    $all("tbody th", tbl).forEach(function (th) { th.setAttribute("scope", "row"); });
  });
});
// A11Y-064 aria-label fallback where captions hidden
safe(function () {
  $all("table").forEach(function (tbl) {
    if (!tbl.querySelector("caption") && !tbl.getAttribute("aria-label") && !tbl.getAttribute("aria-labelledby")) {
      tbl.setAttribute("aria-label", "Data table");
    }
  });
});
// A11Y-065 demote duplicate h1s to level two semantics
safe(function () {
  var h1s = $all("h1");
  h1s.slice(1).forEach(function (h) { h.setAttribute("aria-level", "2"); h.setAttribute("role", "heading"); });
});
// A11Y-066 link services pane to its heading
safe(function () {
  var pane = DOC.querySelector(".services-pane");
  var h = pane ? pane.querySelector("h2") : null;
  if (pane && h) { if (!h.id) h.id = "a11y-services-heading"; pane.setAttribute("aria-labelledby", h.id); }
});
// A11Y-067 link activity pane to its heading
safe(function () {
  var pane = DOC.querySelector(".activity-pane");
  var h = pane ? pane.querySelector("h2") : null;
  if (pane && h) { if (!h.id) h.id = "a11y-activity-heading"; pane.setAttribute("aria-labelledby", h.id); }
});
// A11Y-068 name external links with destination host
safe(function () {
  $all('a[href^="http"]').forEach(function (a) {
    if (a.getAttribute("aria-label")) return;
    try {
      var host = new URL(a.href).hostname;
      var txt = (a.textContent || "").trim();
      a.setAttribute("aria-label", (txt || "External link") + " (" + host + ", opens in new tab)");
    } catch (_) {}
  });
});
// A11Y-069 append new-tab screen-reader suffix text
safe(function () {
  $all('a[target="_blank"]').forEach(function (a) {
    if (a.querySelector(".a11y-sr-only")) return;
    var s = mk("span", "a11y-sr-only", " (opens in new tab)");
    a.appendChild(s);
  });
});
// A11Y-070 mark active filter chips as current
safe(function () {
  var paint = function () {
    $all("#activity-chips button, .act-filter-chip").forEach(function (c) {
      if (c.classList.contains("is-active")) c.setAttribute("aria-current", "true");
      else c.removeAttribute("aria-current");
    });
  };
  paint();
  new MutationObserver(paint).observe(DOC.body, { subtree: true, attributes: true, attributeFilter: ["class"] });
});
try { if (WIN.__a11yAnnounce) WIN.__a11yAnnounce("Accessibility helpers ready."); } catch (_) {}
} catch (e) { try { console.warn("a11y-pack skipped:", e); } catch (_) {} }
})();
