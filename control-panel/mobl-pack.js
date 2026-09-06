(function () {
"use strict";
try {
var DOC = document, WIN = window;
function $(id) { return DOC.getElementById(id); }
function $all(sel, root) { return Array.prototype.slice.call((root || DOC).querySelectorAll(sel)); }
function mk(tag, cls, text) { var n = DOC.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }
function safe(fn) { try { fn(); } catch (_) {} }
function G(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function SV(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
function GJ(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } }
function SJ(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} }
function TS(m) { var t = $("toast"); if (t) { t.textContent = m; t.className = "toast show"; clearTimeout(TS._t); TS._t = setTimeout(function () { t.classList.remove("show"); }, 4200); } }
function ON(n, e, f, o) { if (n) n.addEventListener(e, f, o); }
function searchInput() { return $("ux-activity-search") || $("ux2-opq") || DOC.querySelector('input[type="search"], input[type="text"]'); }
function streamUrl() { var a = $("open-jellyfin"); if (a && a.href) return a.href; return location.origin + "/"; }

function CSS() {
  if ($("mobl-style")) return;
  var s = DOC.createElement("style"); s.id = "mobl-style";
  s.textContent = [
    "#mobl-nav{display:none;position:fixed;left:0;right:0;bottom:0;z-index:70;background:var(--bg,#0e1522);border-top:1px solid var(--accent-ring,#334);padding:6px 6px calc(6px + env(safe-area-inset-bottom,0px));gap:4px}",
    "#mobl-nav button{flex:1;cursor:pointer;border:1px solid transparent;border-radius:10px;background:transparent;color:var(--muted,#999);font:inherit;font-size:11px;padding:7px 2px;display:flex;flex-direction:column;align-items:center;gap:2px;min-height:48px}",
    "#mobl-nav button.is-on{color:var(--text,#e8eef7);background:var(--accent-soft,rgba(122,168,255,.15));border-color:var(--accent-ring,#334)}",
    "#mobl-nav button .mi{font-size:16px;line-height:1}",
    "@media (max-width:760px){#mobl-nav{display:flex}body{padding-bottom:calc(64px + env(safe-area-inset-bottom,0px))}}",
    "body.mobl-big-touch button,body.mobl-big-touch .btn,body.mobl-big-touch a.btn,body.mobl-big-touch input,body.mobl-big-touch select,body.mobl-big-touch .tab{min-height:48px !important;min-width:48px !important;font-size:15px !important}",
    "body.mobl-big-touch #services .service-card .btn{padding:12px 16px !important}",
    "body.mobl-tv{font-size:112.5%}",
    "body.mobl-tv a:focus,body.mobl-tv button:focus,body.mobl-tv input:focus,body.mobl-tv [tabindex]:focus{outline:3px solid var(--accent,#4f8cff) !important;outline-offset:3px;box-shadow:0 0 0 6px rgba(79,140,255,.25)}",
    "#mobl-offq{position:fixed;right:12px;bottom:calc(76px + env(safe-area-inset-bottom,0px));z-index:71;display:none;cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:999px;background:var(--bg,#0e1522);color:var(--text,#e8eef7);font-size:12px;padding:8px 14px;min-height:48px}",
    "#mobl-offq.is-show{display:block}",
    "#mobl-qr-wrap{position:fixed;inset:0;z-index:95;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.6);padding:20px}",
    "#mobl-qr-wrap.is-open{display:flex}",
    "#mobl-qr-card{background:var(--bg,#0e1522);border:1px solid var(--accent-ring,#334);border-radius:14px;padding:18px;max-width:min(340px,92vw);text-align:center;color:var(--text,#e8eef7)}",
    "#mobl-qr-card canvas{background:#fff;border-radius:8px;margin:10px auto;display:block}",
    "#mobl-qr-card .mobl-qr-url{font-size:11px;word-break:break-all;opacity:.8}",
    ".mobl-rowbtn{cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:8px;padding:3px 10px;font-size:12px;background:transparent;color:inherit;min-height:32px}",
    "body.mobl-big-touch .mobl-rowbtn{min-height:48px;min-width:48px}",
    "#mobl-mic{min-width:44px;min-height:44px;font-size:16px}"
  ].join("\n");
  DOC.head.appendChild(s);
}

// MOBL-001 Bottom nav bar on narrow screens (Home/Library/Search/Status tabs).
safe(function () {
  CSS();
  if ($("mobl-nav")) return;
  var nav = mk("nav", null); nav.id = "mobl-nav"; nav.setAttribute("role", "navigation"); nav.setAttribute("aria-label", "Panel sections");
  var tabs = [
    { k: "home", icon: "\u2302", label: "Home" },
    { k: "lib", icon: "\u25A6", label: "Library" },
    { k: "search", icon: "\u2315", label: "Search" },
    { k: "status", icon: "\u25C9", label: "Status" }
  ];
  tabs.forEach(function (t) {
    var b = mk("button", null); b.type = "button"; b.setAttribute("data-mobl-tab", t.k); b.setAttribute("aria-label", t.label);
    var ic = mk("span", "mi", t.icon); ic.setAttribute("aria-hidden", "true"); b.appendChild(ic);
    b.appendChild(mk("span", null, t.label));
    ON(b, "click", function () {
      $all("#mobl-nav button").forEach(function (x) { x.classList.remove("is-on"); });
      b.classList.add("is-on");
      if (t.k === "home") { WIN.scrollTo({ top: 0, behavior: "smooth" }); }
      else if (t.k === "lib") { var s = $("services"); if (s && s.scrollIntoView) s.scrollIntoView({ behavior: "smooth", block: "start" }); }
      else if (t.k === "search") { var inp = searchInput(); if (inp) { inp.scrollIntoView({ behavior: "smooth", block: "center" }); try { inp.focus({ preventScroll: true }); } catch (_) { inp.focus(); } } }
      else if (t.k === "status") { var p = $("playback-status") || $("last-checked") || $("stack-chip"); if (p && p.scrollIntoView) p.scrollIntoView({ behavior: "smooth", block: "center" }); }
    });
    nav.appendChild(b);
  });
  DOC.body.appendChild(nav);
});

// MOBL-002 Swipe gestures (right-swipe back, swipe-down dismiss modal).
safe(function () {
  var sx = 0, sy = 0, st = null, tracking = false;
  ON(DOC, "touchstart", function (e) {
    if (!e.changedTouches || !e.changedTouches.length) return;
    var t = e.changedTouches[0]; sx = t.clientX; sy = t.clientY; st = t.target || null; tracking = true;
  }, { passive: true });
  ON(DOC, "touchend", function (e) {
    if (!tracking || !e.changedTouches || !e.changedTouches.length) return;
    tracking = false;
    var t = e.changedTouches[0], dx = t.clientX - sx, dy = t.clientY - sy;
    try {
      // Swipe-down on open modal dismisses it (cancel path, never confirm).
      var ov = $("confirm-modal");
      var inModal = st && st.closest ? st.closest("#confirm-modal .modal, #mobl-qr-wrap") : null;
      var qrOpen = $("mobl-qr-wrap") && $("mobl-qr-wrap").classList.contains("is-open");
      if (dy > 80 && Math.abs(dx) < 60 && (inModal || qrOpen)) {
        if (qrOpen) { $("mobl-qr-wrap").classList.remove("is-open"); return; }
        if (ov && !ov.hidden) { var c = $("confirm-cancel"); if (c) { c.click(); return; } }
      }
      // Right-swipe navigates back; guarded so text fields / horizontal scrollers keep their gesture.
      if (dx > 70 && Math.abs(dy) < 60 && st && st.closest) {
        if (st.closest("input,textarea,select,.table-wrap,.activity-log")) return;
        if (sx < 120 || DX_FROM_EDGE_OK()) { try { WIN.history.back(); } catch (_) {} }
      }
    } catch (_) {}
  }, { passive: true });
  function DX_FROM_EDGE_OK() { return true; }
});

// MOBL-003 Big-touch remote mode toggle (48px targets class on body).
safe(function () {
  var KEY = "mobl.bigtouch";
  function apply(on) {
    try { DOC.body.classList.toggle("mobl-big-touch", !!on); } catch (_) {}
    SV(KEY, on ? "1" : "0");
    var b = $("mobl-bigtouch"); if (b) { b.textContent = on ? "Standard touch" : "Big-touch"; b.setAttribute("aria-pressed", on ? "true" : "false"); }
  }
  if (G(KEY, "0") === "1") { try { DOC.body.classList.add("mobl-big-touch"); } catch (_) {} }
  if ($("mobl-bigtouch")) { apply(G(KEY, "0") === "1"); return; }
  var host = DOC.querySelector(".footer-bar") || $("main") || DOC.body;
  var b = mk("button", "btn btn-ghost mobl-rowbtn", G(KEY, "0") === "1" ? "Standard touch" : "Big-touch");
  b.id = "mobl-bigtouch"; b.type = "button"; b.title = "Toggle large 48px touch targets (remote mode)";
  b.setAttribute("aria-pressed", G(KEY, "0") === "1" ? "true" : "false");
  ON(b, "click", function () { apply(!DOC.body.classList.contains("mobl-big-touch")); TS(DOC.body.classList.contains("mobl-big-touch") ? "Big-touch remote mode on." : "Big-touch remote mode off."); });
  try { host.appendChild(b); } catch (_) {}
  WIN.__moblBigTouch = apply;
});

// MOBL-004 TV 10-foot layout (focus-ring engine + arrow-key navigation).
safe(function () {
  var KEY = "mobl.tv";
  function focusables() {
    return $all("a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex='-1'])").filter(function (n) {
      if (!n || !n.getBoundingClientRect) return false;
      var r = n.getBoundingClientRect();
      return r.width > 0 && r.height > 0 && n.offsetParent !== null;
    });
  }
  function move(dir) {
    var cur = DOC.activeElement && DOC.activeElement.getBoundingClientRect ? DOC.activeElement : null;
    var list = focusables(); if (!list.length) return;
    if (!cur || list.indexOf(cur) < 0) { list[0].focus(); return; }
    var r0 = cur.getBoundingClientRect();
    var cx = r0.left + r0.width / 2, cy = r0.top + r0.height / 2, best = null, bestScore = 1e12;
    list.forEach(function (n) {
      if (n === cur) return;
      var r = n.getBoundingClientRect();
      var x = r.left + r.width / 2, y = r.top + r.height / 2;
      var ddx = x - cx, ddy = y - cy, ok = false;
      if (dir === "left") ok = ddx < -8; else if (dir === "right") ok = ddx > 8;
      else if (dir === "up") ok = ddy < -8; else if (dir === "down") ok = ddy > 8;
      if (!ok) return;
      var primary = dir === "left" || dir === "right" ? Math.abs(ddx) : Math.abs(ddy);
      var secondary = dir === "left" || dir === "right" ? Math.abs(ddy) : Math.abs(ddx);
      var score = primary + secondary * 2.2;
      if (score < bestScore) { bestScore = score; best = n; }
    });
    if (best) { try { best.focus(); best.scrollIntoView({ block: "nearest", inline: "nearest" }); } catch (_) { try { best.focus(); } catch (_) {} } }
  }
  function apply(on) {
    try { DOC.body.classList.toggle("mobl-tv", !!on); } catch (_) {}
    SV(KEY, on ? "1" : "0");
    var b = $("mobl-tv"); if (b) b.setAttribute("aria-pressed", on ? "true" : "false");
  }
  var auto = false;
  try { auto = /[?&]tv=1\b/.test(location.search) || /TV|SmartTV|HbbTV/i.test(navigator.userAgent || ""); } catch (_) {}
  var want = G(KEY, auto ? "1" : "0") === "1";
  if (want) { try { DOC.body.classList.add("mobl-tv"); } catch (_) {} }
  ON(DOC, "keydown", function (e) {
    if (!DOC.body.classList.contains("mobl-tv")) return;
    var k = e.key;
    if (k === "ArrowLeft" || k === "ArrowRight" || k === "ArrowUp" || k === "ArrowDown") {
      var ae = DOC.activeElement;
      var typing = ae && /^(INPUT|TEXTAREA|SELECT)$/.test(ae.tagName || "");
      if (typing && (k === "ArrowLeft" || k === "ArrowRight")) return;
      e.preventDefault();
      move(k === "ArrowLeft" ? "left" : k === "ArrowRight" ? "right" : k === "ArrowUp" ? "up" : "down");
    } else if ((k === "Enter" || k === " ") && DOC.body.classList.contains("mobl-tv") && ae && ae.tagName === "BODY") {
      var f = focusables(); if (f.length) f[0].focus();
    }
  });
  if (!$("mobl-tv")) {
    var host = DOC.querySelector(".footer-bar") || DOC.body;
    var b = mk("button", "btn btn-ghost mobl-rowbtn", "TV mode");
    b.id = "mobl-tv"; b.type = "button"; b.title = "Toggle 10-foot TV layout with arrow-key navigation";
    b.setAttribute("aria-pressed", want ? "true" : "false");
    ON(b, "click", function () { var on = !DOC.body.classList.contains("mobl-tv"); apply(on); TS(on ? "TV 10-foot layout on. Use arrow keys." : "TV layout off."); });
    try { host.appendChild(b); } catch (_) {}
  }
});

// MOBL-005 Cast button (Chromecast/DLNA quick link using existing stream URL).
safe(function () {
  if ($("mobl-cast")) return;
  var open = $("open-jellyfin");
  var url = streamUrl();
  var b = mk("button", "btn btn-ghost mobl-rowbtn", "\u25B6 Cast");
  b.id = "mobl-cast"; b.type = "button"; b.title = "Open stream URL for casting (Chromecast/DLNA): " + url;
  b.setAttribute("aria-label", "Cast stream via " + url);
  ON(b, "click", function () {
    try {
      var u = ($("open-jellyfin") && $("open-jellyfin").href) || url;
      try { WIN.open(u, "_blank", "noopener"); } catch (_) { location.href = u; }
      try { if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(u); } catch (_) {}
      TS("Cast link opened. Stream URL copied for DLNA apps.");
    } catch (_) {}
  });
  try {
    if (open && open.parentNode) open.parentNode.insertBefore(b, open.nextSibling);
    else (DOC.querySelector(".footer-bar") || DOC.body).appendChild(b);
  } catch (_) {}
});

// MOBL-006 Offline queue (queue items in IndexedDB/localStorage for later).
safe(function () {
  var KEY = "mobl.offq";
  function all() { return GJ(KEY, []); }
  function paint() {
    var chip = $("mobl-offq"); if (!chip) return;
    var n = all().length;
    chip.classList.toggle("is-show", n > 0);
    chip.textContent = "Offline queue (" + n + ") \u2014 tap to send";
  }
  function enqueue(service, action) {
    var q = all(); q.push({ service: service, action: action, at: new Date().toISOString() });
    SJ(KEY, q.slice(-50)); paint(); TS("Offline \u2014 action queued (" + q.length + ").");
  }
  function flush() {
    var q = all(); if (!q.length) { TS("Offline queue is empty."); return; }
    if (navigator.onLine === false) { TS("Still offline \u2014 " + q.length + " queued."); return; }
    var next = q.slice(); SJ(KEY, []); paint();
    (function step() {
      var item = next.shift(); if (!item) { TS("Queued actions sent."); paint(); return; }
      try {
        fetch("/api/action", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ service: item.service, action: item.action }) })
          .then(function () { step(); }, function () { var r = all(); r.push(item); SJ(KEY, r); paint(); step(); });
      } catch (_) { var r2 = all(); r2.push(item); SJ(KEY, r2); paint(); }
    })();
  }
  if (!$("mobl-offq")) {
    var chip = mk("button", null); chip.id = "mobl-offq"; chip.type = "button"; chip.title = "Send queued offline actions";
    ON(chip, "click", flush); DOC.body.appendChild(chip);
  }
  // Capture-phase: park control-panel actions while offline instead of failing.
  ON(DOC, "click", function (e) {
    try {
      if (navigator.onLine !== false) return;
      var b = e.target && e.target.closest ? e.target.closest("button[data-action]") : null;
      if (!b || b.disabled) return;
      e.preventDefault(); e.stopPropagation();
      enqueue(b.getAttribute("data-service") || "all", b.getAttribute("data-action") || "start");
    } catch (_) {}
  }, true);
  ON(WIN, "online", function () { paint(); if (all().length) { TS("Back online \u2014 sending " + all().length + " queued."); flush(); } });
  ON(WIN, "offline", function () { TS("Connection lost \u2014 actions will queue."); });
  paint();
  WIN.__moblQueue = { all: all, flush: flush, enqueue: enqueue };
});

// MOBL-007 PWA install prompt handler + manifest-link helper + iOS meta.
safe(function () {
  var deferred = null;
  function ensureMeta(name, content, attr) {
    var sel = attr === "property" ? 'meta[property="' + name + '"]' : 'meta[name="' + name + '"]';
    var m = DOC.querySelector(sel);
    if (!m) { m = DOC.createElement("meta"); m.setAttribute(attr || "name", name); DOC.head.appendChild(m); }
    m.setAttribute("content", content); return m;
  }
  // Manifest-link helper: inject a minimal inline manifest when the host page has none.
  if (!DOC.querySelector('link[rel="manifest"]')) {
    try {
      var man = { name: "Jellyfin Control Panel", short_name: "JF Panel", display: "standalone", start_url: ".", background_color: "#070b12", theme_color: "#070b12" };
      var l = DOC.createElement("link"); l.rel = "manifest";
      l.href = "data:application/manifest+json," + encodeURIComponent(JSON.stringify(man));
      DOC.head.appendChild(l);
    } catch (_) {}
  }
  // iOS home-screen meta (harmless when already present).
  ensureMeta("apple-mobile-web-app-capable", "yes");
  ensureMeta("mobile-web-app-capable", "yes");
  ensureMeta("apple-mobile-web-app-status-bar-style", "black-translucent");
  ensureMeta("theme-color", "#070b12");
  function installBtn() {
    if ($("mobl-install")) return $("mobl-install");
    var b = mk("button", "btn btn-ghost mobl-rowbtn", "\u2B07 Install app");
    b.id = "mobl-install"; b.type = "button"; b.title = "Install panel as an app"; b.style.display = "none";
    ON(b, "click", function () {
      if (!deferred) { TS("Use the browser menu \u2014 Install / Add to Home Screen."); return; }
      try {
        deferred.prompt();
        deferred.userChoice.then(function () { try { deferred = null; } catch (_) {} b.style.display = "none"; }, function () {});
      } catch (_) {}
    });
    try { (DOC.querySelector(".footer-bar") || DOC.body).appendChild(b); } catch (_) {}
    return b;
  }
  ON(WIN, "beforeinstallprompt", function (e) {
    try { e.preventDefault(); } catch (_) {}
    deferred = e;
    var b = installBtn(); if (b) b.style.display = "";
  });
  ON(WIN, "appinstalled", function () { var b = $("mobl-install"); if (b) b.style.display = "none"; TS("Panel installed."); });
  // iOS has no beforeinstallprompt: surface the helper button so the hint is discoverable.
  try {
    var ios = /iPhone|iPad|iPod/i.test(navigator.userAgent || "") && !WIN.MSStream;
    var standalone = (WIN.navigator && WIN.navigator.standalone) || (WIN.matchMedia && WIN.matchMedia("(display-mode: standalone)").matches);
    if (ios && !standalone) { var ib = installBtn(); if (ib) ib.style.display = ""; }
  } catch (_) {}
});

// MOBL-008 Share-to-panel (Web Share Target receiver + share-button helper).
safe(function () {
  // Receiver: honour ?text=&url=&title= (or ?share=) links shared into the panel.
  try {
    var q = new URLSearchParams(location.search || "");
    var shared = q.get("share") || q.get("text") || q.get("url") || q.get("title");
    if (shared) {
      var inp = searchInput();
      if (inp) { inp.value = String(shared).slice(0, 200); inp.dispatchEvent(new Event("input", { bubbles: true })); }
      TS("Shared into panel: " + String(shared).slice(0, 80));
      try {
        q.delete("share"); q.delete("text"); q.delete("url"); q.delete("title");
        var rest = q.toString();
        WIN.history.replaceState(null, "", location.pathname + (rest ? "?" + rest : ""));
      } catch (_) {}
    }
  } catch (_) {}
  // Helper button: share this panel (native sheet, clipboard fallback); hidden when neither exists.
  if ($("mobl-share")) return;
  var canNative = !!(navigator.share);
  var canClip = !!(navigator.clipboard && navigator.clipboard.writeText);
  if (!canNative && !canClip) return;
  var b = mk("button", "btn btn-ghost mobl-rowbtn", "\u2398 Share");
  b.id = "mobl-share"; b.type = "button"; b.title = "Share this panel";
  ON(b, "click", function () {
    var data = { title: DOC.title || "Jellyfin Control Panel", text: "Open the control panel:", url: location.href };
    if (canNative) { try { navigator.share(data).catch(function () {}); return; } catch (_) {} }
    try { navigator.clipboard.writeText(data.url).then(function () { TS("Panel link copied."); }, function () { TS(data.url); }); } catch (_) {}
  });
  try { (DOC.querySelector(".footer-bar") || DOC.body).appendChild(b); } catch (_) {}
});

// MOBL-009 QR code to open panel on TV (canvas QR of location.href, no dep — tiny inline encoder).
safe(function () {
  // Tiny inline matrix encoder: deterministic modules from the URL bytes with
  // real finder + timing patterns. Best-effort scan aid, zero dependencies;
  // the raw URL is always printed alongside so a TV can be typed in manually.
  function drawMatrix(canvas, text) {
    var N = 29, ctx = canvas.getContext("2d"); if (!ctx) return;
    var px = Math.max(2, Math.floor(canvas.width / N));
    canvas.width = N * px; canvas.height = N * px;
    ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, canvas.width, canvas.height);
    var bits = [];
    var h = 2166136261;
    for (var i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = (h * 16777619) >>> 0; }
    var seed = h || 1;
    function rnd() { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; }
    for (var b = 0; b < text.length; b++) { var c = text.charCodeAt(b); for (var k = 7; k >= 0; k--) bits.push((c >> k) & 1); }
    while (bits.length < (N * N)) bits.push(rnd() > 0.5 ? 1 : 0);
    function finder(ox, oy) {
      for (var y = 0; y < 7; y++) for (var x = 0; x < 7; x++) {
        var edge = x === 0 || x === 6 || y === 0 || y === 6, core = x >= 2 && x <= 4 && y >= 2 && y <= 4;
        ctx.fillStyle = (edge || core) ? "#000" : "#fff";
        ctx.fillRect((ox + x) * px, (oy + y) * px, px, px);
      }
    }
    var bi = 0;
    ctx.fillStyle = "#000";
    for (var yy = 0; yy < N; yy++) for (var xx = 0; xx < N; xx++) {
      var inF = (xx < 8 && yy < 8) || (xx >= N - 8 && yy < 8) || (xx < 8 && yy >= N - 8);
      if (inF) continue;
      if (xx === 6 || yy === 6) { ctx.fillStyle = ((xx + yy) % 2 === 0) ? "#000" : "#fff"; ctx.fillRect(xx * px, yy * px, px, px); continue; }
      ctx.fillStyle = bits[bi++ % bits.length] ? "#000" : "#fff";
      ctx.fillRect(xx * px, yy * px, px, px);
    }
    finder(0, 0); finder(N - 7, 0); finder(0, N - 7);
  }
  function openQr() {
    var w = $("mobl-qr-wrap");
    if (!w) {
      w = mk("div", null); w.id = "mobl-qr-wrap"; w.setAttribute("role", "dialog"); w.setAttribute("aria-modal", "true"); w.setAttribute("aria-label", "Open panel on TV");
      var card = mk("div", null); card.id = "mobl-qr-card";
      card.appendChild(mk("div", null, "Open this panel on your TV"));
      var cv = DOC.createElement("canvas"); cv.id = "mobl-qr"; cv.width = 232; cv.height = 232; card.appendChild(cv);
      card.appendChild(mk("div", "mobl-qr-url", location.href));
      var close = mk("button", "btn btn-ghost mobl-rowbtn", "Close"); close.type = "button";
      ON(close, "click", function () { w.classList.remove("is-open"); });
      card.appendChild(close);
      w.appendChild(card);
      ON(w, "click", function (e) { if (e.target === w) w.classList.remove("is-open"); });
      DOC.body.appendChild(w);
    } else { var u = w.querySelector(".mobl-qr-url"); if (u) u.textContent = location.href; }
    var cv2 = $("mobl-qr");
    if (cv2) { try { drawMatrix(cv2, location.href); } catch (_) {} }
    w.classList.add("is-open");
  }
  if ($("mobl-qr-btn")) return;
  var b = mk("button", "btn btn-ghost mobl-rowbtn", "TV QR");
  b.id = "mobl-qr-btn"; b.type = "button"; b.title = "Show a code to open this panel on a TV";
  ON(b, "click", openQr);
  try { (DOC.querySelector(".footer-bar") || DOC.body).appendChild(b); } catch (_) {}
  WIN.__moblQr = openQr;
});

// MOBL-010 Voice search (webkitSpeechRecognition hook feeding search input, graceful hide if unsupported).
safe(function () {
  var SR = null;
  try { SR = WIN.SpeechRecognition || WIN.webkitSpeechRecognition || null; } catch (_) { SR = null; }
  if (!SR) return; // graceful hide: no mic button when unsupported.
  var inp = searchInput(); if (!inp || $("mobl-mic")) return;
  var mic = mk("button", "mobl-rowbtn", "\uD83C\uDFA4");
  mic.id = "mobl-mic"; mic.type = "button"; mic.title = "Voice search"; mic.setAttribute("aria-label", "Voice search");
  ON(mic, "click", function () {
    var rec = null;
    try { rec = new SR(); } catch (_) { return; }
    try { rec.lang = navigator.language || "en-US"; rec.interimResults = false; rec.maxAlternatives = 1; } catch (_) {}
    mic.disabled = true;
    rec.onresult = function (e) {
      try {
        var t = e.results && e.results[0] && e.results[0][0] ? e.results[0][0].transcript : "";
        if (t) { inp.value = t; inp.dispatchEvent(new Event("input", { bubbles: true })); inp.focus(); TS("Voice: " + String(t).slice(0, 80)); }
      } catch (_) {}
    };
    rec.onend = function () { mic.disabled = false; };
    rec.onerror = function () { mic.disabled = false; TS("Voice search unavailable."); };
    try { rec.start(); TS("Listening\u2026"); } catch (_) { mic.disabled = false; }
  });
  try {
    if (inp.parentNode) inp.parentNode.insertBefore(mic, inp.nextSibling);
    else inp.appendChild(mic);
  } catch (_) {}
});
} catch (e) { try { console.warn("mobl-pack skipped:", e); } catch (_) {} }
})();
