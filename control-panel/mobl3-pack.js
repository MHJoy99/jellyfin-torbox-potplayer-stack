(function () {
"use strict";
try {
var DOC = document, WIN = window;
if (!DOC || !WIN) return;
if (WIN.__mobl3Loaded) return;
WIN.__mobl3Loaded = true;
function $(id) { return DOC.getElementById(id); }
function $all(sel, root) { return Array.prototype.slice.call((root || DOC).querySelectorAll(sel)); }
function mk(tag, cls, text) { var n = DOC.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }
function safe(fn) { try { fn(); } catch (_) {} }
function G(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function SV(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
function TS(m) { var t = $("toast"); if (t) { t.textContent = m; t.className = "toast show"; clearTimeout(TS._t); TS._t = setTimeout(function () { t.classList.remove("show"); }, 3000); } }
function ON(n, e, f, o) { if (n && n.addEventListener) n.addEventListener(e, f, o); }
function buzz(ms) { try { if (WIN.navigator && typeof WIN.navigator.vibrate === "function") WIN.navigator.vibrate(typeof ms === "number" ? ms : 10); } catch (_) {} }

function CSS() {
  if ($("mobl3-style")) return;
  var s = DOC.createElement("style"); s.id = "mobl3-style";
  s.textContent = [
    ":root{--mobl3-bg:#0e1522;--mobl3-text:#e8eef7;--mobl3-ring:#334;--mobl3-soft:rgba(122,168,255,.15)}",
    "#mobl3-bar{display:none;position:fixed;right:10px;top:calc(10px + env(safe-area-inset-top,0px));z-index:78;gap:6px}",
    "#mobl3-bar button{cursor:pointer;border:1px solid var(--mobl3-ring);border:1px solid var(--accent-ring,#334);border-radius:999px;background:var(--mobl3-bg);background:var(--bg,#0e1522);color:var(--mobl3-text);color:var(--text,#e8eef7);font:inherit;font-size:13px;min-width:44px;min-height:44px;padding:8px 10px}",
    "#mobl3-fold{display:none;position:sticky;top:0;z-index:77;text-align:center;font-size:12px;color:var(--mobl3-text);color:var(--text,#e8eef7);background:var(--mobl3-soft);background:var(--accent-soft,rgba(122,168,255,.15));border-bottom:1px solid var(--mobl3-ring);border-bottom:1px solid var(--accent-ring,#334);padding:6px 10px}",
    "#mobl3-fold.is-show{display:block}",
    "#mobl3-hints{display:none;position:fixed;left:10px;bottom:calc(76px + env(safe-area-inset-bottom,0px));z-index:78;gap:6px;flex-wrap:wrap;max-width:70vw}",
    "#mobl3-hints span{border:1px solid var(--mobl3-ring);border:1px solid var(--accent-ring,#334);border-radius:999px;background:var(--mobl3-bg);background:var(--bg,#0e1522);color:var(--mobl3-text);color:var(--text,#e8eef7);font-size:11px;padding:6px 10px;opacity:.92}",
    "#mobl3-ctx{display:none;position:fixed;z-index:89;min-width:180px;background:var(--mobl3-bg);background:var(--bg,#0e1522);color:var(--mobl3-text);color:var(--text,#e8eef7);border:1px solid var(--mobl3-ring);border:1px solid var(--accent-ring,#334);border-radius:12px;padding:6px;box-shadow:0 12px 32px rgba(0,0,0,.45)}",
    "#mobl3-ctx.is-show{display:block}",
    "#mobl3-ctx button{display:block;width:100%;text-align:left;cursor:pointer;border:0;border-radius:8px;background:transparent;color:inherit;font:inherit;font-size:14px;padding:10px 12px;min-height:44px}",
    "body.mobl3-datasaver img,body.mobl3-datasaver video{filter:grayscale(1) brightness(.85) !important}",
    "body.mobl3-datasaver .poster,body.mobl3-datasaver .thumb{content-visibility:auto !important}",
    "body.mobl3-dim::after{content:\"\";position:fixed;inset:0;z-index:60;pointer-events:none;background:rgba(0,0,0,.35)}",
    "// MOB3-010 bottom-sheet modals base.",
    "@media (max-width:820px){#mobl3-bar{display:flex}#mobl3-hints{display:flex}[data-mobl3-sheet]{position:fixed !important;left:0 !important;right:0 !important;bottom:0 !important;top:auto !important;max-height:82vh !important;overflow:auto !important;border-radius:16px 16px 0 0 !important;z-index:88 !important}}",
    "// MOB3-001 tablet 3-col grid.",
    "@media (min-width:821px) and (max-width:1180px){#services.mobl3-tablet,#services{display:grid !important;grid-template-columns:repeat(3,1fr) !important;gap:12px !important}}",
    "// MOB3-002 foldable dual-pane hint.",
    "@media (horizontal-viewport-segments:2){body.mobl3-fold #services{display:grid !important;grid-template-columns:1fr 1fr !important;gap:12px !important}#mobl3-fold{display:block}}",
    "@media (prefers-reduced-motion:reduce){#mobl3-bar,#mobl3-hints,#mobl3-ctx,[data-mobl3-sheet]{transition:none !important;animation:none !important;scroll-behavior:auto !important}}"
  ].join("\n");
  (DOC.head || DOC.documentElement).appendChild(s);
}
safe(CSS);

// MOB3-001 tablet 3-col grid.
safe(function () {
  try {
    var w = WIN.innerWidth || 0;
    if (w >= 821 && w <= 1180) {
      var s = $("services");
      if (s) s.classList.add("mobl3-tablet");
      DOC.body.classList.add("mobl3-tablet");
    }
    DOC.body.setAttribute("data-mobl3", "1");
  } catch (_) {}
});

// MOB3-002 foldable dual-pane hint.
safe(function () {
  if ($("mobl3-fold")) return;
  var bar = mk("div", null, "Foldable dual-pane: unfold for side-by-side panels."); bar.id = "mobl3-fold"; bar.setAttribute("role", "status");
  DOC.body.insertBefore(bar, DOC.body.firstChild);
  function sync() {
    var fold = false;
    try { fold = !!(WIN.visualViewport && WIN.innerWidth && WIN.screen && Math.abs(WIN.innerWidth - (WIN.screen.width || 0)) > 200); } catch (_) {}
    try {
      var segs = (WIN.visualViewport && WIN.visualViewport.segments) || (WIN.getWindowSegments ? WIN.getWindowSegments() : null);
      if (segs && segs.length > 1) fold = true;
    } catch (_) {}
    try {
      if (WIN.matchMedia && WIN.matchMedia("(horizontal-viewport-segments: 2)").matches) fold = true;
    } catch (_) {}
    DOC.body.classList.toggle("mobl3-fold", !!fold);
    bar.classList.toggle("is-show", !!fold);
  }
  ON(WIN, "resize", sync); ON(WIN, "orientationchange", sync); sync();
  WIN.__mobl3FoldSync = sync;
});

// MOB3-003 voice search hook.
safe(function () {
  if ($("mobl3-voice")) return;
  var bar = $("mobl3-bar");
  if (!bar) {
    bar = mk("div", null); bar.id = "mobl3-bar"; bar.setAttribute("role", "toolbar"); bar.setAttribute("aria-label", "Mobile quick tools");
    DOC.body.appendChild(bar);
  }
  var b = mk("button", null, "\uD83C\uDFA4"); b.id = "mobl3-voice"; b.type = "button"; b.setAttribute("aria-label", "Voice search"); b.title = "Voice search";
  ON(b, "click", function () {
    buzz(10);
    try {
      var SR = WIN.SpeechRecognition || WIN.webkitSpeechRecognition;
      if (!SR) { TS("Voice search not supported"); try { DOC.dispatchEvent(new CustomEvent("mobl3:voice-unsupported")); } catch (_) {} return; }
      var rec = new SR();
      rec.lang = "en-US"; rec.interimResults = false; rec.maxAlternatives = 1;
      rec.onresult = function (ev) {
        try {
          var txt = ev.results[0][0].transcript || "";
          try { DOC.dispatchEvent(new CustomEvent("mobl3:voice", { detail: { text: txt } })); } catch (_) {}
          var q = $("ux-search") || $("ux2-search") || DOC.querySelector('input[type="search"],input[name="q"]');
          if (q) { q.value = txt; try { q.dispatchEvent(new Event("input", { bubbles: true })); } catch (_) {} }
          TS("Heard: " + txt);
        } catch (_) {}
      };
      rec.onerror = function () { TS("Voice search failed"); };
      rec.start();
    } catch (_) { TS("Voice search failed"); }
  });
  bar.appendChild(b);
});

// MOB3-004 share-target receive.
safe(function () {
  try {
    var q = new WIN.URLSearchParams(WIN.location.search || "");
    var title = q.get("share-title") || q.get("title") || "";
    var text = q.get("share-text") || q.get("text") || "";
    var url = q.get("share-url") || q.get("url") || "";
    if (!title && !text && !url) return;
    var msg = "Shared: " + (title || text || url);
    try { SV("mobl3-last-share", JSON.stringify({ title: title, text: text, url: url })); } catch (_) {}
    try { DOC.dispatchEvent(new CustomEvent("mobl3:share", { detail: { title: title, text: text, url: url } })); } catch (_) {}
    TS(msg.slice(0, 120));
  } catch (_) {}
});

// MOB3-005 fullscreen toggle btn.
safe(function () {
  var bar = $("mobl3-bar") || (function () { var n = mk("div", null); n.id = "mobl3-bar"; DOC.body.appendChild(n); return n; })();
  if ($("mobl3-fs")) return;
  var b = mk("button", null, "\u26F6"); b.id = "mobl3-fs"; b.type = "button"; b.setAttribute("aria-label", "Toggle fullscreen"); b.title = "Fullscreen";
  ON(b, "click", function () {
    buzz(10);
    safe(function () {
      var el = DOC.documentElement;
      var fs = DOC.fullscreenElement || DOC.webkitFullscreenElement;
      if (fs) { if (DOC.exitFullscreen) DOC.exitFullscreen(); else if (DOC.webkitExitFullscreen) DOC.webkitExitFullscreen(); }
      else { if (el.requestFullscreen) el.requestFullscreen(); else if (el.webkitRequestFullscreen) el.webkitRequestFullscreen(); }
      try { DOC.dispatchEvent(new CustomEvent("mobl3:fullscreen")); } catch (_) {}
    });
  });
  bar.appendChild(b);
});

// MOB3-006 brightness lock hint.
safe(function () {
  if ($("mobl3-bright")) return;
  var hints = $("mobl3-hints") || (function () { var n = mk("div", null); n.id = "mobl3-hints"; DOC.body.appendChild(n); return n; })();
  var chip = mk("span", null, G("mobl3-dim", "0") === "1" ? "Dim: on (tap)" : "Dim: off (tap)"); chip.id = "mobl3-bright"; chip.setAttribute("role", "button"); chip.tabIndex = 0;
  chip.title = "Panels cannot lock brightness; dim overlay instead.";
  function paint() { chip.textContent = DOC.body.classList.contains("mobl3-dim") ? "Dim: on (tap)" : "Dim: off (tap)"; }
  ON(chip, "click", function () {
    var on = DOC.body.classList.toggle("mobl3-dim");
    SV("mobl3-dim", on ? "1" : "0"); paint(); buzz(8);
    TS(on ? "Dim overlay on" : "Dim overlay off");
  });
  ON(chip, "keydown", function (e) { try { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); chip.click(); } } catch (_) {} });
  hints.appendChild(chip);
  if (G("mobl3-dim", "0") === "1") DOC.body.classList.add("mobl3-dim");
  paint();
});

// MOB3-007 rotation lock hint.
safe(function () {
  if ($("mobl3-rotate")) return;
  var hints = $("mobl3-hints") || (function () { var n = mk("div", null); n.id = "mobl3-hints"; DOC.body.appendChild(n); return n; })();
  var chip = mk("span", null, "Rotate: follow system"); chip.id = "mobl3-rotate"; chip.setAttribute("role", "button"); chip.tabIndex = 0;
  chip.title = "Browsers gate orientation lock behind fullscreen + gesture.";
  function label(mode) { chip.textContent = mode === "portrait" ? "Rotate: portrait lock try" : mode === "landscape" ? "Rotate: landscape lock try" : "Rotate: follow system"; }
  var mode = G("mobl3-rotate", "auto");
  label(mode);
  ON(chip, "click", function () {
    buzz(8);
    mode = mode === "auto" ? "portrait" : mode === "portrait" ? "landscape" : "auto";
    SV("mobl3-rotate", mode); label(mode);
    safe(function () {
      var o = WIN.screen && WIN.screen.orientation;
      if (mode === "auto") { if (o && o.unlock) o.unlock(); TS("Rotation follows system"); }
      else { if (o && o.lock) o.lock(mode).then(function () { TS("Rotation lock: " + mode); }, function () { TS("Rotation lock blocked"); }); else TS("Rotation lock unavailable"); }
    });
    try { DOC.dispatchEvent(new CustomEvent("mobl3:rotate", { detail: { mode: mode } })); } catch (_) {}
  });
  hints.appendChild(chip);
});

// MOB3-008 data-saver image toggle.
safe(function () {
  var bar = $("mobl3-bar") || (function () { var n = mk("div", null); n.id = "mobl3-bar"; DOC.body.appendChild(n); return n; })();
  if ($("mobl3-saver")) return;
  var b = mk("button", null, G("mobl3-saver", "0") === "1" ? "Saver on" : "Saver"); b.id = "mobl3-saver"; b.type = "button"; b.setAttribute("aria-label", "Toggle data saver"); b.title = "Data saver";
  function paint() { b.textContent = DOC.body.classList.contains("mobl3-datasaver") ? "Saver on" : "Saver"; }
  ON(b, "click", function () {
    var on = DOC.body.classList.toggle("mobl3-datasaver");
    SV("mobl3-saver", on ? "1" : "0"); paint(); buzz(8);
    TS(on ? "Data saver on: lighter images" : "Data saver off");
    try { DOC.dispatchEvent(new CustomEvent("mobl3:datasaver", { detail: { on: !!on } })); } catch (_) {}
  });
  bar.appendChild(b);
  if (G("mobl3-saver", "0") === "1") DOC.body.classList.add("mobl3-datasaver");
  paint();
});

// MOB3-009 tap-hold context menu.
safe(function () {
  if ($("mobl3-ctx")) return;
  var menu = mk("div", null); menu.id = "mobl3-ctx"; menu.setAttribute("role", "menu");
  var items = [
    { k: "refresh", label: "Refresh", fn: function () { var x = $("ux-refresh") || $("ux2-refresh"); if (x) x.click(); } },
    { k: "top", label: "Back to top", fn: function () { try { WIN.scrollTo(0, 0); } catch (_) {} } },
    { k: "open", label: "Open Jellyfin", fn: function () { var a = $("open-jellyfin"); if (a && a.href) { try { WIN.open(a.href, "_blank"); } catch (_) {} } } }
  ];
  items.forEach(function (it) {
    var b = mk("button", null, it.label); b.type = "button"; b.setAttribute("role", "menuitem"); b.setAttribute("data-mobl3-ctx", it.k);
    ON(b, "click", function () { buzz(10); hide(); safe(it.fn); });
    menu.appendChild(b);
  });
  DOC.body.appendChild(menu);
  function hide() { menu.classList.remove("is-show"); }
  function show(x, y, target) {
    menu.classList.add("is-show");
    menu.style.left = Math.max(8, Math.min(x, (WIN.innerWidth || 320) - 196)) + "px";
    menu.style.top = Math.max(8, Math.min(y, (WIN.innerHeight || 480) - 160)) + "px";
    try { DOC.dispatchEvent(new CustomEvent("mobl3:contexthold", { detail: { x: x, y: y } })); } catch (_) {}
    void target;
  }
  var timer = 0, sx = 0, sy = 0;
  ON(DOC, "touchstart", function (e) {
    try {
      var t = e.touches[0]; sx = t.clientX; sy = t.clientY;
      var el = e.target;
      if (el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT")) return;
      clearTimeout(timer);
      timer = setTimeout(function () { buzz(15); show(sx, sy, el); }, 550);
    } catch (_) {}
  }, { passive: true });
  ON(DOC, "touchmove", function () { clearTimeout(timer); }, { passive: true });
  ON(DOC, "touchend", function () { clearTimeout(timer); }, { passive: true });
  ON(DOC, "click", function (e) { try { if (!menu.contains(e.target)) hide(); } catch (_) { hide(); } });
  ON(DOC, "keydown", function (e) { try { if (e.key === "Escape") hide(); } catch (_) {} });
  WIN.__mobl3CtxHide = hide;
});

// MOB3-010 bottom-sheet modals.
safe(function () {
  function upgrade(root) {
    $all("[data-sheet],.modal,.dialog", root || DOC).forEach(function (n) {
      try { if (!n.hasAttribute("data-mobl3-sheet")) n.setAttribute("data-mobl3-sheet", "1"); } catch (_) {}
    });
  }
  upgrade(DOC);
  WIN.__mobl3Sheet = function (el) {
    try {
      var n = typeof el === "string" ? $(el) : el;
      if (!n) return false;
      n.setAttribute("data-mobl3-sheet", "1");
      return true;
    } catch (_) { return false; }
  };
  try {
    var mo = new WIN.MutationObserver(function (muts) {
      muts.forEach(function (m) {
        $all("[data-sheet],.modal,.dialog", m.target && m.target.nodeType === 1 ? m.target : DOC).forEach(function (n) {
          try { n.setAttribute("data-mobl3-sheet", "1"); } catch (_) {}
        });
      });
    });
    mo.observe(DOC.body, { childList: true, subtree: true });
  } catch (_) {}
});

} catch (_) {}
})();
