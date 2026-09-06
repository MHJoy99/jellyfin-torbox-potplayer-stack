"use strict";
/* Panel wins pack: 10 additive UI enhancements. Self-contained IIFE, no new
   dependencies, no backend contract changes. Uses existing element IDs
   (#services, #activity-log, #toast, #refresh-button), existing endpoints
   (/api/health, /api/status, /api/action) and dark-theme vars with fallbacks. */
(function () {
  "use strict";
  try {
    var PNLA = (window.PNLA = window.PNLA || {});

    function safe(name, fn) {
      try {
        fn();
      } catch (err) {
        try {
          if (window.console && console.warn) console.warn("[ppack]", name, err);
        } catch (_) { /* ignore */ }
      }
    }

    function onReady(fn) {
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", fn, { once: true });
      } else {
        fn();
      }
    }

    function esc(value) {
      return String(value == null ? "" : value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");
    }

    // Reuse the panel fetch helper when present; otherwise bare fetch + timeout.
    function pj(url, options, timeoutMs) {
      try {
        if (typeof window.fetchJson === "function") {
          return window.fetchJson(url, options || null, timeoutMs || 20000);
        }
      } catch (_) { /* fall through */ }
      var controller = new AbortController();
      var timer = setTimeout(function () { controller.abort(); }, timeoutMs || 20000);
      return fetch(url, Object.assign({ cache: "no-store", signal: controller.signal }, options || {}))
        .then(function (resp) {
          if (!resp.ok) throw new Error("HTTP " + resp.status);
          return resp.json();
        })
        .finally(function () { clearTimeout(timer); });
    }

    function ensureStyle(id, css) {
      if (document.getElementById(id)) return;
      var style = document.createElement("style");
      style.id = id;
      style.textContent = css;
      document.head.appendChild(style);
    }

    // Subsequence fuzzy score: higher = better; -1 = no match.
    function fuzzyScore(haystack, needle) {
      var h = String(haystack || "").toLowerCase();
      var n = String(needle || "").toLowerCase().trim();
      if (!n) return 0;
      var hi = 0;
      var score = 0;
      var lastAt = -2;
      for (var i = 0; i < n.length; i += 1) {
        var at = h.indexOf(n[i], hi);
        if (at === -1) return -1;
        if (at === lastAt + 1) score += 2;
        else score += 1;
        if (at === 0 || /[\s\-_./:]/.test(h[at - 1])) score += 2;
        lastAt = at;
        hi = at + 1;
      }
      return score;
    }

    function sharedOverlayCss() {
      ensureStyle("pnla-overlay-styles", [
        ".pnla-overlay{position:fixed;inset:0;z-index:9990;background:rgba(3,6,11,.62);",
        "display:flex;align-items:flex-start;justify-content:center;padding:12vh 16px 16px;}",
        ".pnla-overlay[hidden]{display:none;}",
        ".pnla-box{width:min(560px,100%);background:var(--bg-raised,#0b111c);color:var(--text,#e9eef7);",
        "border:1px solid var(--line,rgba(140,170,220,.18));border-radius:12px;overflow:hidden;",
        "box-shadow:0 18px 60px rgba(0,0,0,.5);}",
        ".pnla-input{width:100%;box-sizing:border-box;background:transparent;border:0;outline:0;",
        "color:var(--text,#e9eef7);font:inherit;font-size:15px;padding:14px 16px;",
        "border-bottom:1px solid var(--line,rgba(140,170,220,.18));}",
        ".pnla-list{list-style:none;margin:0;padding:6px;max-height:46vh;overflow:auto;}",
        ".pnla-item{padding:9px 10px;border-radius:8px;cursor:pointer;font-size:13.5px;color:var(--text,#e9eef7);}",
        ".pnla-item small{display:block;color:var(--muted,#7d8ca3);font-size:11.5px;}",
        ".pnla-item.is-active{background:var(--accent-soft,rgba(79,140,255,.14));outline:1px solid var(--accent-ring,rgba(79,140,255,.4));}",
        ".pnla-hint{padding:8px 14px;color:var(--muted,#7d8ca3);font-size:11.5px;",
        "border-top:1px solid var(--line,rgba(140,170,220,.18));}",
        ".pnla-flash{outline:2px solid var(--accent,#4f8cff) !important;outline-offset:2px;transition:outline-color 1.2s;}",
      ].join("\n"));
    }

    // PNLA-001
    function initSearch() {
      sharedOverlayCss();
      var overlay = document.createElement("div");
      overlay.className = "pnla-overlay";
      overlay.hidden = true;
      overlay.innerHTML =
        '<div class="pnla-box" role="dialog" aria-modal="true" aria-label="Search cards">' +
        '<input class="pnla-input" type="text" placeholder="Search cards…" aria-label="Search cards">' +
        '<ul class="pnla-list" role="listbox" aria-label="Matching cards"></ul>' +
        '<div class="pnla-hint">↑↓ navigate · Enter jumps to card · Esc closes</div></div>';
      document.body.appendChild(overlay);
      var input = overlay.querySelector(".pnla-input");
      var list = overlay.querySelector(".pnla-list");
      var active = 0;
      var current = [];

      function collectTargets() {
        return Array.prototype.slice.call(
          document.querySelectorAll(".service-card:not(.skeleton), .playback-card:not(.skeleton)"),
        ).map(function (card) {
          var titleEl = card.querySelector(".svc-name, h3");
          var detailEl = card.querySelector(".svc-detail, .playback-copy p");
          return {
            el: card,
            title: titleEl ? titleEl.textContent.trim() : card.getAttribute("data-service-id") || "Card",
            detail: detailEl ? detailEl.textContent.trim().slice(0, 120) : "",
          };
        });
      }

      function renderMatches() {
        var q = input.value;
        current = collectTargets()
          .map(function (t) { return { t: t, s: fuzzyScore(t.title + " " + t.detail, q) }; })
          .filter(function (r) { return r.s >= 0; })
          .sort(function (a, b) { return b.s - a.s; })
          .slice(0, 30);
        active = 0;
        list.innerHTML = current.length
          ? current.map(function (r, i) {
            return '<li class="pnla-item' + (i === 0 ? " is-active" : "") + '" role="option" data-i="' + i + '">' +
              esc(r.t.title) + "<small>" + esc(r.t.detail) + "</small></li>";
          }).join("")
          : '<li class="pnla-item" aria-disabled="true">No matching cards<small>Try a shorter query</small></li>';
      }

      function setActive(i) {
        active = (i + current.length) % Math.max(1, current.length);
        list.querySelectorAll(".pnla-item").forEach(function (li, j) {
          li.classList.toggle("is-active", j === active);
        });
        var sel = list.querySelector(".pnla-item.is-active");
        if (sel && sel.scrollIntoView) sel.scrollIntoView({ block: "nearest" });
      }

      function choose() {
        var hit = current[active];
        if (!hit) return;
        close();
        try {
          hit.t.el.scrollIntoView({ behavior: "smooth", block: "center" });
          hit.t.el.classList.add("pnla-flash");
          setTimeout(function () { hit.t.el.classList.remove("pnla-flash"); }, 1400);
        } catch (_) { /* scroll best-effort */ }
      }

      function open() { overlay.hidden = false; input.value = ""; renderMatches(); input.focus(); }
      function close() { overlay.hidden = true; }

      list.addEventListener("click", function (ev) {
        var li = ev.target.closest(".pnla-item[data-i]");
        if (!li) return;
        active = Number(li.getAttribute("data-i")) || 0;
        choose();
      });
      input.addEventListener("input", renderMatches);
      input.addEventListener("keydown", function (ev) {
        if (ev.key === "ArrowDown") { ev.preventDefault(); setActive(active + 1); }
        else if (ev.key === "ArrowUp") { ev.preventDefault(); setActive(active - 1); }
        else if (ev.key === "Enter") { ev.preventDefault(); choose(); }
        else if (ev.key === "Escape") { ev.preventDefault(); close(); }
      });
      overlay.addEventListener("click", function (ev) { if (ev.target === overlay) close(); });
      document.addEventListener("keydown", function (ev) {
        var tag = (document.activeElement && document.activeElement.tagName) || "";
        var typing = /^(INPUT|TEXTAREA|SELECT)$/.test(tag);
        if ((ev.ctrlKey || ev.metaKey) && !ev.shiftKey && (ev.key === "k" || ev.key === "K")) {
          if (typing && !overlay.hidden) return;
          ev.preventDefault();
          if (overlay.hidden) open(); else close();
        } else if (ev.key === "Escape" && !overlay.hidden) {
          close();
        }
      });
      PNLA.search = { open: open, close: close };
    }

    // PNLA-002
    function initPalette() {
      sharedOverlayCss();
      var overlay = document.createElement("div");
      overlay.className = "pnla-overlay";
      overlay.hidden = true;
      overlay.innerHTML =
        '<div class="pnla-box" role="dialog" aria-modal="true" aria-label="Command palette">' +
        '<input class="pnla-input" type="text" placeholder="Type a command…" aria-label="Command palette">' +
        '<ul class="pnla-list" role="listbox" aria-label="Commands"></ul>' +
        '<div class="pnla-hint">↑↓ navigate · Enter runs · Esc closes · read-only discovery</div></div>';
      document.body.appendChild(overlay);
      var input = overlay.querySelector(".pnla-input");
      var list = overlay.querySelector(".pnla-list");
      var active = 0;
      var current = [];

      // Read-only discovery: derive runnable commands from existing panel controls.
      function discover() {
        var cmds = [];
        Array.prototype.forEach.call(document.querySelectorAll("button[data-action]"), function (btn) {
          var action = btn.getAttribute("data-action") || "";
          var service = btn.getAttribute("data-service") || "";
          if (!action || btn.disabled || btn.closest("#pnla-bulkbar")) return;
          var label = (action.charAt(0).toUpperCase() + action.slice(1)) + (service ? " " + service : "");
          cmds.push({
            label: label,
            hint: "Runs the existing panel button",
            run: function () { btn.click(); },
          });
        });
        function clickBy(sel, label, hint) {
          var el = document.querySelector(sel);
          if (!el) return;
          cmds.push({ label: label, hint: hint, run: function () { el.click(); } });
        }
        clickBy("#refresh-button", "Refresh status now", "Re-polls the existing status endpoints");
        clickBy("#open-jellyfin", "Open Jellyfin", "Opens the existing Jellyfin link");
        var errorsOnly = document.querySelector("#activity-errors-only");
        if (errorsOnly) {
          cmds.push({
            label: "Toggle errors-only filter",
            hint: "Flips the existing activity filter",
            run: function () { errorsOnly.click(); },
          });
        }
        var log = document.querySelector("#activity-log");
        if (log) {
          cmds.push({
            label: "Open logs",
            hint: "Scrolls to the existing activity list",
            run: function () { log.scrollIntoView({ behavior: "smooth", block: "start" }); },
          });
        }
        // De-dupe by label, keep first occurrence.
        var seen = {};
        return cmds.filter(function (c) {
          if (seen[c.label]) return false;
          seen[c.label] = true;
          return true;
        });
      }

      function render() {
        var q = input.value;
        current = discover()
          .map(function (c) { return { c: c, s: fuzzyScore(c.label + " " + c.hint, q) }; })
          .filter(function (r) { return r.s >= 0; })
          .sort(function (a, b) { return b.s - a.s; })
          .slice(0, 30);
        active = 0;
        list.innerHTML = current.length
          ? current.map(function (r, i) {
            return '<li class="pnla-item' + (i === 0 ? " is-active" : "") + '" role="option" data-i="' + i + '">' +
              esc(r.c.label) + "<small>" + esc(r.c.hint) + "</small></li>";
          }).join("")
          : '<li class="pnla-item" aria-disabled="true">No matching command</li>';
      }

      function setActive(i) {
        if (!current.length) return;
        active = (i + current.length) % current.length;
        list.querySelectorAll(".pnla-item").forEach(function (li, j) {
          li.classList.toggle("is-active", j === active);
        });
      }

      function run() {
        var hit = current[active];
        if (!hit) return;
        close();
        try { hit.c.run(); } catch (err) {
          safe("palette-run", function () { throw err; });
        }
      }

      function open() { overlay.hidden = false; input.value = ""; render(); input.focus(); }
      function close() { overlay.hidden = true; }

      list.addEventListener("click", function (ev) {
        var li = ev.target.closest(".pnla-item[data-i]");
        if (!li) return;
        active = Number(li.getAttribute("data-i")) || 0;
        run();
      });
      input.addEventListener("input", render);
      input.addEventListener("keydown", function (ev) {
        if (ev.key === "ArrowDown") { ev.preventDefault(); setActive(active + 1); }
        else if (ev.key === "ArrowUp") { ev.preventDefault(); setActive(active - 1); }
        else if (ev.key === "Enter") { ev.preventDefault(); run(); }
        else if (ev.key === "Escape") { ev.preventDefault(); close(); }
      });
      overlay.addEventListener("click", function (ev) { if (ev.target === overlay) close(); });
      document.addEventListener("keydown", function (ev) {
        if ((ev.ctrlKey || ev.metaKey) && ev.shiftKey && (ev.key === "P" || ev.key === "p")) {
          ev.preventDefault();
          if (overlay.hidden) open(); else close();
        } else if (ev.key === "Escape" && !overlay.hidden) {
          close();
        }
      });
      PNLA.palette = { open: open, close: close };
    }

    // PNLA-003
    function initStats() {
      ensureStyle("pnla-stats-styles", [
        "#pnla-stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-bottom:14px;}",
        ".pnla-stat{background:var(--bg-raised,#0b111c);border:1px solid var(--line,rgba(140,170,220,.18));",
        "border-radius:10px;padding:10px 14px;}",
        ".pnla-stat span{display:block;font-size:11px;color:var(--muted,#7d8ca3);text-transform:uppercase;letter-spacing:.06em;}",
        ".pnla-stat strong{font-size:20px;color:var(--text,#e9eef7);}",
        ".pnla-stat small{color:var(--muted,#7d8ca3);font-size:11px;}",
      ].join("\n"));

      var main = document.querySelector("main.shell, main");
      if (!main || document.getElementById("pnla-stats")) return;
      var row = document.createElement("div");
      row.id = "pnla-stats";
      row.setAttribute("aria-live", "polite");
      row.setAttribute("aria-label", "Dashboard summary");
      var anchor = main.querySelector(".columns");
      main.insertBefore(row, anchor || main.firstChild);

      function paint(servicesUp, servicesTotal, items, extra) {
        row.innerHTML =
          '<div class="pnla-stat"><span>Services up</span><strong>' + esc(servicesUp) + " / " + esc(servicesTotal) +
          "</strong> <small>healthy</small></div>" +
          '<div class="pnla-stat"><span>Activity items</span><strong>' + esc(items) +
          "</strong> <small>rendered</small></div>" +
          '<div class="pnla-stat"><span>Panel</span><strong>' + esc(extra) +
          "</strong> <small>status</small></div>";
      }

      function activityCount() {
        var log = document.getElementById("activity-log");
        if (!log) return 0;
        return log.querySelectorAll(".act-item").length;
      }

      function refresh() {
        pj("/api/health", null, 8000).then(function (health) {
          var services = (health && (health.services || health.checks || health.stack)) || {};
          var keys = Object.keys(services);
          var up = keys.filter(function (k) {
            var s = services[k];
            var st = String((s && (s.state || s.status)) || "").toLowerCase();
            return st === "healthy" || st === "up" || st === "running" || s === true;
          }).length;
          var total = keys.length || 5;
          return pj("/api/status", null, 8000).then(function (status) {
            var label = "live";
            if (status && status.version) label = "v" + String(status.version).slice(0, 12);
            else if (status && status.ok === false) label = "degraded";
            paint(up, total, activityCount(), label);
          }).catch(function () {
            paint(up, total, activityCount(), "live");
          });
        }).catch(function () {
          // Fallback: count healthy badges already rendered in the DOM.
          var cards = document.querySelectorAll("#services .service-card:not(.skeleton)");
          var up = document.querySelectorAll("#services .badge-healthy").length;
          paint(up, cards.length || "–", activityCount(), "cached");
        });
      }

      paint("–", "–", activityCount(), "…");
      refresh();
      setInterval(refresh, 15000);
      new MutationObserver(function () {
        // Keep the items count fresh as the activity list re-renders.
        var strong = row.querySelectorAll(".pnla-stat strong")[1];
        if (strong) strong.textContent = String(activityCount());
      }).observe(document.getElementById("activity-log") || document.body, {
        childList: true,
        subtree: true,
      });
    }

    // PNLA-004
    function initSkeleton() {
      ensureStyle("pnla-skeleton-styles", [
        "@keyframes pnla-shimmer{0%{background-position:-400px 0;}100%{background-position:400px 0;}}",
        ".pnla-shimmer .sk,.pnla-shimmer.sk{background:linear-gradient(90deg,",
        "var(--bg-raised,#0b111c) 25%,var(--surface-hover,#1a2740) 50%,var(--bg-raised,#0b111c) 75%);",
        "background-size:800px 100%;animation:pnla-shimmer 1.3s linear infinite;border-radius:6px;min-height:12px;}",
      ].join("\n"));

      // JS hook: render N shimmer placeholder rows inside any container.
      PNLA.skeleton = function (container, count) {
        var host = typeof container === "string" ? document.querySelector(container) : container;
        if (!host) return;
        var n = Math.max(1, Math.min(8, Number(count) || 3));
        var html = "";
        for (var i = 0; i < n; i += 1) {
          html += '<div class="pnla-shimmer" aria-hidden="true"><div class="sk sk-w80"></div>' +
            '<div class="sk sk-w60"></div></div>';
        }
        host.innerHTML = html;
      };

      // Tag the panel's own loading skeletons so they shimmer while lists load.
      new MutationObserver(function () {
        document.querySelectorAll("#services .service-card.skeleton, #playback-status .skeleton").forEach(function (el) {
          el.classList.add("pnla-shimmer");
        });
      }).observe(document.documentElement, { childList: true, subtree: true });
    }

    // PNLA-005
    function initEmptyStates() {
      ensureStyle("pnla-empty-styles", [
        ".pnla-empty{border:1px dashed var(--line-strong,rgba(140,170,220,.4));border-radius:12px;",
        "padding:22px 18px;text-align:center;color:var(--muted,#7d8ca3);font-size:13px;}",
        ".pnla-empty h3{margin:0 0 6px;color:var(--text,#e9eef7);font-size:15px;}",
        ".pnla-empty p{margin:0 0 12px;}",
        ".pnla-empty .btn{cursor:pointer;}",
      ].join("\n"));

      PNLA.emptyState = function (container, opts) {
        var host = typeof container === "string" ? document.querySelector(container) : container;
        if (!host || host.querySelector(":scope > .pnla-empty")) return null;
        var o = opts || {};
        var box = document.createElement("div");
        box.className = "pnla-empty";
        box.innerHTML = "<h3>" + esc(o.title || "Nothing here yet") + "</h3><p>" +
          esc(o.hint || "Get started with the next step below.") + "</p>";
        if (o.actionLabel) {
          var btn = document.createElement("button");
          btn.type = "button";
          btn.className = "btn btn-primary btn-sm";
          btn.textContent = o.actionLabel;
          btn.addEventListener("click", function () {
            try {
              if (typeof o.onAction === "function") o.onAction();
            } catch (err) { safe("empty-action", function () { throw err; }); }
          });
          box.appendChild(btn);
        }
        host.appendChild(box);
        return box;
      };

      function startAll() {
        var btn = document.querySelector('.global-actions [data-action="start"]');
        if (btn) btn.click();
      }

      function refreshNow() {
        var btn = document.getElementById("refresh-button");
        if (btn) btn.click();
      }

      // Friendly empty states for empty libraries/lists, with a next-step button.
      new MutationObserver(function () {
        var services = document.getElementById("services");
        if (services && !services.querySelector(".service-card") && !services.querySelector(":scope > .pnla-empty")) {
          PNLA.emptyState(services, {
            title: "No services to show",
            hint: "The service list is empty. Start the stack or refresh to reload it.",
            actionLabel: "Start all services",
            onAction: startAll,
          });
        }
        var log = document.getElementById("activity-log");
        if (log && log.querySelector(".act-empty") && !log.querySelector(":scope > .pnla-empty")) {
          PNLA.emptyState(log, {
            title: "No activity yet",
            hint: "No panel actions have been recorded. Refresh to check for recent activity.",
            actionLabel: "Refresh status",
            onAction: refreshNow,
          });
        }
      }).observe(document.documentElement, { childList: true, subtree: true });
    }

    // PNLA-006
    function initToasts() {
      ensureStyle("pnla-toast-styles", [
        "#pnla-toasts{position:fixed;right:16px;bottom:16px;z-index:9995;display:flex;flex-direction:column;gap:8px;",
        "max-width:min(360px,calc(100vw - 32px));}",
        ".pnla-toast{display:flex;align-items:center;gap:10px;background:var(--bg-raised,#0b111c);",
        "color:var(--text,#e9eef7);border:1px solid var(--line,rgba(140,170,220,.18));border-radius:10px;",
        "padding:10px 12px;font-size:13px;box-shadow:0 10px 30px rgba(0,0,0,.45);}",
        ".pnla-toast[data-kind='success']{border-color:var(--green,#3ecf8e);}",
        ".pnla-toast[data-kind='warn']{border-color:var(--amber,#f0b35c);}",
        ".pnla-toast[data-kind='error']{border-color:var(--red,#f06a6a);}",
        ".pnla-toast button{flex:none;cursor:pointer;font:inherit;font-size:12px;border-radius:7px;padding:4px 10px;",
        "border:1px solid var(--accent-ring,rgba(79,140,255,.4));background:var(--accent-soft,rgba(79,140,255,.14));",
        "color:var(--text,#e9eef7);}",
      ].join("\n"));

      var host = document.createElement("div");
      host.id = "pnla-toasts";
      host.setAttribute("aria-live", "polite");
      document.body.appendChild(host);

      var queue = [];
      var visible = 0;
      var MAX_VISIBLE = 3;

      function pump() {
        while (visible < MAX_VISIBLE && queue.length) {
          var job = queue.shift();
          visible += 1;
          show(job);
        }
      }

      function show(job) {
        var el = document.createElement("div");
        el.className = "pnla-toast";
        el.setAttribute("data-kind", job.kind);
        el.setAttribute("role", "status");
        var msg = document.createElement("span");
        msg.textContent = job.message;
        el.appendChild(msg);
        var done = false;
        function dismiss() {
          if (done) return;
          done = true;
          clearTimeout(timer);
          if (el.parentElement) el.parentElement.removeChild(el);
          visible -= 1;
          pump();
        }
        if (job.actionLabel && typeof job.onAction === "function") {
          var btn = document.createElement("button");
          btn.type = "button";
          btn.textContent = job.actionLabel;
          btn.addEventListener("click", function () {
            try { job.onAction(); } catch (err) { safe("toast-action", function () { throw err; }); }
            dismiss();
          });
          el.appendChild(btn);
        }
        host.appendChild(el);
        var timer = setTimeout(dismiss, job.durationMs);
        job.dismiss = dismiss;
      }

      // Toast notification helper: success / warn / error (+ info), auto-dismiss, queue.
      PNLA.toast = function (message, kind, opts) {
        var o = opts || {};
        var k = ["success", "warn", "error", "info"].indexOf(kind) !== -1 ? kind : "info";
        queue.push({
          message: String(message == null ? "" : message),
          kind: k,
          durationMs: Math.max(1500, Math.min(15000, Number(o.durationMs) || 4200)),
          actionLabel: o.actionLabel,
          onAction: o.onAction,
        });
        pump();
      };
    }

    // PNLA-007
    function initUndo() {
      // Arm the undo window only for confirmed destructive stops (precise signal,
      // so cancelling the confirm modal never shows a toast).
      document.addEventListener("ui:confirmed-action", function (ev) {
        var detail = (ev && ev.detail) || {};
        if (detail.action !== "stop") return;
        var service = String(detail.service || "service");
        if (service === "all") return; // too broad to auto-restore; skip
        try {
          PNLA.toast("Stopped " + service + " — undo available for 5s", "warn", {
            durationMs: 5000,
            actionLabel: "Undo",
            onAction: function () {
              pj("/api/action", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ service: service, action: "start" }),
              }, 120000).then(function () {
                PNLA.toast("Restarted " + service, "success");
              }).catch(function (err) {
                PNLA.toast("Undo failed: " + (err && err.message ? err.message : err), "error");
              });
            },
          });
        } catch (_) { /* toast best-effort */ }
      });
    }

    // PNLA-008
    function initBulkSelect() {
      ensureStyle("pnla-bulk-styles", [
        "#pnla-bulkbar{position:fixed;left:50%;transform:translateX(-50%);bottom:16px;z-index:9994;",
        "display:flex;align-items:center;gap:10px;background:var(--bg-raised,#0b111c);color:var(--text,#e9eef7);",
        "border:1px solid var(--accent-ring,rgba(79,140,255,.4));border-radius:12px;padding:10px 14px;font-size:13px;",
        "box-shadow:0 10px 30px rgba(0,0,0,.45);}",
        "#pnla-bulkbar[hidden]{display:none;}",
        "#pnla-bulkbar .btn{cursor:pointer;}",
        ".pnla-pick{position:absolute;top:8px;right:8px;width:16px;height:16px;accent-color:var(--accent,#4f8cff);cursor:pointer;}",
        ".service-card{position:relative;}",
      ].join("\n"));

      var pane = document.querySelector(".services-pane .pane-actions, .services-pane .pane-heading");
      var grid = document.getElementById("services");
      if (!grid) return;
      var selecting = false;

      var toggle = document.createElement("button");
      toggle.type = "button";
      toggle.className = "btn btn-secondary btn-sm";
      toggle.textContent = "Select";
      toggle.setAttribute("aria-pressed", "false");
      if (pane) pane.appendChild(toggle);
      else grid.parentElement.insertBefore(toggle, grid);

      var bar = document.createElement("div");
      bar.id = "pnla-bulkbar";
      bar.hidden = true;
      bar.innerHTML =
        '<strong id="pnla-bulkcount">0 selected</strong>' +
        '<button type="button" class="btn btn-primary btn-sm" data-bulk="start">Start</button>' +
        '<button type="button" class="btn btn-secondary btn-sm" data-bulk="restart">Restart</button>' +
        '<button type="button" class="btn btn-secondary btn-sm" data-bulk="stop">Stop</button>' +
        '<button type="button" class="btn btn-ghost btn-sm" data-bulk="clear">Clear</button>';
      document.body.appendChild(bar);
      var countEl = bar.querySelector("#pnla-bulkcount");

      function selectedIds() {
        return Array.prototype.map.call(
          grid.querySelectorAll(".pnla-pick:checked"),
          function (box) {
            var card = box.closest(".service-card");
            return card ? card.getAttribute("data-service-id") : null;
          },
        ).filter(Boolean);
      }

      function updateCount() {
        var n = selectedIds().length;
        countEl.textContent = n + " selected";
      }

      function setSelecting(on) {
        selecting = on;
        toggle.setAttribute("aria-pressed", on ? "true" : "false");
        toggle.textContent = on ? "Done" : "Select";
        bar.hidden = !on;
        grid.querySelectorAll(".service-card").forEach(function (card) {
          var box = card.querySelector(":scope > .pnla-pick");
          if (on && !box && !card.classList.contains("skeleton")) {
            box = document.createElement("input");
            box.type = "checkbox";
            box.className = "pnla-pick";
            box.setAttribute("aria-label", "Select service");
            box.addEventListener("change", updateCount);
            card.appendChild(box);
          } else if (!on && box) {
            box.remove();
          }
        });
        if (on) updateCount();
      }

      toggle.addEventListener("click", function () { setSelecting(!selecting); });

      grid.addEventListener("change", function (ev) {
        if (ev.target && ev.target.classList && ev.target.classList.contains("pnla-pick")) updateCount();
      });

      bar.addEventListener("click", function (ev) {
        var btn = ev.target.closest("button[data-bulk]");
        if (!btn) return;
        var kind = btn.getAttribute("data-bulk");
        var ids = selectedIds();
        if (kind === "clear") {
          grid.querySelectorAll(".pnla-pick:checked").forEach(function (box) { box.checked = false; });
          updateCount();
          return;
        }
        if (!ids.length) {
          PNLA.toast("Nothing selected", "warn");
          return;
        }
        // Bulk run via the existing action endpoint, one request per service.
        var pending = ids.slice();
        var failed = 0;
        (function next() {
          var id = pending.shift();
          if (!id) {
            PNLA.toast(
              failed ? ("Bulk " + kind + " finished with " + failed + " failure(s)") : ("Bulk " + kind + " done for " + ids.length + " service(s)"),
              failed ? "warn" : "success",
            );
            return;
          }
          pj("/api/action", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ service: id, action: kind }),
          }, 300000).then(next, function () { failed += 1; next(); });
        })();
      });

      // Keep checkboxes in sync across panel re-renders while select mode is on.
      new MutationObserver(function () {
        if (!selecting) return;
        grid.querySelectorAll(".service-card:not(.skeleton)").forEach(function (card) {
          if (!card.querySelector(":scope > .pnla-pick")) {
            var box = document.createElement("input");
            box.type = "checkbox";
            box.className = "pnla-pick";
            box.setAttribute("aria-label", "Select service");
            box.addEventListener("change", updateCount);
            card.appendChild(box);
          }
        });
      }).observe(grid, { childList: true, subtree: true });
    }

    // PNLA-009
    function initCardOrder() {
      var KEY = "jellyfin.panel.cardOrder";
      var grid = document.getElementById("services");
      if (!grid) return;

      function load() {
        try {
          var raw = localStorage.getItem(KEY);
          var arr = raw ? JSON.parse(raw) : null;
          return Array.isArray(arr) ? arr.map(String) : [];
        } catch (_) { return []; }
      }

      function save() {
        try {
          var ids = Array.prototype.map.call(
            grid.querySelectorAll(".service-card[data-service-id]"),
            function (card) { return card.getAttribute("data-service-id"); },
          );
          localStorage.setItem(KEY, JSON.stringify(ids));
        } catch (_) { /* storage unavailable */ }
      }

      function apply() {
        var order = load();
        if (!order.length) return;
        var byId = {};
        Array.prototype.forEach.call(grid.querySelectorAll(".service-card[data-service-id]"), function (card) {
          byId[card.getAttribute("data-service-id")] = card;
        });
        order.forEach(function (id) {
          if (byId[id]) grid.appendChild(byId[id]);
        });
      }

      var dragging = null;
      grid.addEventListener("dragstart", function (ev) {
        var card = ev.target.closest ? ev.target.closest(".service-card[data-service-id]") : null;
        if (!card || card.classList.contains("skeleton")) return;
        dragging = card;
        try { ev.dataTransfer.effectAllowed = "move"; } catch (_) { /* ignore */ }
      });
      grid.addEventListener("dragover", function (ev) {
        if (!dragging) return;
        var over = ev.target.closest ? ev.target.closest(".service-card[data-service-id]") : null;
        if (!over || over === dragging) return;
        ev.preventDefault();
        var rect = over.getBoundingClientRect();
        var after = (ev.clientY - rect.top) > rect.height / 2;
        grid.insertBefore(dragging, after ? over.nextSibling : over);
      });
      grid.addEventListener("drop", function (ev) {
        if (!dragging) return;
        ev.preventDefault();
        dragging = null;
        save();
        try { PNLA.toast("Card order saved", "success"); } catch (_) { /* ignore */ }
      });
      grid.addEventListener("dragend", function () { dragging = null; });

      // Drag-and-drop library ordering: tag cards draggable + re-apply persisted order.
      new MutationObserver(function () {
        grid.querySelectorAll(".service-card[data-service-id]:not(.skeleton)").forEach(function (card) {
          if (!card.hasAttribute("draggable")) {
            card.setAttribute("draggable", "true");
            card.title = (card.title ? card.title + " · " : "") + "Drag to reorder";
          }
        });
        apply();
      }).observe(grid, { childList: true, subtree: true });
      apply();
    }

    // PNLA-010
    function initRename() {
      var KEY = "jellyfin.panel.nameAlias";
      // No rename endpoint exists on the backend, so aliases are stored locally
      // (additive only, zero API contract change) and applied as label overrides.
      function load() {
        try {
          var raw = localStorage.getItem(KEY);
          var obj = raw ? JSON.parse(raw) : null;
          return obj && typeof obj === "object" ? obj : {};
        } catch (_) { return {}; }
      }

      function save(map) {
        try { localStorage.setItem(KEY, JSON.stringify(map)); } catch (_) { /* ignore */ }
      }

      function apply() {
        var map = load();
        document.querySelectorAll("#services .service-card[data-service-id]").forEach(function (card) {
          var id = card.getAttribute("data-service-id");
          var nameEl = card.querySelector(".svc-name");
          if (!nameEl || !map[id] || nameEl.querySelector("input")) return;
          if (nameEl.textContent.trim() !== String(map[id])) nameEl.textContent = String(map[id]);
        });
      }

      document.getElementById("services").addEventListener("dblclick", function (ev) {
        var nameEl = ev.target.closest ? ev.target.closest(".svc-name") : null;
        if (!nameEl || nameEl.querySelector("input")) return;
        var card = nameEl.closest(".service-card[data-service-id]");
        if (!card) return;
        var id = card.getAttribute("data-service-id");
        var original = nameEl.textContent;
        var input = document.createElement("input");
        input.type = "text";
        input.value = original.trim();
        input.setAttribute("aria-label", "Rename service label");
        input.style.cssText = "font:inherit;color:var(--text,#e9eef7);background:var(--bg,#070b12);" +
          "border:1px solid var(--accent,#4f8cff);border-radius:6px;padding:2px 6px;max-width:100%;";
        nameEl.textContent = "";
        nameEl.appendChild(input);
        input.focus();
        input.select();
        var done = false;
        function cancel() {
          if (done) return;
          done = true;
          nameEl.textContent = original;
        }
        function commit() {
          if (done) return;
          done = true;
          var next = input.value.trim();
          if (!next) {
            nameEl.textContent = original;
            return;
          }
          var map = load();
          map[id] = next;
          save(map);
          nameEl.textContent = next;
          try { PNLA.toast("Label saved", "success"); } catch (_) { /* ignore */ }
        }
        input.addEventListener("keydown", function (kev) {
          if (kev.key === "Enter") { kev.preventDefault(); commit(); }
          else if (kev.key === "Escape") { kev.preventDefault(); cancel(); }
          kev.stopPropagation();
        });
        input.addEventListener("blur", commit);
      });

      new MutationObserver(apply).observe(document.getElementById("services"), { childList: true, subtree: true });
      apply();
    }

    onReady(function () {
      safe("search", initSearch);
      safe("palette", initPalette);
      safe("stats", initStats);
      safe("skeleton", initSkeleton);
      safe("empty", initEmptyStates);
      safe("toasts", initToasts);
      safe("undo", initUndo);
      safe("bulk", initBulkSelect);
      safe("order", initCardOrder);
      safe("rename", initRename);
    });
  } catch (err) {
    try {
      if (window.console && console.error) console.error("[ppack] fatal", err);
    } catch (_) { /* ignore */ }
  }
})();
