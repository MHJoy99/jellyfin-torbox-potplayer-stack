(function () {
"use strict";
try {
var DOC = document, WIN = window;
if (!DOC || !WIN) return;
if (WIN.__mobl2Loaded) return;
WIN.__mobl2Loaded = true;
function $(id) { return DOC.getElementById(id); }
function $all(sel, root) { return Array.prototype.slice.call((root || DOC).querySelectorAll(sel)); }
function mk(tag, cls, text) { var n = DOC.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }
function safe(fn) { try { fn(); } catch (_) {} }
function G(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function SV(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
function TS(m) { var t = $("toast"); if (t) { t.textContent = m; t.className = "toast show"; clearTimeout(TS._t); TS._t = setTimeout(function () { t.classList.remove("show"); }, 3000); } }
function ON(n, e, f, o) { if (n && n.addEventListener) n.addEventListener(e, f, o); }
// MOB2-006 haptic tick via navigator.vibrate guarded.
function buzz(ms) { try { if (WIN.navigator && typeof WIN.navigator.vibrate === "function") WIN.navigator.vibrate(typeof ms === "number" ? ms : 10); } catch (_) {} }
function reducedMotion() { try { return WIN.matchMedia && WIN.matchMedia("(prefers-reduced-motion: reduce)").matches; } catch (_) { return false; } }

function CSS() {
  if ($("mobl2-style")) return;
  var s = DOC.createElement("style"); s.id = "mobl2-style";
  s.textContent = [
    ":root{--mobl2-bg:#0e1522;--mobl2-text:#e8eef7;--mobl2-ring:#334;--mobl2-soft:rgba(122,168,255,.15)}",
    "#mobl2-actionbar{display:none;position:fixed;left:0;right:0;bottom:0;z-index:72;background:var(--mobl2-bg);background:var(--bg,#0e1522);border-top:1px solid var(--mobl2-ring);border-top:1px solid var(--accent-ring,#334);padding:6px 6px calc(6px + env(safe-area-inset-bottom,0px));gap:6px}",
    "#mobl2-actionbar button{flex:1;cursor:pointer;border:1px solid transparent;border-radius:10px;background:transparent;color:var(--muted,#999);font:inherit;font-size:12px;padding:9px 4px;min-height:48px}",
    "#mobl2-actionbar button.is-on{color:var(--mobl2-text);color:var(--text,#e8eef7);background:var(--mobl2-soft);background:var(--accent-soft,rgba(122,168,255,.15))}",
    "#mobl2-thumb{display:none;position:fixed;right:10px;bottom:calc(76px + env(safe-area-inset-bottom,0px));z-index:73;gap:8px}",
    "#mobl2-thumb button{cursor:pointer;border:1px solid var(--mobl2-ring);border:1px solid var(--accent-ring,#334);border-radius:999px;background:var(--mobl2-bg);background:var(--bg,#0e1522);color:var(--mobl2-text);color:var(--text,#e8eef7);font-size:15px;min-width:52px;min-height:52px;padding:8px 12px}",
    "#mobl2-install{display:none;position:fixed;left:10px;right:10px;bottom:calc(76px + env(safe-area-inset-bottom,0px));z-index:74;background:var(--mobl2-bg);background:var(--bg,#0e1522);color:var(--mobl2-text);color:var(--text,#e8eef7);border:1px solid var(--mobl2-ring);border:1px solid var(--accent-ring,#334);border-radius:12px;padding:10px 12px;font-size:13px}",
    "#mobl2-install.is-show{display:block}",
    "#mobl2-install button{cursor:pointer;border:1px solid var(--mobl2-ring);border:1px solid var(--accent-ring,#334);border-radius:8px;background:transparent;color:inherit;padding:8px 12px;min-height:44px}",
    "#mobl2-offline{display:none;position:sticky;top:0;z-index:75;background:#3a2b00;color:#ffe9b0;border-bottom:1px solid #6b5200;font-size:12px;padding:8px 12px;text-align:center}",
    "#mobl2-offline.is-show{display:block}",
    "#mobl2-ptr{display:none;position:fixed;top:0;left:0;right:0;z-index:76;text-align:center;font-size:12px;color:var(--mobl2-text);color:var(--text,#e8eef7);background:var(--mobl2-soft);background:var(--accent-soft,rgba(122,168,255,.15));padding:6px}",
    "#mobl2-ptr.is-show{display:block}",
    "body.mobl2-big button,body.mobl2-big .btn,body.mobl2-big a.btn,body.mobl2-big input,body.mobl2-big select,body.mobl2-big .tab{min-height:48px !important;min-width:48px !important;font-size:15px !important}",
    "@media (max-width:820px){#mobl2-actionbar{display:flex}#mobl2-thumb{display:flex}body{padding-bottom:calc(70px + env(safe-area-inset-bottom,0px))}}",
    "@media (max-width:820px) and (orientation:landscape){#services{display:grid !important;grid-template-columns:1fr 1fr !important;gap:10px !important}}",
    "// MOB2-010 reduced-motion respect.",
    "@media (prefers-reduced-motion:reduce){#mobl2-actionbar,#mobl2-thumb,#mobl2-install,#mobl2-ptr{transition:none !important;animation:none !important;scroll-behavior:auto !important}}"
  ].join("\n");
  (DOC.head || DOC.documentElement).appendChild(s);
}

// MOB2-001 sticky bottom action bar.
safe(function () {
  CSS();
  if ($("mobl2-actionbar")) return;
  var bar = mk("nav", null); bar.id = "mobl2-actionbar"; bar.setAttribute("role", "navigation"); bar.setAttribute("aria-label", "Quick actions");
  var acts = [
    { k: "status", label: "Status", fn: function () { var b = $("ux-refresh") || $("ux2-refresh"); if (b) b.click(); else TS("Status refresh"); } },
    { k: "restart", label: "Restart", fn: function () { var b = $("ux-restart") || $all("[data-restart]").filter(function (n) { return n && n.offsetParent !== null; })[0]; if (b) b.click(); else TS("Restart"); } },
    { k: "open", label: "Open", fn: function () { var a = $("open-jellyfin"); if (a && a.href) { try { WIN.open(a.href, "_blank"); } catch (_) {} } else TS("Open Jellyfin"); } },
    { k: "big", label: "BigTap", fn: function () { var on = DOC.body.classList.toggle("mobl2-big"); try { SV("mobl2-big", on ? "1" : "0"); } catch (_) {} TS(on ? "Large tap targets on" : "Large tap targets off"); } }
  ];
  acts.forEach(function (a) {
    var b = mk("button", null, a.label); b.type = "button"; b.setAttribute("data-mobl2-act", a.k);
    ON(b, "click", function () { buzz(10); b.classList.add("is-on"); setTimeout(function () { b.classList.remove("is-on"); }, 600); safe(a.fn); });
    bar.appendChild(b);
  });
  DOC.body.appendChild(bar);
});

// MOB2-002 swipe-left quick restart.
safe(function () {
  if (WIN.__mobl2Swipe) return; WIN.__mobl2Swipe = true;
  var sx = 0, sy = 0;
  ON(DOC, "touchstart", function (e) { try { var t = e.touches[0]; sx = t.clientX; sy = t.clientY; } catch (_) {} }, { passive: true });
  ON(DOC, "touchend", function (e) {
    try {
      var t = e.changedTouches[0];
      var dx = sx - t.clientX, dy = Math.abs(sy - t.clientY);
      if (dx > 90 && dy < 60) {
        var el = e.target;
        if (el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT")) return;
        buzz(12);
        var b = $("ux-restart");
        if (b) { TS("Swipe-left: restart"); b.click(); }
        else { try { DOC.dispatchEvent(new CustomEvent("mobl2:restart")); } catch (_) {} TS("Swipe-left detected"); }
      }
    } catch (_) {}
  }, { passive: true });
});

// MOB2-003 pull-to-refresh hook.
safe(function () {
  if ($("mobl2-ptr")) return;
  var ptr = mk("div", null, "Pull to refresh…"); ptr.id = "mobl2-ptr"; ptr.setAttribute("aria-live", "polite");
  DOC.body.appendChild(ptr);
  WIN.__mobl2Refresh = function () { try { DOC.dispatchEvent(new CustomEvent("mobl2:refresh")); } catch (_) {} var b = $("ux-refresh"); if (b) b.click(); };
  var startY = 0, pulled = false;
  ON(DOC, "touchstart", function (e) { try { startY = e.touches[0].clientY; } catch (_) {} }, { passive: true });
  ON(DOC, "touchmove", function (e) {
    try {
      var y = e.touches[0].clientY;
      var atTop = (WIN.scrollY || DOC.documentElement.scrollTop || 0) <= 0;
      if (atTop && (y - startY) > 70) { pulled = true; ptr.classList.add("is-show"); }
    } catch (_) {}
  }, { passive: true });
  ON(DOC, "touchend", function () {
    try {
      ptr.classList.remove("is-show");
      if (pulled) { pulled = false; buzz(10); safe(function () { WIN.__mobl2Refresh(); }); }
    } catch (_) {}
  }, { passive: true });
});

// MOB2-004 larger tap targets mode.
safe(function () {
  try { if (G("mobl2-big", "0") === "1") DOC.body.classList.add("mobl2-big"); } catch (_) {}
  try {
    if (WIN.matchMedia && WIN.matchMedia("(pointer:coarse)").matches && G("mobl2-big", "") === "") DOC.body.classList.add("mobl2-big");
  } catch (_) {}
});

// MOB2-005 landscape two-col grid.
safe(function () {
  try { DOC.body.setAttribute("data-mobl2", "1"); } catch (_) {}
});

// MOB2-007 install-prompt card.
safe(function () {
  if ($("mobl2-install")) return;
  if (G("mobl2-install-dismissed", "0") === "1") return;
  var card = mk("div", null); card.id = "mobl2-install"; card.setAttribute("role", "dialog"); card.setAttribute("aria-label", "Install app");
  var p = mk("p", null, "Install this panel: use Share / Add to Home Screen for full-screen one-hand use.");
  var row = mk("div", null);
  var ok = mk("button", null, "Got it"); ok.type = "button";
  var later = mk("button", null, "Dismiss"); later.type = "button";
  ON(ok, "click", function () { buzz(10); card.classList.remove("is-show"); SV("mobl2-install-dismissed", "1"); });
  ON(later, "click", function () { buzz(10); card.classList.remove("is-show"); SV("mobl2-install-dismissed", "1"); });
  row.appendChild(ok); row.appendChild(later);
  card.appendChild(p); card.appendChild(row);
  DOC.body.appendChild(card);
  var shown = false;
  function show() { if (shown) return; shown = true; card.classList.add("is-show"); }
  ON(WIN, "beforeinstallprompt", function () { show(); });
  WIN.__mobl2InstallPrompt = show;
  setTimeout(function () { try { if (WIN.innerWidth <= 820) show(); } catch (_) {} }, 4000);
});

// MOB2-008 offline read-only cache banner.
safe(function () {
  if ($("mobl2-offline")) return;
  var b = mk("div", null, "Offline — read-only cache. Changes will not save."); b.id = "mobl2-offline"; b.setAttribute("role", "status");
  DOC.body.insertBefore(b, DOC.body.firstChild);
  function sync() { try { b.classList.toggle("is-show", WIN.navigator && WIN.navigator.onLine === false); } catch (_) {} }
  ON(WIN, "offline", sync); ON(WIN, "online", sync); sync();
});

// MOB2-009 one-thumb reachable toolbar.
safe(function () {
  if ($("mobl2-thumb")) return;
  var tb = mk("div", null); tb.id = "mobl2-thumb"; tb.setAttribute("role", "toolbar"); tb.setAttribute("aria-label", "Thumb reach");
  var top = mk("button", null, "↑"); top.type = "button"; top.setAttribute("aria-label", "Scroll to top");
  var bot = mk("button", null, "↓"); bot.type = "button"; bot.setAttribute("aria-label", "Scroll to bottom");
  ON(top, "click", function () { buzz(10); try { if (reducedMotion()) WIN.scrollTo(0, 0); else WIN.scrollTo({ top: 0, behavior: "smooth" }); } catch (_) { WIN.scrollTo(0, 0); } });
  ON(bot, "click", function () { buzz(10); try { var h = DOC.documentElement.scrollHeight; if (reducedMotion()) WIN.scrollTo(0, h); else WIN.scrollTo({ top: h, behavior: "smooth" }); } catch (_) {} });
  tb.appendChild(top); tb.appendChild(bot);
  DOC.body.appendChild(tb);
});

} catch (_) {}
})();
