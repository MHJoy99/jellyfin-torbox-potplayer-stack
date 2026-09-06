"use strict";
/* smrt2-pack: second smart wins, additive read-only; no /api changes. */
(function smrt2Pack() {
  if (typeof window === "undefined" || typeof document === "undefined") return;
  if (window.__smt2Loaded) return;
  window.__smt2Loaded = true;

  var STATUS_URL = "/api/status";
  var METRICS_URL = "/api/metrics";
  var SECTION_ID = "smt2-collections";
  var FETCH_TIMEOUT_MS = 8000;

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function fetchJson(url, timeoutMs) {
    var ctrl = null;
    var timer = null;
    try {
      if (typeof AbortController !== "undefined") ctrl = new AbortController();
    } catch (_) {
      ctrl = null;
    }
    var opts = {};
    if (ctrl) {
      opts.signal = ctrl.signal;
      timer = setTimeout(function () {
        try { ctrl.abort(); } catch (_) { /* noop */ }
      }, timeoutMs || FETCH_TIMEOUT_MS);
    }
    return fetch(url, opts).then(function (res) {
      if (timer) clearTimeout(timer);
      if (!res || !res.ok) throw new Error("bad status " + (res && res.status));
      return res.json();
    }).catch(function (err) {
      if (timer) clearTimeout(timer);
      throw err;
    });
  }

  function readPageItems() {
    var out = [];
    try {
      var nodes = document.querySelectorAll("[data-title], .media-item, .library-item, tr[data-item]");
      nodes.forEach(function (n) {
        var title = n.getAttribute("data-title") || n.getAttribute("data-name") ||
          (n.querySelector(".title, .name, td:first-child") || {}).textContent || "";
        title = String(title).trim();
        if (!title) return;
        var year = n.getAttribute("data-year") || "";
        var ym = String(n.textContent || "").match(/\b(19\d{2}|20\d{2})\b/);
        if (!ym && year) ym = [year, year];
        out.push({
          title: title,
          year: ym ? ym[1] : "",
          genre: n.getAttribute("data-genre") || "",
          progress: n.getAttribute("data-progress") || "",
          el: null
        });
      });
    } catch (_) { /* DOM read best-effort */ }
    return out;
  }

  // SMT2-001 auto-group collections by genre
  function groupByGenre(items) {
    var groups = {};
    items.forEach(function (it) {
      var g = (it.genre || "Unsorted").trim() || "Unsorted";
      if (!groups[g]) groups[g] = [];
      groups[g].push(it);
    });
    return groups;
  }

  // SMT2-002 duplicate finder (same title+year)
  function findDuplicates(items) {
    var seen = {};
    var dups = [];
    items.forEach(function (it) {
      var key = (it.title || "").toLowerCase().trim() + "|" + (it.year || "").trim();
      if (!key || key === "|") return;
      if (seen[key]) {
        if (seen[key] !== true) { dups.push(it); seen[key] = true; }
        else dups.push(it);
      } else {
        seen[key] = false;
      }
    });
    return dups;
  }

  // SMT2-003 missing-episode hint
  function missingEpisodeHint(playback) {
    if (!playback) return "";
    var expected = Number(playback.expected_entries || playback.entries || 0);
    var entries = Number(playback.entries || 0);
    if (expected > 0 && entries >= 0 && entries < expected) {
      return "Missing ~" + (expected - entries) + " episode(s) vs expected " + expected + ".";
    }
    return "";
  }

  // SMT2-004 next-up recommender
  function nextUp(items, playback) {
    var hint = playback && (playback.show || playback.next || playback.last_play);
    if (hint && typeof hint === "object") hint = hint.show || hint.title || "";
    if (hint) return String(hint);
    var withProgress = items.filter(function (i) { return i.progress !== ""; });
    if (withProgress.length) return withProgress[0].title;
    return items.length ? items[0].title : "";
  }

  // SMT2-005 quota forecast chip
  function quotaChip(metrics) {
    try {
      var q = (metrics && (metrics.quota || metrics.disk || metrics.usage)) || null;
      if (!q) return "";
      var pct = Number(q.pct ?? q.percent ?? q.used_pct ?? NaN);
      if (Number.isFinite(pct)) {
        var days = Math.max(0, Math.round((100 - pct) / 2));
        return "Quota " + pct + "% — ~" + days + "d headroom at current pace.";
      }
      if (q.used != null && q.total != null) return "Quota " + esc(q.used) + " / " + esc(q.total) + ".";
    } catch (_) { /* noop */ }
    return "";
  }

  // SMT2-006 bandwidth saver toggle hint
  function bandwidthHint() {
    var reduced = false;
    try {
      reduced = window.matchMedia && window.matchMedia("(prefers-reduced-data: reduce)").matches;
    } catch (_) { /* noop */ }
    var saveData = false;
    try {
      saveData = !!(navigator && navigator.connection && navigator.connection.saveData);
    } catch (_) { /* noop */ }
    if (reduced || saveData) return "Saver hint: network asks for reduced data — prefer lower bitrate.";
    return "Saver hint: full quality OK; enable saver on metered links.";
  }

  // SMT2-007 smart search synonyms
  var SYNONYMS = {
    scifi: ["sci-fi", "science fiction", "sf"],
    comedy: ["funny", "humor", "humour"],
    doc: ["documentary", "docs"],
    kids: ["children", "family", "animation"]
  };
  function expandQuery(q) {
    var base = String(q || "").toLowerCase().trim();
    if (!base) return [];
    var out = [base];
    Object.keys(SYNONYMS).forEach(function (k) {
      var all = [k].concat(SYNONYMS[k]);
      if (all.indexOf(base) !== -1) {
        all.forEach(function (s) { if (out.indexOf(s) === -1) out.push(s); });
      }
    });
    return out;
  }

  // SMT2-008 auto-play next toggle
  var AUTOPLAY_KEY = "jellyfin.panel.smt2.autoplayNext";
  function loadAutoplay() {
    try { return localStorage.getItem(AUTOPLAY_KEY) === "1"; } catch (_) { return false; }
  }
  function saveAutoplay(v) {
    try { localStorage.setItem(AUTOPLAY_KEY, v ? "1" : "0"); } catch (_) { /* noop */ }
  }

  // SMT2-009 continue-watching sorter
  function sortContinueWatching(items) {
    return items.slice().sort(function (a, b) {
      var pa = parseFloat(a.progress);
      var pb = parseFloat(b.progress);
      var na = Number.isFinite(pa) ? pa : -1;
      var nb = Number.isFinite(pb) ? pb : -1;
      if (nb !== na) return nb - na;
      return String(a.title).localeCompare(String(b.title));
    });
  }

  // SMT2-010 library health score
  function healthScore(services, dupCount, missingCount) {
    var keys = services ? Object.keys(services) : [];
    var up = keys.filter(function (k) {
      var s = services[k];
      var st = typeof s === "string" ? s : (s && (s.state || s.status));
      return st === "healthy" || st === "up" || st === "running" || s === true;
    }).length;
    var svcScore = keys.length ? Math.round((up / keys.length) * 60) : 30;
    var dupPenalty = Math.min(20, (dupCount || 0) * 2);
    var missPenalty = Math.min(20, (missingCount || 0) * 2);
    return Math.max(0, Math.min(100, svcScore + 40 - dupPenalty - missPenalty));
  }

  function ensureSection() {
    var sec = document.getElementById(SECTION_ID);
    if (sec) return sec;
    sec = document.createElement("section");
    sec.id = SECTION_ID;
    sec.className = "smt2-section";
    sec.setAttribute("aria-label", "Smart collections");
    var anchor = document.querySelector("main, #app, .content, body");
    (anchor || document.body).appendChild(sec);
    return sec;
  }

  function ensureStyle() {
    if (document.getElementById("smt2-style")) return;
    var st = document.createElement("style");
    st.id = "smt2-style";
    st.textContent = ".smt2-section{margin:1rem 0;padding:.75rem 1rem;border:1px solid var(--line);border-radius:12px;background:var(--surface)}.smt2-section h2{font-size:1rem;margin:.25rem 0 .5rem}.smt2-grid{display:flex;flex-wrap:wrap;gap:.4rem}.smt2-chip{display:inline-flex;align-items:center;gap:.35em;padding:.25em .7em;border-radius:999px;border:1px solid var(--line);background:var(--surface-2);font-size:.8rem}.smt2-row{display:flex;gap:.5rem;align-items:center;flex-wrap:wrap;margin:.4rem 0}.smt2-muted{opacity:.75;font-size:.85rem}";
    document.head.appendChild(st);
  }

  function render(state) {
    var sec = ensureSection();
    ensureStyle();
    var groups = groupByGenre(state.items);
    var groupNames = Object.keys(groups).slice(0, 8);
    var autoplay = loadAutoplay();
    var sorted = sortContinueWatching(state.items).slice(0, 5);
    var score = healthScore(state.services, state.dups.length, state.missing ? 1 : 0);
    var quota = quotaChip(state.metrics);
    var html = "";
    html += "<h2>Smart collections</h2>";
    html += "<div class='smt2-row smt2-muted'>Health " + esc(score) + "/100 &middot; " + esc(state.dups.length) + " duplicate(s)" + (state.missing ? " &middot; " + esc(state.missing) : "") + "</div>";
    if (quota) html += "<div class='smt2-row'><span class='smt2-chip'>" + esc(quota) + "</span></div>";
    html += "<div class='smt2-row smt2-muted'>" + esc(bandwidthHint()) + "</div>";
    html += "<div class='smt2-row'><label><input type='checkbox' id='smt2-autoplay'" + (autoplay ? " checked" : "") + "> Auto-play next</label>" +
      "<span class='smt2-muted'>Next up: " + esc(nextUp(state.items, state.playback) || "—") + "</span></div>";
    html += "<div class='smt2-grid'>" + groupNames.map(function (g) {
      return "<span class='smt2-chip'>" + esc(g) + " (" + groups[g].length + ")</span>";
    }).join("") + "</div>";
    if (state.dups.length) {
      html += "<div class='smt2-row smt2-muted'>Duplicates: " + esc(state.dups.slice(0, 5).map(function (d) { return d.title + (d.year ? " (" + d.year + ")" : ""); }).join(", ")) + "</div>";
    }
    if (sorted.length) {
      html += "<div class='smt2-row smt2-muted'>Continue: " + esc(sorted.map(function (s) { return s.title; }).join(" · ")) + "</div>";
    }
    sec.innerHTML = html;
    var box = sec.querySelector("#smt2-autoplay");
    if (box) box.addEventListener("change", function () { saveAutoplay(box.checked); });
    void expandQuery;
  }

  function boot() {
    var items = readPageItems();
    Promise.all([
      fetchJson(STATUS_URL).catch(function () { return null; }),
      fetchJson(METRICS_URL).catch(function () { return null; })
    ]).then(function (pair) {
      var status = pair[0] || {};
      var metrics = pair[1] || {};
      var services = status.services || metrics.services || {};
      var playback = status.playback || null;
      render({
        items: items,
        services: services,
        metrics: metrics,
        playback: playback,
        dups: findDuplicates(items),
        missing: missingEpisodeHint(playback)
      });
    }).catch(function () {
      render({ items: items, services: {}, metrics: {}, playback: null, dups: findDuplicates(items), missing: "" });
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
