(function () {
  "use strict";
  if (typeof window === "undefined") return;
  if (window.__pnlcLoaded) return;
  window.__pnlcLoaded = true;
  try {
    function safe(fn) {
      try { fn(); } catch (_) { /* per-feature guard */ }
    }
    function $(sel, root) {
      try { return (root || document).querySelector(sel); } catch (_) { return null; }
    }
    function $all(sel, root) {
      try { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); } catch (_) { return []; }
    }
    function pnlcToast(msg) {
      try {
        var t = document.getElementById("toast");
        if (t) {
          t.textContent = String(msg);
          t.className = "toast toast-info show";
          clearTimeout(pnlcToast._t);
          pnlcToast._t = setTimeout(function () { try { t.classList.remove("show"); } catch (_) {} }, 2500);
          return;
        }
      } catch (_) {}
    }

    safe(function injectStyle() {
      if (document.getElementById("pnlc-style")) return;
      var css = [
        "#pnlc-toolbar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:0 0 10px;padding:8px 10px;border:1px solid var(--line);border-radius:10px;background:var(--bg);color:var(--text);}",
        "#pnlc-toolbar .pnlc-chips{display:flex;flex-wrap:wrap;gap:6px;align-items:center;}",
        "#pnlc-toolbar .pnlc-chip{font:inherit;font-size:12px;padding:3px 10px;border-radius:999px;border:1px solid var(--line);background:transparent;color:var(--muted);cursor:pointer;}",
        "#pnlc-toolbar .pnlc-chip.is-active{color:var(--text);border-color:var(--accent);}",
        "#pnlc-toolbar .pnlc-btn{font:inherit;font-size:12px;padding:3px 10px;border-radius:8px;border:1px solid var(--line);background:transparent;color:var(--text);cursor:pointer;}",
        "#pnlc-toolbar .pnlc-btn:hover{border-color:var(--accent);}",
        "#pnlc-spark{width:110px;height:26px;border:1px solid var(--line);border-radius:6px;}",
        "#pnlc-ticker{overflow:hidden;white-space:nowrap;border:1px solid var(--line);border-radius:8px;margin:0 0 10px;color:var(--muted);background:var(--bg);}",
        "#pnlc-ticker span{display:inline-block;padding:6px 0;animation:pnlc-scroll 22s linear infinite;}",
        "@keyframes pnlc-scroll{from{transform:translateX(100%);}to{transform:translateX(-100%);}}",
        "#services.pnlc-collapsed{display:none;}",
        "#playback-status.pnlc-collapsed{display:none;}",
        ".service-card.pnlc-selected{outline:2px solid var(--accent);outline-offset:2px;}",
        ".pnlc-row{display:flex;gap:6px;margin-top:8px;align-items:center;}",
        ".pnlc-copy,.pnlc-note-btn{font:inherit;font-size:11.5px;padding:2px 8px;border-radius:7px;border:1px solid var(--line);background:transparent;color:var(--muted);cursor:pointer;}",
        ".pnlc-copy:hover,.pnlc-note-btn:hover{color:var(--text);border-color:var(--accent);}",
        ".pnlc-note{font:inherit;font-size:11.5px;color:var(--text);background:transparent;border:1px solid var(--line);border-radius:7px;padding:2px 6px;width:100%;margin-top:6px;}",
        ".pnlc-note::placeholder{color:var(--muted);}"
      ].join("\n");
      var st = document.createElement("style");
      st.id = "pnlc-style";
      st.textContent = css;
      document.head.appendChild(st);
    });

    var store = {
      filter: "all",
      collapsed: false,
      theme: "auto",
      sel: -1,
      hist: []
    };
    try { store.theme = localStorage.getItem("pnlc.theme") || "auto"; } catch (_) {}

    function serviceCards() { return $all("#services .service-card:not(.skeleton)"); }
    function cardState(card) {
      try {
        var m = /st-(healthy|warning|starting|stopped)/.exec(card.className || "");
        return m ? m[1] : "stopped";
      } catch (_) { return "stopped"; }
    }
    function cardUrl(card) {
      try {
        var addr = $(".svc-addr", card);
        var txt = addr ? addr.textContent.trim() : "";
        var pm = /127\.0\.0\.1:(\d+)/.exec(txt) || /:(\d{2,5})/.exec(txt);
        if (pm) return "http://127.0.0.1:" + pm[1] + "/";
        if (/^https?:\/\//i.test(txt)) return txt;
      } catch (_) {}
      return "";
    }
    function applyFilter() {
      try {
        serviceCards().forEach(function (c) {
          var st = cardState(c);
          var show = store.filter === "all" || st === store.filter ||
            (store.filter === "warn" && (st === "warning" || st === "starting"));
          c.style.display = show ? "" : "none";
        });
        $all("#pnlc-toolbar .pnlc-chip[data-f]").forEach(function (b) {
          try { b.classList.toggle("is-active", b.getAttribute("data-f") === store.filter); } catch (_) {}
        });
      } catch (_) {}
    }
    function applyTheme() {
      try {
        var mode = store.theme;
        var light = false;
        if (mode === "light") light = true;
        else if (mode === "auto" && window.matchMedia) light = !!window.matchMedia("(prefers-color-scheme: light)").matches;
        try { document.documentElement.setAttribute("data-pnlc-theme", light ? "light" : "dark"); } catch (_) {}
        var btn = $("#pnlc-theme-btn");
        if (btn) btn.textContent = "Theme: " + mode;
      } catch (_) {}
    }

    safe(function ensureToolbar() {
      var host = $("#services");
      if (!host || !host.parentElement || $("#pnlc-toolbar")) return;
      var bar = document.createElement("div");
      bar.id = "pnlc-toolbar";
      bar.setAttribute("role", "toolbar");
      bar.setAttribute("aria-label", "Panel conveniences");
      bar.innerHTML = '<div class="pnlc-chips" role="group" aria-label="Quick filter"></div>' +
        '<canvas id="pnlc-spark" width="220" height="52" aria-label="Uptime sparkline" title="Healthy-service history"></canvas>' +
        '<button class="pnlc-btn" id="pnlc-collapse-btn" type="button" title="Collapse/expand service list">Collapse</button>' +
        '<button class="pnlc-btn" id="pnlc-theme-btn" type="button" title="Dark/light auto-follow">Theme: auto</button>' +
        '<button class="pnlc-btn" id="pnlc-export-btn" type="button" title="Export service list as JSON">Export JSON</button>' +
        '<button class="pnlc-btn" id="pnlc-openall-btn" type="button" title="Open all healthy services">Open all healthy</button>';
      host.parentElement.insertBefore(bar, host);
      var tick = document.createElement("div");
      tick.id = "pnlc-ticker";
      tick.setAttribute("aria-live", "off");
      tick.innerHTML = "<span>Panel conveniences loaded.</span>";
      host.parentElement.insertBefore(tick, host);
    });

    // PNLC-001 quick-filter chips for service states
    safe(function f001() {
      var box = $("#pnlc-toolbar .pnlc-chips");
      if (!box) return;
      var defs = [["all", "All"], ["healthy", "Healthy"], ["warn", "Warn"], ["stopped", "Stopped"]];
      defs.forEach(function (d) {
        var b = document.createElement("button");
        b.className = "pnlc-chip" + (store.filter === d[0] ? " is-active" : "");
        b.type = "button";
        b.setAttribute("data-f", d[0]);
        b.textContent = d[1];
        b.addEventListener("click", function () {
          try { store.filter = d[0]; applyFilter(); } catch (_) {}
        });
        box.appendChild(b);
      });
      var svc = $("#services");
      if (svc && window.MutationObserver) {
        var ob = new MutationObserver(function () { try { applyFilter(); enhanceCards(); } catch (_) {} });
        try { ob.observe(svc, { childList: true, subtree: true }); } catch (_) {}
      }
      applyFilter();
    });

    // PNLC-002 collapsible service groups
    safe(function f002() {
      var btn = $("#pnlc-collapse-btn");
      var svc = $("#services");
      var play = $("#playback-status");
      if (!btn || !svc) return;
      btn.addEventListener("click", function () {
        try {
          store.collapsed = !store.collapsed;
          svc.classList.toggle("pnlc-collapsed", store.collapsed);
          if (play) play.classList.toggle("pnlc-collapsed", store.collapsed);
          btn.textContent = store.collapsed ? "Expand" : "Collapse";
        } catch (_) {}
      });
    });

    function enhanceCards() {
      try {
        serviceCards().forEach(function (card) {
          var id = "";
          try { id = card.getAttribute("data-service-id") || ""; } catch (_) {}
          if (!id) return;
          // Shared per-card pass for copy-button + notes enhancers.
          if (!$(".pnlc-row", card)) {
            var row = document.createElement("div");
            row.className = "pnlc-row";
            var copy = document.createElement("button");
            copy.className = "pnlc-copy";
            copy.type = "button";
            copy.textContent = "Copy URL";
            copy.setAttribute("data-pnlc-copy", id);
            copy.addEventListener("click", function (ev) {
              try {
                ev.stopPropagation();
                var url = cardUrl(card);
                if (!url) { pnlcToast("No URL for " + id); return; }
                copyText(url, "URL copied: " + url);
              } catch (_) {}
            });
            row.appendChild(copy);
            var note = document.createElement("input");
            note.className = "pnlc-note";
            note.type = "text";
            note.placeholder = "Note for " + id + "…";
            note.setAttribute("aria-label", "Note for " + id);
            note.setAttribute("data-pnlc-note", id);
            try { note.value = localStorage.getItem("pnlc.note." + id) || ""; } catch (_) {}
            note.addEventListener("change", function () {
              try { localStorage.setItem("pnlc.note." + id, note.value); pnlcToast("Note saved"); } catch (_) {}
            });
            card.appendChild(row);
            card.appendChild(note);
          }
        });
      } catch (_) {}
    }
    function copyText(text, okMsg) {
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(function () { pnlcToast(okMsg); }, function () { fallbackCopy(text, okMsg); });
        } else fallbackCopy(text, okMsg);
      } catch (_) { fallbackCopy(text, okMsg); }
    }
    function fallbackCopy(text, okMsg) {
      try {
        var ta = document.createElement("textarea");
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        ta.remove();
        pnlcToast(okMsg);
      } catch (_) { pnlcToast(text); }
    }

    // PNLC-003 copy service URL button
    safe(function f003() { enhanceCards(); });

    // PNLC-004 uptime sparkline canvas
    safe(function f004() {
      var cv = $("#pnlc-spark");
      if (!cv) return;
      function sample() {
        try {
          var cards = serviceCards();
          var healthy = cards.filter(function (c) { return cardState(c) === "healthy"; }).length;
          store.hist.push(healthy);
          if (store.hist.length > 40) store.hist.shift();
          draw();
        } catch (_) {}
      }
      function draw() {
        try {
          var ctx = cv.getContext("2d");
          if (!ctx) return;
          var W = cv.width, H = cv.height;
          ctx.clearRect(0, 0, W, H);
          var n = store.hist.length;
          if (n < 2) return;
          var max = Math.max.apply(null, store.hist.concat([1]));
          ctx.beginPath();
          store.hist.forEach(function (v, i) {
            var x = (i / (n - 1)) * (W - 4) + 2;
            var y = H - 4 - (v / max) * (H - 8);
            if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
          });
          ctx.strokeStyle = "#4f8cff";
          ctx.lineWidth = 2;
          ctx.stroke();
        } catch (_) {}
      }
      try { setInterval(sample, 5000); } catch (_) {}
      sample();
    });

    // PNLC-005 dark/light auto-follow toggle
    safe(function f005() {
      var btn = $("#pnlc-theme-btn");
      applyTheme();
      if (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)")) {
        try {
          window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", function () {
            try { if (store.theme === "auto") applyTheme(); } catch (_) {}
          });
        } catch (_) {}
      }
      if (!btn) return;
      btn.addEventListener("click", function () {
        try {
          store.theme = store.theme === "auto" ? "dark" : store.theme === "dark" ? "light" : "auto";
          try { localStorage.setItem("pnlc.theme", store.theme); } catch (_) {}
          applyTheme();
        } catch (_) {}
      });
    });

    // PNLC-006 keyboard nav j/k + enter
    safe(function f006() {
      function select(i) {
        try {
          var cards = serviceCards().filter(function (c) { return c.style.display !== "none"; });
          if (!cards.length) return;
          store.sel = Math.max(0, Math.min(cards.length - 1, i));
          cards.forEach(function (c, k) {
            try { c.classList.toggle("pnlc-selected", k === store.sel); } catch (_) {}
          });
          try { cards[store.sel].scrollIntoView({ block: "nearest" }); } catch (_) {}
        } catch (_) {}
      }
      document.addEventListener("keydown", function (ev) {
        try {
          var tag = (ev.target && ev.target.tagName) || "";
          if (/^(INPUT|TEXTAREA|SELECT)$/i.test(tag)) return;
          if (ev.key === "j") select(store.sel + 1);
          else if (ev.key === "k") select(store.sel - 1);
          else if (ev.key === "Enter" && store.sel >= 0) {
            var cards = serviceCards().filter(function (c) { return c.style.display !== "none"; });
            var card = cards[store.sel];
            if (card) {
              var b = $(".svc-actions .btn", card) || $("button", card);
              if (b) b.click();
            }
          } else return;
        } catch (_) {}
      });
    });

    // PNLC-007 service notes (localStorage)
    safe(function f007() { enhanceCards(); });

    // PNLC-008 bulk export service list JSON
    safe(function f008() {
      var btn = $("#pnlc-export-btn");
      if (!btn) return;
      btn.addEventListener("click", function () {
        try {
          var data = serviceCards().map(function (c) {
            var id = "";
            try { id = c.getAttribute("data-service-id") || ""; } catch (_) { id = ""; }
            var name = "";
            try { name = ($(".svc-name", c) || {}).textContent || ""; } catch (_) {}
            var note = "";
            try { note = localStorage.getItem("pnlc.note." + id) || ""; } catch (_) {}
            return { id: id, name: String(name).trim(), state: cardState(c), url: cardUrl(c), note: note };
          });
          var blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
          var a = document.createElement("a");
          a.href = URL.createObjectURL(blob);
          a.download = "services.json";
          document.body.appendChild(a);
          a.click();
          setTimeout(function () { try { URL.revokeObjectURL(a.href); a.remove(); } catch (_) {} }, 500);
          pnlcToast("Exported " + data.length + " services");
        } catch (_) {}
      });
    });

    // PNLC-009 status ticker marquee
    safe(function f009() {
      var tick = $("#pnlc-ticker span");
      if (!tick) return;
      function update() {
        try {
          var label = $("#stack-chip-label");
          var checked = $("#last-checked-text");
          var txt = (label ? label.textContent : "status") + (checked ? " · checked " + checked.textContent : "") + " · " + new Date().toLocaleTimeString();
          tick.textContent = txt;
        } catch (_) {}
      }
      try { setInterval(update, 5000); } catch (_) {}
      update();
    });

    // PNLC-010 one-click open-all healthy services
    safe(function f010() {
      var btn = $("#pnlc-openall-btn");
      if (!btn) return;
      btn.addEventListener("click", function () {
        try {
          var urls = serviceCards()
            .filter(function (c) { return cardState(c) === "healthy"; })
            .map(cardUrl)
            .filter(Boolean);
          if (!urls.length) { pnlcToast("No healthy services to open"); return; }
          urls.forEach(function (u) { try { window.open(u, "_blank", "noopener"); } catch (_) {} });
          pnlcToast("Opened " + urls.length + " healthy service(s)");
        } catch (_) {}
      });
    });

    safe(applyTheme);
  } catch (e) {
    try { console.error("pnlc-pack failed", e); } catch (_) {}
  }
})();
