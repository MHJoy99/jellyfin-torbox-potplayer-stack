(function () {
"use strict";
/* pnlb-pack.js — 10 additive panel wins. IIFE, guarded, no deps, no API changes. */
try { if (window.__pnlbLoaded) return; window.__pnlbLoaded = true; } catch (_) {}
function G(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function SV(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
function GJ(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } }
function SJ(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} }
function E(id) { return document.getElementById(id); }
function MK(t, c, x) { var n = document.createElement(t); if (c) n.className = c; if (x != null) n.textContent = x; return n; }
function TS(m) { var t = E("toast"); if (t) { t.textContent = m; t.className = "toast toast-info show"; clearTimeout(TS._t); TS._t = setTimeout(function () { t.classList.remove("show"); }, 4200); } }
function ON(n, e, f) { if (n) n.addEventListener(e, f); }
function CP(t, msg) {
  function fb() { var ta = document.createElement("textarea"); ta.value = t; document.body.appendChild(ta); ta.select(); try { document.execCommand("copy"); } catch (_) {} ta.remove(); TS(msg || "Copied."); }
  if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(function () { TS(msg || "Copied."); }, fb); else fb();
}
function CSS() {
  if (E("pnlb-style")) return;
  var s = document.createElement("style"); s.id = "pnlb-style";
  s.textContent = [
    "#pnlb-hover-preview{position:fixed;z-index:120;pointer-events:none;display:none;max-width:280px;border:1px solid var(--accent-ring,#334);border-radius:10px;overflow:hidden;background:var(--bg,#0e1522);box-shadow:0 12px 32px rgba(0,0,0,.5)}",
    "#pnlb-hover-preview img{display:block;max-width:280px;max-height:320px;width:auto;height:auto}",
    "#pnlb-hover-preview .pnlb-cap{font-size:11px;padding:4px 8px;color:var(--muted,#999);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:280px}",
    ".pnlb-pathbtns{display:inline-flex;gap:4px;margin-left:6px;vertical-align:middle}",
    ".pnlb-mini{cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:6px;font-size:10.5px;padding:1px 7px;background:transparent;color:inherit}",
    ".pnlb-mini:hover{border-color:var(--accent,#4f8cff)}",
    "#pnlb-crumbs{font-size:12px;margin:0 0 10px;color:var(--muted,#999)}",
    "#pnlb-crumbs ol{display:flex;flex-wrap:wrap;gap:6px;list-style:none;margin:0;padding:0;align-items:center}",
    "#pnlb-crumbs a{color:inherit;text-decoration:none;border-bottom:1px dotted var(--accent-ring,#334)}",
    "#pnlb-crumbs a:hover{color:var(--text,#fff)}",
    "#pnlb-crumbs [aria-current]{color:var(--text,#fff);font-weight:700}",
    ".pnlb-sticky{position:sticky;top:0;z-index:30;background:var(--bg,#0e1522)}",
    ".pnlb-stuck{box-shadow:0 6px 18px rgba(0,0,0,.45)}",
    "#pnlb-presets{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:0 0 10px;font-size:12px}",
    "#pnlb-presets select,#pnlb-presets input{font:inherit;font-size:12px;padding:3px 8px;border-radius:8px;border:1px solid var(--accent-ring,#334);background:transparent;color:inherit;max-width:200px}",
    ".tbl th[data-pnlb-sort]{cursor:pointer;user-select:none}",
    ".tbl th[data-pnlb-sort]:hover{color:var(--accent,#4f8cff)}",
    "#pnlb-pager{display:flex;flex-wrap:wrap;gap:8px;align-items:center;font-size:12px;margin:8px 0;color:var(--muted,#999)}",
    "#pnlb-pager button,#pnlb-pager select{font:inherit;font-size:12px;padding:2px 9px;border-radius:8px;border:1px solid var(--accent-ring,#334);background:transparent;color:inherit}",
    "#pnlb-shortcuts{position:fixed;inset:0;z-index:130;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.55)}",
    "#pnlb-shortcuts[hidden]{display:none}",
    "#pnlb-shortcuts .pnlb-card{background:var(--bg,#0e1522);border:1px solid var(--accent-ring,#334);border-radius:12px;padding:16px;max-width:min(440px,92vw);font-size:13px}",
    "#pnlb-shortcuts kbd{border:1px solid var(--accent-ring,#334);border-radius:6px;padding:0 6px;font:inherit;background:rgba(255,255,255,.05)}",
    "#pnlb-recent{display:flex;gap:6px;overflow-x:auto;padding:6px 2px;margin:0 0 10px;font-size:12px}",
    "#pnlb-recent .pnlb-chip{flex:0 0 auto;cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:999px;padding:2px 10px;background:transparent;color:inherit;max-width:220px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}",
    "#pnlb-recent .pnlb-chip:hover{border-color:var(--accent,#4f8cff)}",
    "#pnlb-onboard{position:fixed;inset:0;z-index:140;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.6)}",
    "#pnlb-onboard[hidden]{display:none}",
    "#pnlb-onboard .pnlb-card{background:var(--bg,#0e1522);border:1px solid var(--accent-ring,#334);border-radius:14px;padding:20px;max-width:min(480px,92vw);font-size:14px}",
    "#pnlb-onboard .pnlb-steps{display:flex;gap:6px;margin:10px 0}",
    "#pnlb-onboard .pnlb-dot{width:22px;height:6px;border-radius:999px;background:var(--accent-ring,#334)}",
    "#pnlb-onboard .pnlb-dot.is-on{background:var(--accent,#4f8cff)}",
    "#pnlb-onboard .pnlb-row{display:flex;gap:8px;justify-content:flex-end;margin-top:14px}"
  ].join("\n");
  document.head.appendChild(s);
}

// PNLB-001
function wHoverPreview() {
  try {
    CSS();
    var tip = E("pnlb-hover-preview");
    if (!tip) { tip = MK("div", ""); tip.id = "pnlb-hover-preview"; tip.setAttribute("aria-hidden", "true"); document.body.appendChild(tip); }
    var timer = null, lastTarget = null;
    function hide() { try { tip.style.display = "none"; } catch (_) {} if (timer) { clearTimeout(timer); timer = null; } lastTarget = null; }
    function place(x, y) {
      var pad = 16, w = 296, h = 340;
      var lx = x + pad, ly = y + pad;
      try {
        if (lx + w > window.innerWidth - 8) lx = x - w - pad;
        if (ly + h > window.innerHeight - 8) ly = y - h - pad;
        if (lx < 8) lx = 8; if (ly < 8) ly = 8;
      } catch (_) {}
      tip.style.left = lx + "px"; tip.style.top = ly + "px";
    }
    document.addEventListener("mousemove", function (ev) {
      try {
        var t = ev.target && ev.target.closest ? ev.target.closest("main.shell img, #services img, #playback-status img") : null;
        if (!t || !t.getAttribute("src")) { if (lastTarget) hide(); return; }
        if (t === lastTarget && tip.style.display === "block") { place(ev.clientX, ev.clientY); return; }
        lastTarget = t;
        if (timer) clearTimeout(timer);
        var src = t.getAttribute("src"), alt = t.getAttribute("alt") || t.title || "Preview";
        timer = setTimeout(function () {
          try {
            tip.innerHTML = "";
            var im = document.createElement("img"); im.src = src; im.alt = alt;
            tip.appendChild(im);
            var cap = MK("div", "pnlb-cap", alt); tip.appendChild(cap);
            tip.style.display = "block"; place(ev.clientX, ev.clientY);
          } catch (_) {}
        }, 160);
      } catch (_) {}
    }, { passive: true });
    document.addEventListener("mouseout", function (ev) { try { if (lastTarget && ev.target === lastTarget) hide(); } catch (_) {} });
    document.addEventListener("scroll", hide, { passive: true, capture: true });
  } catch (_) {}
}

// PNLB-002
function wCopyPath() {
  function pathOf(el) {
    try {
      var d = el.querySelector("[data-path]");
      if (d) return d.getAttribute("data-path") || "";
      if (el.getAttribute && el.getAttribute("data-path")) return el.getAttribute("data-path");
      var m = el.querySelector(".mono, .cell-ellipsis, .act-msg, code");
      var t = (m ? m.textContent : el.textContent) || "";
      t = String(t).trim().split("\n")[0];
      if (/[a-zA-Z]:\\|\/[\w.\-]+\//.test(t)) return t.slice(0, 260);
    } catch (_) {}
    return "";
  }
  function decorate(root) {
    try {
      var items = root.querySelectorAll("#activity-log li, #services .service-card, .tbl tbody tr");
      Array.prototype.forEach.call(items, function (el) {
        try {
          if (el._pnlbPath) return; el._pnlbPath = 1;
          var p = pathOf(el);
          if (!p) return;
          var wrap = MK("span", "pnlb-pathbtns");
          var cp = MK("button", "pnlb-mini", "Copy path"); cp.type = "button"; cp.title = "Copy path: " + p;
          ON(cp, "click", function (ev) { try { ev.stopPropagation(); } catch (_) {} CP(p, "Path copied."); });
          var of = MK("button", "pnlb-mini", "Open folder"); of.type = "button"; of.title = "Show containing folder";
          ON(of, "click", function (ev) {
            try { ev.stopPropagation(); } catch (_) {}
            var folder = p.replace(/[/\\][^/\\]+$/, "") || p;
            CP(folder, "Folder path copied: " + folder);
          });
          wrap.appendChild(cp); wrap.appendChild(of);
          var anchor = el.querySelector(".act-msg, td:last-child, .service-head, p:last-child") || el;
          anchor.appendChild(wrap);
        } catch (_) {}
      });
    } catch (_) {}
  }
  try {
    decorate(document);
    try {
      var mo = new MutationObserver(function (muts) {
        try { muts.forEach(function (m) { Array.prototype.forEach.call(m.addedNodes || [], function (n) { if (n.nodeType === 1) decorate(n.nodeType === 1 && n.matches && /^(LI|TR|ARTICLE)$/.test(n.tagName) ? (n.parentNode || document) : n); }); }); } catch (_) {}
      });
      mo.observe(document.body, { childList: true, subtree: true });
    } catch (_) {}
  } catch (_) {}
}

// PNLB-003
function wCrumbs() {
  try {
    function currentLabel() {
      try {
        var h = location.hash ? decodeURIComponent(location.hash.replace(/^#/, "")) : "";
        var tab = document.querySelector('.tabs [aria-selected="true"]');
        var pane = document.querySelector("main.shell h2");
        return (h || (tab ? tab.textContent.trim() : "") || (pane ? pane.textContent.trim() : "") || "Home").slice(0, 60);
      } catch (_) { return "Home"; }
    }
    function paint() {
      try {
        var main = document.querySelector("main.shell"); if (!main) return;
        var nav = E("pnlb-crumbs");
        if (!nav) { nav = document.createElement("nav"); nav.id = "pnlb-crumbs"; nav.setAttribute("aria-label", "Breadcrumb"); main.insertBefore(nav, main.firstChild); }
        var label = currentLabel();
        nav.innerHTML = "";
        var ol = document.createElement("ol");
        var li0 = document.createElement("li"); var a0 = document.createElement("a"); a0.href = "#"; a0.textContent = "Home";
        ON(a0, "click", function (ev) { try { ev.preventDefault(); window.scrollTo({ top: 0, behavior: "smooth" }); } catch (_) { window.scrollTo(0, 0); } });
        li0.appendChild(a0); ol.appendChild(li0);
        var sep = MK("li", "", "›"); sep.setAttribute("aria-hidden", "true"); ol.appendChild(sep);
        var li1 = document.createElement("li"); li1.setAttribute("aria-current", "page"); li1.textContent = label; ol.appendChild(li1);
        nav.appendChild(ol);
      } catch (_) {}
    }
    paint();
    ON(window, "hashchange", paint);
    document.addEventListener("click", function (ev) { try { if (ev.target && ev.target.closest && ev.target.closest(".tabs [data-density]")) setTimeout(paint, 50); } catch (_) {} });
  } catch (_) {}
}

// PNLB-004
function wStickyFilters() {
  try {
    var bars = Array.prototype.slice.call(document.querySelectorAll("#activity-filters, .act-filters, #ux2-bar, .ux2-bar"));
    if (!bars.length) return;
    bars.forEach(function (b) { try { b.classList.add("pnlb-sticky"); } catch (_) {} });
    function onScroll() {
      try {
        var stuck = (window.scrollY || 0) > 24;
        bars.forEach(function (b) { b.classList.toggle("pnlb-stuck", stuck); });
      } catch (_) {}
    }
    ON(window, "scroll", onScroll); onScroll();
  } catch (_) {}
}

// PNLB-005
function wPresets() {
  try {
    var KEY = "pnlb.presets";
    var defs = GJ(KEY, null);
    if (!Array.isArray(defs)) { defs = [{ name: "4K unwatched", q: "4K", src: "all" }]; SJ(KEY, defs); }
    var host = E("activity-filters") || E("ux2-bar") || document.querySelector("main.shell");
    if (!host || E("pnlb-presets")) return;
    var bar = MK("div", ""); bar.id = "pnlb-presets"; bar.setAttribute("role", "group"); bar.setAttribute("aria-label", "Saved filter presets");
    bar.appendChild(MK("span", "", "Presets:"));
    var sel = document.createElement("select"); sel.id = "pnlb-preset-sel"; sel.setAttribute("aria-label", "Saved presets");
    var inp = document.createElement("input"); inp.id = "pnlb-preset-name"; inp.type = "text"; inp.placeholder = "Name, e.g. 4K unwatched"; inp.maxLength = 40; inp.setAttribute("aria-label", "Preset name");
    var save = MK("button", "pnlb-mini", "Save"); save.type = "button";
    var del = MK("button", "pnlb-mini", "Delete"); del.type = "button";
    bar.appendChild(sel); bar.appendChild(inp); bar.appendChild(save); bar.appendChild(del);
    host.appendChild(bar);
    function list() { var v = GJ(KEY, []); return Array.isArray(v) ? v : []; }
    function paint() {
      try {
        sel.innerHTML = "";
        list().forEach(function (p) { var o = document.createElement("option"); o.value = p.name; o.textContent = p.name; sel.appendChild(o); });
        if (!sel.options.length) { var o = document.createElement("option"); o.value = ""; o.textContent = "(no presets)"; sel.appendChild(o); }
      } catch (_) {}
    }
    function currentQ() {
      try {
        var s = E("ux-activity-search") || E("ux2-opq");
        return s ? s.value : "";
      } catch (_) { return ""; }
    }
    function applyPreset(p) {
      try {
        var s = E("ux-activity-search") || E("ux2-opq");
        if (s && p.q != null) { s.value = p.q; s.dispatchEvent(new Event("input", { bubbles: true })); }
        TS("Preset applied: " + p.name);
      } catch (_) {}
    }
    ON(sel, "change", function () { var f = list().filter(function (p) { return p.name === sel.value; })[0]; if (f) applyPreset(f); });
    ON(save, "click", function () {
      var name = (inp.value || "").trim().slice(0, 40) || "Preset " + (list().length + 1);
      var v = list().filter(function (p) { return p.name !== name; });
      v.push({ name: name, q: currentQ(), src: G("jellyfin.panel.activity.sourceFilter", "all") });
      SJ(KEY, v.slice(-12)); paint(); sel.value = name; TS("Preset saved: " + name);
    });
    ON(del, "click", function () {
      SJ(KEY, list().filter(function (p) { return p.name !== sel.value; })); paint(); TS("Preset deleted.");
    });
    paint();
  } catch (_) {}
}

// PNLB-006
function wTableSort() {
  try {
    function cmp(a, b, dir) {
      var an = parseFloat(a), bn = parseFloat(b);
      if (!isNaN(an) && !isNaN(bn) && a.trim() !== "" && b.trim() !== "") return (an - bn) * dir;
      return String(a).localeCompare(String(b)) * dir;
    }
    Array.prototype.forEach.call(document.querySelectorAll("table.tbl"), function (tbl) {
      try {
        var heads = tbl.querySelectorAll("thead th");
        Array.prototype.forEach.call(heads, function (th, idx) {
          try {
            if (th._pnlbSort) return; th._pnlbSort = 1;
            th.setAttribute("data-pnlb-sort", "");
            th.setAttribute("tabindex", "0"); th.setAttribute("aria-sort", "none"); th.title = "Click to sort";
            function go() {
              try {
                var cur = th.getAttribute("aria-sort") === "ascending" ? -1 : 1;
                Array.prototype.forEach.call(heads, function (h) { h.setAttribute("aria-sort", "none"); });
                th.setAttribute("aria-sort", cur === 1 ? "ascending" : "descending");
                var tb = tbl.querySelector("tbody"); if (!tb) return;
                var rows = Array.prototype.slice.call(tb.querySelectorAll("tr"));
                rows.sort(function (ra, rb) {
                  var ca = ra.children[idx] ? ra.children[idx].textContent : "";
                  var cb = rb.children[idx] ? rb.children[idx].textContent : "";
                  return cmp(ca, cb, cur);
                });
                rows.forEach(function (r) { tb.appendChild(r); });
              } catch (_) {}
            }
            ON(th, "click", go);
            ON(th, "keydown", function (ev) { if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); go(); } });
          } catch (_) {}
        });
      } catch (_) {}
    });
  } catch (_) {}
}

// PNLB-007
function wPager() {
  try {
    var log = E("activity-log"); if (!log || E("pnlb-pager")) return;
    var SIZE_KEY = "pnlb.pageSize", MODE_KEY = "pnlb.pagerMode";
    var size = parseInt(G(SIZE_KEY, "25"), 10) || 25;
    var mode = G(MODE_KEY, "paginate");
    var shown = size;
    var bar = MK("div", ""); bar.id = "pnlb-pager";
    bar.innerHTML = "<span>Show</span>";
    var sel = document.createElement("select"); sel.setAttribute("aria-label", "Items per page");
    ["10", "25", "50", "100"].forEach(function (n) { var o = document.createElement("option"); o.value = n; o.textContent = n; if (parseInt(n, 10) === size) o.selected = true; sel.appendChild(o); });
    var prev = MK("button", "", "Prev"); prev.type = "button";
    var next = MK("button", "", "Next"); next.type = "button";
    var info = MK("span", "", "");
    var tog = MK("button", "", mode === "infinite" ? "Infinite: on" : "Infinite: off"); tog.type = "button"; tog.title = "Toggle infinite scroll";
    bar.appendChild(sel); bar.appendChild(prev); bar.appendChild(next); bar.appendChild(info); bar.appendChild(tog);
    log.parentNode.insertBefore(bar, log.nextSibling);
    var sentinel = MK("div", ""); sentinel.id = "pnlb-sentinel"; sentinel.style.height = "2px";
    log.parentNode.insertBefore(sentinel, bar.nextSibling);
    var page = 0;
    function items() { return Array.prototype.slice.call(log.querySelectorAll("li")); }
    function paint() {
      try {
        var all = items(); if (!all.length) { info.textContent = "0 items"; return; }
        if (mode === "paginate") {
          var pages = Math.max(1, Math.ceil(all.length / size));
          page = Math.max(0, Math.min(page, pages - 1));
          all.forEach(function (li, i) { li.style.display = (i >= page * size && i < page * size + size) ? "" : "none"; });
          info.textContent = "Page " + (page + 1) + " of " + pages;
        } else {
          all.forEach(function (li, i) { li.style.display = i < shown ? "" : "none"; });
          info.textContent = "Showing " + Math.min(shown, all.length) + " of " + all.length;
        }
      } catch (_) {}
    }
    ON(sel, "change", function () { size = parseInt(sel.value, 10) || 25; SV(SIZE_KEY, String(size)); shown = size; page = 0; paint(); });
    ON(prev, "click", function () { page = Math.max(0, page - 1); paint(); });
    ON(next, "click", function () { page = page + 1; paint(); });
    ON(tog, "click", function () {
      mode = mode === "infinite" ? "paginate" : "infinite";
      SV(MODE_KEY, mode); tog.textContent = mode === "infinite" ? "Infinite: on" : "Infinite: off";
      shown = size; page = 0; paint();
    });
    try {
      var io = new IntersectionObserver(function (ents) {
        try { if (mode === "infinite" && ents[0] && ents[0].isIntersecting) { shown += size; paint(); } } catch (_) {}
      }, { root: null });
      io.observe(sentinel);
    } catch (_) {}
    try { new MutationObserver(function () { paint(); }).observe(log, { childList: true }); } catch (_) {}
    paint();
  } catch (_) {}
}

// PNLB-008
function wShortcuts() {
  try {
    if (E("pnlb-shortcuts")) return;
    var ov = MK("div", ""); ov.id = "pnlb-shortcuts"; ov.hidden = true;
    ov.innerHTML = "<div class='pnlb-card' role='dialog' aria-modal='true' aria-label='Keyboard shortcuts'><h2 style='margin:0 0 8px'>Keyboard shortcuts</h2><p><kbd>?</kbd> this cheatsheet &middot; <kbd>r</kbd> refresh &middot; <kbd>/</kbd> focus search &middot; <kbd>Esc</kbd> close</p><p style='color:var(--muted,#999)'>Press <kbd>Esc</kbd> or click outside to close.</p><div style='text-align:right'><button type='button' class='pnlb-mini' id='pnlb-sc-close'>Close</button></div></div>";
    document.body.appendChild(ov);
    function open() { ov.hidden = false; var b = E("pnlb-sc-close"); if (b) b.focus(); }
    function close() { ov.hidden = true; }
    try { window.pnlbShortcuts = open; } catch (_) {}
    ON(E("pnlb-sc-close"), "click", close);
    ON(ov, "click", function (ev) { if (ev.target === ov) close(); });
    document.addEventListener("keydown", function (ev) {
      try {
        var tag = (ev.target && ev.target.tagName) || "";
        var typing = /^(INPUT|TEXTAREA|SELECT)$/.test(tag) || (ev.target && ev.target.isContentEditable);
        if (ev.key === "?" && !typing) { ev.preventDefault(); open(); }
        else if (ev.key === "Escape" && !ov.hidden) close();
        else if ((ev.key === "r" || ev.key === "R") && !typing && ov.hidden) { var rb = E("refresh-button"); if (rb) rb.click(); }
        else if (ev.key === "/" && !typing && ov.hidden) { var s = E("ux-activity-search") || E("ux2-opq"); if (s) { ev.preventDefault(); s.focus(); } }
      } catch (_) {}
    });
  } catch (_) {}
}

// PNLB-009
function wRecent() {
  try {
    var KEY = "pnlb.recent";
    function list() { var v = GJ(KEY, []); return Array.isArray(v) ? v : []; }
    function push(title, href) {
      try {
        title = String(title || "").trim().slice(0, 80); if (!title) return;
        href = String(href || location.href);
        var v = [{ t: title, h: href, ts: Date.now() }].concat(list().filter(function (x) { return x.t !== title; }));
        SJ(KEY, v.slice(0, 12)); paint();
      } catch (_) {}
    }
    function paint() {
      try {
        var host = document.querySelector("main.shell"); if (!host) return;
        var strip = E("pnlb-recent");
        if (!strip) {
          strip = MK("div", ""); strip.id = "pnlb-recent"; strip.setAttribute("aria-label", "Recently viewed"); strip.setAttribute("role", "group");
          var cols = host.querySelector(".columns"); host.insertBefore(strip, cols || host.firstChild);
        }
        strip.innerHTML = "";
        var v = list(); if (!v.length) { strip.appendChild(MK("span", "", "Recently viewed: nothing yet")); return; }
        strip.appendChild(MK("span", "", "Recently viewed:"));
        v.forEach(function (r) {
          var c = MK("button", "pnlb-chip", r.t); c.type = "button"; c.title = r.t;
          ON(c, "click", function () { try { if (r.h && r.h !== location.href) location.href = r.h; } catch (_) {} TS("Reopened: " + r.t); });
          strip.appendChild(c);
        });
      } catch (_) {}
    }
    document.addEventListener("click", function (ev) {
      try {
        var el = ev.target && ev.target.closest ? ev.target.closest("#services .service-card, #activity-log li, a[href]") : null;
        if (!el) return;
        var title = (el.getAttribute("data-service-id") || el.textContent || "").trim().split("\n")[0].slice(0, 80);
        push(title, (el.getAttribute && el.getAttribute("href")) || location.href);
      } catch (_) {}
    });
    paint();
    try { window.pnlbRecent = push; } catch (_) {}
  } catch (_) {}
}

// PNLB-010
function wOnboard() {
  try {
    var KEY = "pnlb.onboarded";
    function done() { SV(KEY, "1"); var o = E("pnlb-onboard"); if (o) o.hidden = true; }
    function show(step) {
      try {
        var o = E("pnlb-onboard");
        if (!o) {
          o = MK("div", ""); o.id = "pnlb-onboard";
          o.innerHTML = "<div class='pnlb-card' role='dialog' aria-modal='true' aria-label='Welcome tour'><h2 style='margin:0'>Welcome to the panel</h2><p id='pnlb-ob-body' style='min-height:44px'></p><div class='pnlb-steps' aria-hidden='true'><span class='pnlb-dot'></span><span class='pnlb-dot'></span><span class='pnlb-dot'></span></div><div class='pnlb-row'><button type='button' class='pnlb-mini' id='pnlb-ob-skip'>Skip</button><button type='button' class='pnlb-mini' id='pnlb-ob-back'>Back</button><button type='button' class='pnlb-mini' id='pnlb-ob-next'>Next</button></div></div>";
          document.body.appendChild(o);
          ON(E("pnlb-ob-skip"), "click", done);
          ON(E("pnlb-ob-back"), "click", function () { show(Math.max(0, cur - 1)); });
          ON(E("pnlb-ob-next"), "click", function () { if (cur >= 2) done(); else show(cur + 1); });
          ON(o, "click", function (ev) { if (ev.target === o) done(); });
        }
        cur = step;
        var bodies = ["Step 1 of 3 — Services show live health. Press Start all or check Activity for logs.", "Step 2 of 3 — Press ? for shortcuts, save filter presets, sort tables by clicking headers.", "Step 3 of 3 — Done! Your recently-viewed strip keeps the last 12 items. Press Done to begin."];
        var b = E("pnlb-ob-body"); if (b) b.textContent = bodies[cur] || bodies[0];
        Array.prototype.forEach.call(o.querySelectorAll(".pnlb-dot"), function (d, i) { d.classList.toggle("is-on", i <= cur); });
        var nx = E("pnlb-ob-next"); if (nx) nx.textContent = cur >= 2 ? "Done" : "Next";
        o.hidden = false;
      } catch (_) {}
    }
    var cur = 0;
    try { window.pnlbTour = function () { show(0); }; } catch (_) {}
    if (G(KEY, "") === "1") return;
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function () { setTimeout(function () { show(0); }, 600); });
    else setTimeout(function () { show(0); }, 600);
  } catch (_) {}
}

try {
  CSS();
  wHoverPreview();
  wCopyPath();
  wCrumbs();
  wStickyFilters();
  wPresets();
  wTableSort();
  wPager();
  wShortcuts();
  wRecent();
  wOnboard();
} catch (_) {}
})();
