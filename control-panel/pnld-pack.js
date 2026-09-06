"use strict";
(function () {
  if (window.__pnldLoaded) return;
  window.__pnldLoaded = true;
  try {
    var ORDER_KEY = "pnld.order";
    var DENSITY_KEY = "pnld.density";
    var MUTE_KEY = "pnld.muted";
    var CHECK_KEY = "pnld.checklist.done";
    var RESTART_KEY = "pnld.restartedAt";

    function $(s, r) { try { return (r || document).querySelector(s); } catch (_) { return null; } }
    function $all(s, r) { try { return Array.prototype.slice.call((r || document).querySelectorAll(s)); } catch (_) { return []; } }
    function loadJSON(k, fb) { try { var v = localStorage.getItem(k); return v ? JSON.parse(v) : fb; } catch (_) { return fb; } }
    function saveJSON(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} }

    /* base style (own namespace only) */
    try {
      if (!document.getElementById("pnld-style")) {
        var st = document.createElement("style");
        st.id = "pnld-style";
        st.textContent = [
          ":root{--pnld-bg:var(--bg,#070b12);--pnld-card:var(--surface-2,#131e30);--pnld-text:var(--text,#e9eef7);--pnld-muted:var(--muted,#7d8ca3);--pnld-accent:var(--accent,#4f8cff);--pnld-ring:var(--accent-ring,rgba(79,140,255,.45))}",
          "#pnld-bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:10px 0;font-size:12px;color:var(--pnld-muted)}",
          "#pnld-bar input[type=search]{background:var(--pnld-card);color:var(--pnld-text);border:1px solid var(--pnld-ring);border-radius:8px;padding:5px 9px;font:inherit;min-width:170px}",
          "#pnld-bar button{background:var(--pnld-card);color:var(--pnld-text);border:1px solid var(--pnld-ring);border-radius:8px;padding:5px 10px;font:inherit;cursor:pointer}",
          "#pnld-bar button:hover{border-color:var(--pnld-accent)}",
          "#pnld-bar button[aria-pressed=true]{background:var(--pnld-accent);color:#fff}",
          ".pnld-fav{width:16px;height:16px;border-radius:4px;vertical-align:-3px;margin-right:4px;background:var(--pnld-card)}",
          ".pnld-hl{outline:2px solid var(--pnld-accent);border-radius:6px;background:rgba(79,140,255,.15)}",
          ".pnld-fresh{font-size:10.5px;color:#9fe0a8;border:1px solid rgba(125,216,138,.4);border-radius:999px;padding:1px 8px;margin-left:6px;white-space:nowrap}",
          "body.pnld-compact #services{gap:8px !important}",
          "body.pnld-compact .service-card{gap:6px !important;padding:10px !important}",
          "body.pnld-compact .svc-detail{display:none !important}",
          "#pnld-ring{width:22px;height:22px;vertical-align:middle}",
          ".pnld-help{display:inline-grid;place-items:center;width:16px;height:16px;border-radius:50%;border:1px solid var(--pnld-ring);color:var(--pnld-muted);font-size:11px;line-height:1;cursor:help;margin-left:6px;position:relative}",
          ".pnld-help:hover::after{content:attr(data-tip);position:absolute;left:50%;top:130%;transform:translateX(-50%);min-width:150px;max-width:230px;background:var(--pnld-card);color:var(--pnld-text);border:1px solid var(--pnld-ring);border-radius:8px;padding:7px 9px;font-size:11.5px;font-weight:400;z-index:50;white-space:normal}",
          "#pnld-check{position:fixed;right:14px;bottom:14px;z-index:60;background:var(--pnld-card);color:var(--pnld-text);border:1px solid var(--pnld-ring);border-radius:12px;padding:14px 15px;max-width:280px;box-shadow:0 8px 30px rgba(0,0,0,.5);font-size:12.5px}",
          "#pnld-check h3{margin:0 0 8px;font-size:13px}",
          "#pnld-check li{margin:4px 0;list-style:none}",
          "#pnld-check ul{margin:0 0 10px;padding:0}",
          "body.pnld-muted #toast{display:none !important}",
          ".service-card[draggable=true]{cursor:grab}"
        ].join("\n");
        document.head.appendChild(st);
      }
    } catch (_) {}

    function servicesGrid() { return document.getElementById("services"); }
    function cards() { var g = servicesGrid(); return g ? $all(".service-card", g).filter(function (c) { return !c.classList.contains("skeleton"); }) : []; }

    // PNLD-001 service favicons from origin (img-only, no fetch; derives origin from .svc-addr port)
    function favicons() {
      try {
        cards().forEach(function (card) {
          if (card.querySelector(".pnld-fav")) return;
          var addr = $(".svc-addr", card);
          var m = addr && addr.textContent.match(/127\.0\.0\.1:(\d+)/);
          if (!m) return;
          var img = document.createElement("img");
          img.className = "pnld-fav";
          img.alt = "";
          img.loading = "lazy";
          img.src = "http://127.0.0.1:" + m[1] + "/favicon.ico";
          img.onerror = function () { try { img.remove(); } catch (_) {} };
          var name = $(".svc-name", card);
          if (name) name.prepend(img); else card.prepend(img);
        });
      } catch (_) {}
    }

    // PNLD-002 drag-to-reorder dashboard cards (persist localStorage pnld.order)
    function reorder() {
      try {
        var g = servicesGrid();
        if (!g || g.__pnldDnd) return;
        g.__pnldDnd = true;
        var order = loadJSON(ORDER_KEY, null);
        if (Array.isArray(order) && order.length) {
          var byId = {};
          cards().forEach(function (c) { byId[c.getAttribute("data-service-id")] = c; });
          order.forEach(function (id) { if (byId[id]) g.appendChild(byId[id]); });
        }
        var drag = null;
        g.addEventListener("dragstart", function (e) {
          var c = e.target.closest && e.target.closest(".service-card");
          if (!c) return;
          drag = c;
          try { e.dataTransfer.effectAllowed = "move"; } catch (_) {}
        });
        g.addEventListener("dragover", function (e) {
          if (!drag) return;
          var over = e.target.closest && e.target.closest(".service-card");
          if (!over || over === drag) return;
          e.preventDefault();
          try {
            var r = over.getBoundingClientRect();
            var after = (e.clientY - r.top) > r.height / 2;
            g.insertBefore(drag, after ? over.nextSibling : over);
          } catch (_) {}
        });
        g.addEventListener("drop", function (e) {
          try {
            e.preventDefault();
            var ids = cards().map(function (c) { return c.getAttribute("data-service-id"); });
            saveJSON(ORDER_KEY, ids);
          } catch (_) {}
          drag = null;
        });
        cards().forEach(function (c) { c.setAttribute("draggable", "true"); });
        new MutationObserver(function () {
          try { $all(".service-card", g).forEach(function (c) { if (!c.getAttribute("draggable")) c.setAttribute("draggable", "true"); }); favicons(); } catch (_) {}
        }).observe(g, { childList: true });
      } catch (_) {}
    }

    // PNLD-003 compact/comfortable density toggle
    function density(btn) {
      try {
        var v = null;
        try { v = localStorage.getItem(DENSITY_KEY); } catch (_) {}
        if (v === "compact") document.body.classList.add("pnld-compact");
        if (btn) btn.addEventListener("click", function () {
          try {
            var on = document.body.classList.toggle("pnld-compact");
            try { localStorage.setItem(DENSITY_KEY, on ? "compact" : "comfortable"); } catch (_) {}
            btn.setAttribute("aria-pressed", on ? "true" : "false");
            btn.textContent = on ? "Comfortable" : "Compact";
          } catch (_) {}
        });
      } catch (_) {}
    }

    // PNLD-004 service search highlight (filters + highlights matching cards)
    function search(input) {
      try {
        if (!input) return;
        input.addEventListener("input", function () {
          try {
            var q = (input.value || "").trim().toLowerCase();
            cards().forEach(function (c) {
              var t = (c.textContent || "").toLowerCase();
              var hit = !q || t.indexOf(q) !== -1;
              c.style.display = hit ? "" : "none";
              c.classList.toggle("pnld-hl", !!q && hit);
            });
          } catch (_) {}
        });
      } catch (_) {}
    }

    // PNLD-005 recently-restarted badge (marks cards whose Restart button was pressed)
    function freshBadge() {
      try {
        var seen = loadJSON(RESTART_KEY, {});
        function paint() {
          try {
            cards().forEach(function (c) {
              var id = c.getAttribute("data-service-id");
              var ts = seen[id];
              var old = $(".pnld-fresh", c);
              if (old) old.remove();
              if (ts && Date.now() - ts < 10 * 60 * 1000) {
                var mins = Math.max(0, Math.round((Date.now() - ts) / 60000));
                var b = document.createElement("span");
                b.className = "pnld-fresh";
                b.textContent = mins < 1 ? "restarted just now" : "restarted " + mins + "m ago";
                var h = $(".svc-name", c);
                if (h) h.appendChild(b);
              }
            });
          } catch (_) {}
        }
        document.addEventListener("click", function (e) {
          try {
            var btn = e.target.closest && e.target.closest('button[data-action="restart"]');
            if (!btn) return;
            var card = btn.closest(".service-card");
            var id = btn.getAttribute("data-service") || (card && card.getAttribute("data-service-id")) || "svc";
            seen[id] = Date.now();
            saveJSON(RESTART_KEY, seen);
            setTimeout(paint, 800);
          } catch (_) {}
        }, true);
        paint();
        setInterval(paint, 60000);
      } catch (_) {}
    }

    // PNLD-006 auto-refresh countdown ring (visual 5s ring reset on #services mutations)
    function ring(host) {
      try {
        if (!host) return;
        host.innerHTML = '<svg id="pnld-ring" viewBox="0 0 24 24" aria-label="Next refresh countdown"><circle cx="12" cy="12" r="9" fill="none" stroke="var(--pnld-ring)" stroke-width="3"/><circle id="pnld-ring-fg" cx="12" cy="12" r="9" fill="none" stroke="var(--pnld-accent)" stroke-width="3" stroke-linecap="round" stroke-dasharray="56.5" stroke-dashoffset="0" transform="rotate(-90 12 12)"/></svg>';
        var fg = host.querySelector("#pnld-ring-fg");
        var left = 5;
        var g = servicesGrid();
        if (g) new MutationObserver(function () { left = 5; }).observe(g, { childList: true, subtree: true });
        setInterval(function () {
          try {
            left = left <= 0 ? 5 : left - 1;
            if (fg) fg.style.strokeDashoffset = String(56.5 * (1 - left / 5));
            host.title = "Refreshing in " + left + "s";
          } catch (_) {}
        }, 1000);
      } catch (_) {}
    }

    // PNLD-007 export/import panel prefs JSON (pnld.* keys download + file restore)
    function prefs(expBtn, impInput) {
      try {
        if (expBtn) expBtn.addEventListener("click", function () {
          try {
            var out = {};
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              if (k && k.indexOf("pnld.") === 0) out[k] = localStorage.getItem(k);
            }
            var blob = new Blob([JSON.stringify(out, null, 2)], { type: "application/json" });
            var a = document.createElement("a");
            a.href = URL.createObjectURL(blob);
            a.download = "panel-prefs.json";
            document.body.appendChild(a);
            a.click();
            setTimeout(function () { try { URL.revokeObjectURL(a.href); a.remove(); } catch (_) {} }, 500);
          } catch (_) {}
        });
        if (impInput) impInput.addEventListener("change", function () {
          try {
            var f = impInput.files && impInput.files[0];
            if (!f) return;
            var rd = new FileReader();
            rd.onload = function () {
              try {
                var o = JSON.parse(String(rd.result || "{}"));
                Object.keys(o).forEach(function (k) { if (k.indexOf("pnld.") === 0) try { localStorage.setItem(k, String(o[k])); } catch (_) {} });
                location.reload();
              } catch (_) {}
            };
            rd.readAsText(f);
          } catch (_) {}
        });
      } catch (_) {}
    }

    // PNLD-008 quick mute-all toasts (hides #toast, persists pnld.muted)
    function mute(btn) {
      try {
        var apply = function (on) {
          try {
            document.body.classList.toggle("pnld-muted", on);
            if (btn) btn.setAttribute("aria-pressed", on ? "true" : "false");
          } catch (_) {}
        };
        var cur = null;
        try { cur = localStorage.getItem(MUTE_KEY) === "1"; } catch (_) {}
        apply(!!cur);
        var toast = document.getElementById("toast");
        if (toast) new MutationObserver(function () {
          try { if (document.body.classList.contains("pnld-muted")) toast.textContent = ""; } catch (_) {}
        }).observe(toast, { childList: true });
        if (btn) btn.addEventListener("click", function () {
          try {
            var on = !document.body.classList.contains("pnld-muted");
            try { localStorage.setItem(MUTE_KEY, on ? "1" : "0"); } catch (_) {}
            apply(on);
          } catch (_) {}
        });
      } catch (_) {}
    }

    // PNLD-009 contextual help tooltips (? icons on Services/Activity panes)
    function tips() {
      try {
        var defs = [
          [".services-pane .pane-heading h2", "Services show live health. Start/Restart/Stop act on the local service only."],
          [".activity-pane .pane-heading h2", "Activity lists recent panel events. Use Errors only to focus on warnings and failures."],
          [".playback-pane .pane-heading h2", "Playback shows the latest validated playlist for one-click resume."]
        ];
        defs.forEach(function (d) {
          try {
            var h = $(d[0]);
            if (!h || h.querySelector(".pnld-help")) return;
            var s = document.createElement("span");
            s.className = "pnld-help";
            s.textContent = "?";
            s.setAttribute("tabindex", "0");
            s.setAttribute("role", "img");
            s.setAttribute("aria-label", d[1]);
            s.setAttribute("data-tip", d[1]);
            s.title = d[1];
            h.appendChild(s);
          } catch (_) {}
        });
      } catch (_) {}
    }

    // PNLD-010 guided first-run checklist (dismiss persists pnld.checklist.done)
    function checklist() {
      try {
        var done = null;
        try { done = localStorage.getItem(CHECK_KEY); } catch (_) {}
        if (done === "1" || document.getElementById("pnld-check")) return;
        var box = document.createElement("div");
        box.id = "pnld-check";
        box.setAttribute("role", "dialog");
        box.setAttribute("aria-label", "First-run checklist");
        box.innerHTML = "<h3>First-run checklist</h3><ul><li>\u2610 Open Jellyfin once</li><li>\u2610 Check all services are healthy</li><li>\u2610 Try search + density above</li></ul><button type='button'>Got it</button>";
        var b = box.querySelector("button");
        if (b) b.addEventListener("click", function () {
          try { try { localStorage.setItem(CHECK_KEY, "1"); } catch (_) {} box.remove(); } catch (_) {}
        });
        document.body.appendChild(box);
      } catch (_) {}
    }

    /* toolbar: additive only */
    try {
      var main = document.getElementById("main") || document.body;
      if (!document.getElementById("pnld-bar")) {
        var bar = document.createElement("div");
        bar.id = "pnld-bar";
        bar.setAttribute("aria-label", "Panel extras");
        bar.innerHTML = "<input type='search' id='pnld-q' placeholder='Search services\u2026' aria-label='Search services'><button type='button' id='pnld-density'>Compact</button><button type='button' id='pnld-mute' aria-pressed='false'>Mute toasts</button><button type='button' id='pnld-exp'>Export prefs</button><label style='cursor:pointer'>Import <input type='file' id='pnld-imp' accept='application/json' hidden></label><span id='pnld-ringhost'></span>";
        var anchor = servicesGrid();
        if (anchor && anchor.parentNode) anchor.parentNode.insertBefore(bar, anchor);
        else main.prepend(bar);
      }
      density($("#pnld-density"));
      search($("#pnld-q"));
      ring($("#pnld-ringhost"));
      prefs($("#pnld-exp"), $("#pnld-imp"));
      mute($("#pnld-mute"));
    } catch (_) {}

    try { favicons(); } catch (_) {}
    try { reorder(); } catch (_) {}
    try { freshBadge(); } catch (_) {}
    try { tips(); } catch (_) {}
    try { checklist(); } catch (_) {}
    setInterval(function () { try { favicons(); tips(); } catch (_) {} }, 5000);
  } catch (_) {}
})();
