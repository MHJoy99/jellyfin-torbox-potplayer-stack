"use strict";
/* PNLE panel wins pack — additive only, no existing wiring touched. */
(function () {
  if (window.__pnleLoaded) return;
  window.__pnleLoaded = true;
  try {
    var DOC = document;
    var LS_PIN = "pnle.pinned";
    var LS_CSS = "pnle.customCss";
    var LS_HIDE_ARCH = "pnle.hideArchived";

    function $(s, r) { try { return (r || DOC).querySelector(s); } catch (_) { return null; } }
    function $all(s, r) { try { return Array.prototype.slice.call((r || DOC).querySelectorAll(s)); } catch (_) { return []; } }
    function loadJSON(k, fb) { try { var v = localStorage.getItem(k); return v ? JSON.parse(v) : fb; } catch (_) { return fb; } }
    function saveJSON(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} }
    function cardName(card) {
      try {
        var n = card.getAttribute("data-service") || card.getAttribute("data-name") || "";
        if (n) return n;
        var t = $(".svc-name,.service-name,.card-title,h3,h4", card);
        return (t ? t.textContent : card.textContent).trim().slice(0, 60) || "service";
      } catch (_) { return "service"; }
    }
    function toast(msg) {
      try {
        var t = DOC.getElementById("toast");
        if (t) { t.textContent = msg; t.classList.add("show"); setTimeout(function () { try { t.classList.remove("show"); } catch (_) {} }, 2200); return; }
        var n = DOC.createElement("div"); n.id = "pnle-toast"; n.textContent = msg;
        DOC.body.appendChild(n); setTimeout(function () { try { n.remove(); } catch (_) {} }, 2200);
      } catch (_) {}
    }
    function copyText(s, okMsg) {
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(s).then(function () { toast(okMsg || "Copied"); }, function () { fallbackCopy(s, okMsg); });
        } else { fallbackCopy(s, okMsg); }
      } catch (_) { fallbackCopy(s, okMsg); }
    }
    function fallbackCopy(s, okMsg) {
      try {
        var ta = DOC.createElement("textarea"); ta.value = s; ta.style.position = "fixed"; ta.style.opacity = "0";
        DOC.body.appendChild(ta); ta.select();
        try { DOC.execCommand("copy"); toast(okMsg || "Copied"); } catch (_) {}
        ta.remove();
      } catch (_) {}
    }

    /* own style namespace only */
    try {
      if (!DOC.getElementById("pnle-style")) {
        var st = DOC.createElement("style");
        st.id = "pnle-style";
        st.textContent = [
          ":root{--pnle-bg:var(--bg,#070b12);--pnle-card:var(--surface-2,#131e30);--pnle-text:var(--text,#e9eef7);--pnle-muted:var(--muted,#7d8ca3);--pnle-accent:var(--accent,#4f8cff);--pnle-ring:var(--accent-ring,rgba(79,140,255,.45))}",
          "#pnle-bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:10px 0;font-size:12px;color:var(--pnle-muted)}",
          "#pnle-bar button,#pnle-bar select{background:var(--pnle-card);color:var(--pnle-text);border:1px solid var(--pnle-ring);border-radius:8px;padding:5px 10px;font:inherit;cursor:pointer}",
          "#pnle-bar button:hover{border-color:var(--pnle-accent)}",
          "#pnle-bar button[aria-pressed=true]{background:var(--pnle-accent);color:#fff}",
          "#pnle-pinned{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:0 0 8px;font-size:12px;color:var(--pnle-muted)}",
          ".pnle-chip{display:inline-flex;align-items:center;gap:6px;background:var(--pnle-card);color:var(--pnle-text);border:1px solid var(--pnle-ring);border-radius:999px;padding:3px 6px 3px 10px}",
          ".pnle-chip button{border:none;background:transparent;color:var(--pnle-muted);cursor:pointer;font:inherit;padding:0 4px}",
          ".pnle-dot{font-size:11px;margin-right:5px;vertical-align:1px}",
          ".pnle-pinbtn{margin-left:6px;border:1px solid var(--pnle-ring);background:var(--pnle-card);color:var(--pnle-muted);border-radius:6px;font-size:11px;padding:1px 6px;cursor:pointer}",
          ".pnle-pinbtn[aria-pressed=true]{color:#ffd76a;border-color:rgba(255,215,106,.5)}",
          "#pnle-pop{position:fixed;z-index:70;display:none;max-width:280px;background:var(--pnle-card);color:var(--pnle-text);border:1px solid var(--pnle-ring);border-radius:10px;padding:10px 12px;font-size:12px;box-shadow:0 8px 30px rgba(0,0,0,.5)}",
          "#pnle-pop h4{margin:0 0 6px;font-size:13px}",
          "#pnle-pop code{font-size:11px;opacity:.9;word-break:break-all}",
          "#pnle-cssbox{margin:10px 0;font-size:12px;color:var(--pnle-muted)}",
          "#pnle-cssbox textarea{width:100%;min-height:52px;background:var(--pnle-card);color:var(--pnle-text);border:1px solid var(--pnle-ring);border-radius:8px;font:inherit;font-size:11.5px;padding:8px}",
          "#pnle-toast{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);z-index:80;background:var(--pnle-card);color:var(--pnle-text);border:1px solid var(--pnle-ring);border-radius:10px;padding:8px 14px;font-size:12.5px}",
          ".pnle-tour{outline:2px solid var(--pnle-accent) !important;border-radius:8px !important}",
          "@media print{#pnle-bar,#pnle-pinned,#pnle-cssbox,#pnle-pop{display:none !important}}"
        ].join("\n");
        DOC.head.appendChild(st);
      }
    } catch (_) {}

    function grid() { return DOC.getElementById("services"); }
    function cards() {
      var g = grid();
      if (!g) return [];
      return $all(".service-card", g).filter(function (c) { return !c.classList.contains("skeleton"); });
    }
    function isUp(card) {
      try {
        if (card.classList.contains("is-up") || card.classList.contains("up") || card.classList.contains("running")) return true;
        if (card.classList.contains("is-down") || card.classList.contains("down") || card.classList.contains("stopped")) return false;
        var t = (card.textContent || "").toLowerCase();
        if (/(^|\s)(up|running|online|healthy)(\s|$|,)/.test(t)) return true;
        if (/(^|\s)(down|offline|stopped|error|unhealthy)(\s|$|,)/.test(t)) return false;
        return null;
      } catch (_) { return null; }
    }
    function isArchived(card) {
      try {
        if (card.hasAttribute("data-archived")) return true;
        if (card.classList.contains("is-archived") || card.classList.contains("archived")) return true;
        return /archived/i.test(card.textContent || "");
      } catch (_) { return false; }
    }

    // PNLE-001 pinned services row (localStorage list, additive strip above #services)
    function pinnedRow() {
      try {
        var g = grid(); if (!g || DOC.getElementById("pnle-pinned")) return;
        var wrap = DOC.createElement("div"); wrap.id = "pnle-pinned";
        wrap.setAttribute("role", "group"); wrap.setAttribute("aria-label", "Pinned services");
        g.parentNode.insertBefore(wrap, g);
        renderPinned();
      } catch (_) {}
    }
    function pinnedList() { return loadJSON(LS_PIN, []); }
    function renderPinned() {
      try {
        var wrap = DOC.getElementById("pnle-pinned"); if (!wrap) return;
        var pins = pinnedList();
        wrap.innerHTML = "";
        var label = DOC.createElement("span"); label.textContent = pins.length ? "Pinned:" : "Pin services with \u{1F4CC} on a card.";
        wrap.appendChild(label);
        pins.forEach(function (name) {
          var chip = DOC.createElement("span"); chip.className = "pnle-chip";
          chip.textContent = name + " ";
          var x = DOC.createElement("button"); x.type = "button"; x.textContent = "\u00D7"; x.setAttribute("aria-label", "Unpin " + name);
          x.onclick = function () { try { saveJSON(LS_PIN, pinnedList().filter(function (p) { return p !== name; })); syncPinBtns(); renderPinned(); } catch (_) {} };
          chip.appendChild(x); wrap.appendChild(chip);
        });
      } catch (_) {}
    }
    function syncPinBtns() {
      try {
        var pins = pinnedList();
        cards().forEach(function (card) {
          var b = $(".pnle-pinbtn", card); if (!b) return;
          var on = pins.indexOf(cardName(card)) !== -1;
          b.setAttribute("aria-pressed", on ? "true" : "false");
          b.textContent = on ? "\u{1F4CC} Pinned" : "\u{1F4CC} Pin";
        });
      } catch (_) {}
    }
    function injectPinBtns() {
      try {
        cards().forEach(function (card) {
          if ($(".pnle-pinbtn", card)) return;
          var b = DOC.createElement("button"); b.type = "button"; b.className = "pnle-pinbtn";
          b.textContent = "\u{1F4CC} Pin";
          b.onclick = function (ev) {
            try {
              ev.stopPropagation();
              var name = cardName(card); var pins = pinnedList();
              if (pins.indexOf(name) !== -1) pins = pins.filter(function (p) { return p !== name; });
              else pins.push(name);
              saveJSON(LS_PIN, pins); syncPinBtns(); renderPinned(); toast("Pinned updated");
            } catch (_) {}
          };
          var anchor = $(".svc-name,.service-name,.card-title,h3,h4", card) || card.firstChild;
          try { (anchor && anchor.parentNode ? anchor.parentNode : card).appendChild(b); } catch (_) { card.appendChild(b); }
        });
        syncPinBtns();
      } catch (_) {}
    }

    // PNLE-002 service status emoji dots (read-only GET /api/health refresh, additive span)
    var pnleHealth = {};
    function paintDots() {
      try {
        cards().forEach(function (card) {
          if ($(".pnle-dot", card)) { updateDot(card); return; }
          var d = DOC.createElement("span"); d.className = "pnle-dot"; d.setAttribute("aria-hidden", "true");
          var anchor = $(".svc-name,.service-name,.card-title,h3,h4", card);
          try {
            if (anchor) anchor.insertBefore(d, anchor.firstChild);
            else card.insertBefore(d, card.firstChild);
          } catch (_) {}
          updateDot(card);
        });
      } catch (_) {}
    }
    function updateDot(card) {
      try {
        var d = $(".pnle-dot", card); if (!d) return;
        var s = isUp(card);
        d.textContent = s === true ? "\u{1F7E2}" : (s === false ? "\u{1F534}" : "\u{1F7E1}");
        var nm = cardName(card);
        if (pnleHealth[nm] === "up") d.textContent = "\u{1F7E2}";
        else if (pnleHealth[nm] === "down") d.textContent = "\u{1F534}";
      } catch (_) {}
    }
    function refreshHealth() {
      try {
        fetch("/api/health", { method: "GET", cache: "no-store" }).then(function (r) {
          if (!r.ok) throw new Error("http " + r.status);
          return r.json();
        }).then(function (j) {
          try {
            var map = j.services || j.checks || j;
            Object.keys(map).forEach(function (k) {
              var v = String(map[k]).toLowerCase();
              pnleHealth[k] = (/up|ok|running|healthy|true/.test(v) && !/down|fail|error/.test(v)) ? "up" : "down";
            });
            paintDots();
          } catch (_) {}
        }).catch(function () {});
      } catch (_) {}
    }

    // PNLE-003 quick copy API URL (copies origin + /api/health)
    function copyApiUrl() {
      try {
        var url = (location.origin || "") + "/api/health";
        copyText(url, "API URL copied: " + url);
      } catch (_) {}
    }

    // PNLE-004 sortable by uptime/name (reorders #services cards only)
    var pnleSort = "none";
    function sortCards(mode) {
      try {
        pnleSort = mode;
        var g = grid(); if (!g) return;
        var list = cards(); if (!list.length) return;
        var withIdx = list.map(function (c, i) { return { c: c, i: i }; });
        if (mode === "name") withIdx.sort(function (a, b) { return cardName(a.c).localeCompare(cardName(b.c)); });
        else if (mode === "status") withIdx.sort(function (a, b) {
          var sa = isUp(a.c), sb = isUp(b.c);
          return (sa === sb) ? cardName(a.c).localeCompare(cardName(b.c)) : (sa === true ? -1 : 1);
        });
        else withIdx.sort(function (a, b) { return a.i - b.i; });
        withIdx.forEach(function (w) { try { g.appendChild(w.c); } catch (_) {} });
        paintDots(); injectPinBtns(); applyArchivedHide();
      } catch (_) {}
    }

    // PNLE-005 archived services hide (toggle; heuristic .is-archived / "archived" text)
    function hideArchived() { try { return localStorage.getItem(LS_HIDE_ARCH) === "1"; } catch (_) { return false; } }
    function applyArchivedHide() {
      try {
        var hide = hideArchived();
        cards().forEach(function (card) {
          if (isArchived(card)) card.style.display = hide ? "none" : "";
        });
        var t = $('[data-pnle="hide-arch"]');
        if (t) t.setAttribute("aria-pressed", hide ? "true" : "false");
      } catch (_) {}
    }

    // PNLE-006 service detail popover (click card title -> floating detail, additive)
    function ensurePop() {
      try {
        var p = DOC.getElementById("pnle-pop");
        if (p) return p;
        p = DOC.createElement("div"); p.id = "pnle-pop"; p.setAttribute("role", "dialog"); p.setAttribute("aria-live", "polite");
        DOC.body.appendChild(p);
        DOC.addEventListener("click", function (e) {
          try { if (p.style.display === "block" && !p.contains(e.target)) p.style.display = "none"; } catch (_) {}
        });
        DOC.addEventListener("keydown", function (e) { try { if (e.key === "Escape") p.style.display = "none"; } catch (_) {} });
        return p;
      } catch (_) { return null; }
    }
    function showPop(card, x, y) {
      try {
        var p = ensurePop(); if (!p) return;
        var name = cardName(card);
        var addr = ($(".svc-addr", card) || {}).textContent || "";
        addr = String(addr).trim().slice(0, 120);
        var status = isUp(card); var emoji = status === true ? "\u{1F7E2}" : (status === false ? "\u{1F534}" : "\u{1F7E1}");
        p.innerHTML = "";
        var h = DOC.createElement("h4"); h.textContent = emoji + " " + name; p.appendChild(h);
        if (addr) { var c = DOC.createElement("code"); c.textContent = addr; p.appendChild(c); }
        var row = DOC.createElement("div"); row.style.marginTop = "8px"; row.style.display = "flex"; row.style.gap = "6px";
        var cp = DOC.createElement("button"); cp.type = "button"; cp.textContent = "Copy name";
        cp.onclick = function () { copyText(name, "Copied: " + name); };
        row.appendChild(cp);
        if (addr) {
          var ca = DOC.createElement("button"); ca.type = "button"; ca.textContent = "Copy address";
          ca.onclick = function () { copyText(addr, "Address copied"); };
          row.appendChild(ca);
        }
        p.appendChild(row);
        p.style.display = "block";
        p.style.left = Math.min(x + 10, window.innerWidth - 300) + "px";
        p.style.top = Math.min(y + 10, window.innerHeight - 160) + "px";
      } catch (_) {}
    }
    function injectPopTriggers() {
      try {
        cards().forEach(function (card) {
          if (card.getAttribute("data-pnle-pop") === "1") return;
          card.setAttribute("data-pnle-pop", "1");
          card.addEventListener("click", function (e) {
            try {
              if (e.target.closest("button,a,input,select,textarea,.pnle-pinbtn")) return;
              showPop(card, e.clientX || 100, e.clientY || 100);
            } catch (_) {}
          });
        });
      } catch (_) {}
    }

    // PNLE-007 bulk open in tabs (opens each card link; popup-blocker safe loop)
    function openAll() {
      try {
        var links = [];
        cards().forEach(function (card) {
          if (card.style.display === "none") return;
          var a = $("a[href^='http'],a[href^='/']", card);
          var addr = ($(".svc-addr", card) || {}).textContent || "";
          addr = String(addr).trim();
          var url = a ? a.getAttribute("href") : (/^https?:\/\//.test(addr) ? addr : "");
          if (url) links.push(url);
        });
        if (!links.length) { toast("No service URLs to open"); return; }
        var blocked = 0;
        links.slice(0, 10).forEach(function (u) { try { var w = window.open(u, "_blank", "noopener"); if (!w) blocked++; } catch (_) { blocked++; } });
        toast(blocked ? "Opened with " + blocked + " blocked by popup blocker" : "Opened " + Math.min(links.length, 10) + " tabs");
      } catch (_) {}
    }

    // PNLE-008 panel tour replay button (highlights #services -> #activity-log -> #toast)
    function replayTour() {
      try {
        var steps = ["services", "activity-log", "toast"];
        var i = 0;
        function step() {
          try {
            $all(".pnle-tour").forEach(function (n) { try { n.classList.remove("pnle-tour"); } catch (_) {} });
            if (i >= steps.length) { toast("Tour done"); return; }
            var n = DOC.getElementById(steps[i]);
            if (n) {
              n.classList.add("pnle-tour");
              try { n.scrollIntoView({ block: "nearest", behavior: "smooth" }); } catch (_) {}
              toast("Tour " + (i + 1) + "/" + steps.length + ": #" + steps[i]);
            }
            i++; setTimeout(step, 1400);
          } catch (_) {}
        }
        step();
      } catch (_) {}
    }

    // PNLE-009 custom CSS injector box (textarea + apply, persisted, own #pnle-custom tag)
    function cssBox() {
      try {
        if (DOC.getElementById("pnle-cssbox")) return;
        var log = DOC.getElementById("activity-log");
        var box = DOC.createElement("div"); box.id = "pnle-cssbox";
        var lab = DOC.createElement("div"); lab.textContent = "Custom CSS (stored locally, applied via own <style> tag):";
        var ta = DOC.createElement("textarea"); ta.setAttribute("aria-label", "Custom CSS");
        try { ta.value = localStorage.getItem(LS_CSS) || ""; } catch (_) {}
        var row = DOC.createElement("div"); row.style.display = "flex"; row.style.gap = "6px"; row.style.marginTop = "6px";
        var apply = DOC.createElement("button"); apply.type = "button"; apply.textContent = "Apply CSS";
        apply.onclick = function () {
          try {
            var css = ta.value || "";
            try { localStorage.setItem(LS_CSS, css); } catch (_) {}
            applyCustomCss(css); toast("Custom CSS applied");
          } catch (_) {}
        };
        var clear = DOC.createElement("button"); clear.type = "button"; clear.textContent = "Clear";
        clear.onclick = function () {
          try { ta.value = ""; try { localStorage.removeItem(LS_CSS); } catch (_) {} applyCustomCss(""); toast("Custom CSS cleared"); } catch (_) {}
        };
        row.appendChild(apply); row.appendChild(clear);
        box.appendChild(lab); box.appendChild(ta); box.appendChild(row);
        if (log && log.parentNode) log.parentNode.insertBefore(box, log);
        else DOC.body.appendChild(box);
        applyCustomCss(ta.value || "");
      } catch (_) {}
    }
    function applyCustomCss(css) {
      try {
        var tag = DOC.getElementById("pnle-custom");
        if (!css) { if (tag) tag.remove(); return; }
        if (!tag) { tag = DOC.createElement("style"); tag.id = "pnle-custom"; DOC.head.appendChild(tag); }
        tag.textContent = css;
      } catch (_) {}
    }

    // PNLE-010 export dashboard PNG hint (window.print shortcut; print CSS hides PNLE chrome)
    function exportHint() {
      try { toast("Export: press Ctrl+P then Save as PDF, or screenshot. (window.print)"); } catch (_) {}
      try { window.print(); } catch (_) {}
    }

    function toolbar() {
      try {
        var g = grid(); if (!g || DOC.getElementById("pnle-bar")) return;
        var bar = DOC.createElement("div"); bar.id = "pnle-bar"; bar.setAttribute("role", "toolbar"); bar.setAttribute("aria-label", "Panel extras");
        function btn(label, title, fn, key) {
          var b = DOC.createElement("button"); b.type = "button"; b.textContent = label; b.title = title || label;
          if (key) b.setAttribute("data-pnle", key);
          b.onclick = function () { try { fn(b); } catch (_) {} };
          bar.appendChild(b); return b;
        }
        btn("Copy API URL", "Copy origin + /api/health", function () { copyApiUrl(); });
        btn("Open all in tabs", "Bulk open visible service URLs (max 10)", function () { openAll(); });
        btn("Replay tour", "Highlight #services, #activity-log, #toast", function () { replayTour(); });
        btn("Export PNG", "Hint: Ctrl+P / screenshot (calls window.print)", function () { exportHint(); });
        var hide = btn("Hide archived: off", "Toggle archived services", function (b) {
          try {
            var next = !hideArchived();
            try { localStorage.setItem(LS_HIDE_ARCH, next ? "1" : "0"); } catch (_) {}
            applyArchivedHide();
            b.textContent = "Hide archived: " + (next ? "on" : "off");
            b.setAttribute("aria-pressed", next ? "true" : "false");
          } catch (_) {}
        }, "hide-arch");
        try {
          var on = hideArchived();
          hide.textContent = "Hide archived: " + (on ? "on" : "off");
          hide.setAttribute("aria-pressed", on ? "true" : "false");
        } catch (_) {}
        var sel = DOC.createElement("select"); sel.setAttribute("aria-label", "Sort services");
        [["none", "Sort: default"], ["name", "Sort: name"], ["status", "Sort: status"]].forEach(function (o) {
          var op = DOC.createElement("option"); op.value = o[0]; op.textContent = o[1]; sel.appendChild(op);
        });
        sel.onchange = function () { try { sortCards(sel.value); } catch (_) {} };
        bar.appendChild(sel);
        g.parentNode.insertBefore(bar, g);
      } catch (_) {}
    }

    function boot() {
      try {
        toolbar();
        pinnedRow();
        injectPinBtns();
        paintDots();
        injectPopTriggers();
        cssBox();
        applyArchivedHide();
        refreshHealth();
        try {
          var obs = new MutationObserver(function () {
            try { injectPinBtns(); paintDots(); injectPopTriggers(); applyArchivedHide(); } catch (_) {}
          });
          var g = grid();
          if (g) obs.observe(g, { childList: true, subtree: true });
        } catch (_) {}
      } catch (_) {}
    }
    if (DOC.readyState === "loading") DOC.addEventListener("DOMContentLoaded", boot);
    else boot();
  } catch (_) {}
})();
