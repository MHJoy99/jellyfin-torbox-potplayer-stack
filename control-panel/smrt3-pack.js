"use strict";
/* smrt3-pack: third smart wins, additive read-only; no /api changes. */
(function smrt3Pack() {
  if (typeof window === "undefined" || typeof document === "undefined") return;
  if (window.__smt3Loaded) return;
  window.__smt3Loaded = true;

  var STATUS_URL = "/api/status";
  var METRICS_URL = "/api/metrics";
  var SECTION_ID = "smt3-collections";
  var STYLE_ID = "smt3-style";
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
    } catch (_) { ctrl = null; }
    var opts = {};
    if (ctrl) {
      opts.signal = ctrl.signal;
      timer = setTimeout(function () { try { ctrl.abort(); } catch (_) {} }, timeoutMs || FETCH_TIMEOUT_MS);
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
          ((n.querySelector(".title, .name, td:first-child") || {}).textContent || "");
        title = String(title).trim();
        if (!title) return;
        var genre = n.getAttribute("data-genre") || n.getAttribute("data-mood") || "";
        var yearRaw = n.getAttribute("data-year") || "";
        var ym = String(n.textContent || "").match(/\b(19\d{2}|20\d{2})\b/);
        var year = yearRaw || (ym ? ym[1] : "");
        var ratingRaw = n.getAttribute("data-rating") || n.getAttribute("data-vote") || "";
        var rating = parseFloat(ratingRaw);
        var playsRaw = n.getAttribute("data-plays") || n.getAttribute("data-play-count") || "";
        var plays = playsRaw === "" ? 0 : parseInt(playsRaw, 10);
        var progressRaw = n.getAttribute("data-progress") || "";
        var progress = progressRaw === "" ? "" : String(progressRaw);
        var director = n.getAttribute("data-director") || "";
        var bitrate = n.getAttribute("data-bitrate") || "";
        var seasonRaw = n.getAttribute("data-season") || n.getAttribute("data-seasons") || "";
        out.push({
          title: title,
          genre: String(genre || "").toLowerCase(),
          year: year ? parseInt(year, 10) : NaN,
          rating: Number.isFinite(rating) ? rating : NaN,
          plays: Number.isFinite(plays) ? plays : 0,
          progress: progress,
          director: String(director || "").trim(),
          bitrate: String(bitrate || "").trim(),
          seasons: seasonRaw ? parseInt(seasonRaw, 10) : NaN
        });
      });
    } catch (_) { /* DOM may be absent — keep empty list */ }
    return out;
  }

  function num(v, dflt) {
    var n = Number(v);
    return Number.isFinite(n) ? n : dflt;
  }

  // SMT3-001 mood collections (cozy / action night / feel-good buckets from genre keywords)
  var MOODS = {
    "cozy night": ["comedy", "family", "animation", "romance", "feel"],
    "action night": ["action", "adventure", "thriller", "crime", "sci-fi", "scifi"],
    "feel-good": ["comedy", "music", "family", "romance"]
  };
  function moodCollections(items) {
    var out = {};
    Object.keys(MOODS).forEach(function (mood) {
      var keys = MOODS[mood];
      out[mood] = items.filter(function (it) {
        var g = String(it.genre || "");
        return keys.some(function (k) { return g.indexOf(k) !== -1; });
      }).slice(0, 5).map(function (it) { return it.title; });
    });
    if (!items.length) return out;
    var anyHit = Object.keys(out).some(function (k) { return out[k].length; });
    if (!anyHit) {
      // Fallback: bucket alphabetically so the section is never empty.
      out["cozy night"] = items.slice(0, 3).map(function (it) { return it.title; });
      out["action night"] = items.slice(3, 6).map(function (it) { return it.title; });
      out["feel-good"] = items.slice(6, 9).map(function (it) { return it.title; });
    }
    return out;
  }

  // SMT3-002 decade marathon builder (group titles by decade)
  function decadeMarathon(items) {
    var buckets = {};
    items.forEach(function (it) {
      if (!Number.isFinite(it.year)) return;
      var decade = Math.floor(it.year / 10) * 10;
      var label = decade + "s";
      if (!buckets[label]) buckets[label] = [];
      buckets[label].push(it.title);
    });
    var labels = Object.keys(buckets).sort();
    // Pick the fullest decade as the marathon suggestion.
    var best = "";
    var bestCount = 0;
    labels.forEach(function (l) {
      if (buckets[l].length > bestCount) { bestCount = buckets[l].length; best = l; }
    });
    return { buckets: buckets, labels: labels, best: best, bestCount: bestCount };
  }

  // SMT3-003 director spotlight (most frequent director in DOM attrs)
  function directorSpotlight(items) {
    var counts = {};
    items.forEach(function (it) {
      if (!it.director) return;
      counts[it.director] = (counts[it.director] || 0) + 1;
    });
    var names = Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; });
    if (!names.length) return { name: "", count: 0, titles: [] };
    var top = names[0];
    var titles = items.filter(function (it) { return it.director === top; }).slice(0, 4).map(function (it) { return it.title; });
    return { name: top, count: counts[top], titles: titles };
  }

  // SMT3-004 unfinished series nudger (items with partial progress 0 < p < 100)
  function unfinishedSeries(items, playback) {
    var list = items.filter(function (it) {
      var p = parseFloat(it.progress);
      return Number.isFinite(p) && p > 0 && p < 100;
    }).slice(0, 5).map(function (it) { return it.title + " (" + it.progress + "%)"; });
    if (!list.length && playback && typeof playback === "object") {
      var hint = playback.show || playback.next || playback.continue || "";
      if (hint && typeof hint === "object") hint = hint.show || hint.title || "";
      if (hint) list.push(String(hint));
    }
    return list;
  }

  // SMT3-005 new-season alerter (season count hints from status.playback or data-season attrs)
  function newSeasonAlert(items, playback) {
    var notes = [];
    try {
      var fresh = playback && (playback.new_season || playback.newSeason || playback.latest_season);
      if (fresh) {
        if (typeof fresh === "object") fresh = fresh.show || fresh.title || JSON.stringify(fresh);
        notes.push("New season: " + String(fresh));
      }
      items.forEach(function (it) {
        if (Number.isFinite(it.seasons) && it.seasons > 1 && notes.length < 5) {
          notes.push(it.title + " — S" + it.seasons + " available");
        }
      });
    } catch (_) { /* noop */ }
    return notes.slice(0, 5);
  }

  // SMT3-006 watchlist priority sorter (unplayed first, then high-rated, then title)
  function watchlistPriority(items) {
    return items.slice().sort(function (a, b) {
      var pa = Number.isFinite(a.plays) ? a.plays : 0;
      var pb = Number.isFinite(b.plays) ? b.plays : 0;
      if (pa !== pb) return pa - pb;
      var ra = Number.isFinite(a.rating) ? a.rating : -1;
      var rb = Number.isFinite(b.rating) ? b.rating : -1;
      if (rb !== ra) return rb - ra;
      return String(a.title).localeCompare(String(b.title));
    }).slice(0, 5).map(function (it) { return it.title; });
  }

  // SMT3-007 hidden gems (low-play high-rated: plays <= 1 and rating >= 7.5)
  function hiddenGems(items) {
    var gems = items.filter(function (it) {
      return (it.plays || 0) <= 1 && Number.isFinite(it.rating) && it.rating >= 7.5;
    }).slice(0, 5).map(function (it) { return it.title + " ★" + it.rating; });
    return gems;
  }

  // SMT3-008 binge planner estimate (assume ~45m/ep, count unwatched queue; rough hours)
  function bingeEstimate(items, playback) {
    var queue = items.filter(function (it) { return (it.plays || 0) === 0; }).length;
    var perEpMin = 45;
    try {
      var hinted = playback && (playback.episode_minutes || playback.ep_minutes || playback.avg_minutes);
      if (Number.isFinite(Number(hinted)) && Number(hinted) > 0) perEpMin = Number(hinted);
    } catch (_) { /* keep default */ }
    var hours = Math.round((queue * perEpMin) / 60 * 10) / 10;
    return { queue: queue, perEpMin: perEpMin, hours: hours };
  }

  // SMT3-009 family mix balancer (count kids/family vs rest for a balanced night)
  function familyMix(items) {
    var kids = items.filter(function (it) {
      var g = String(it.genre || "");
      return g.indexOf("family") !== -1 || g.indexOf("kids") !== -1 ||
        g.indexOf("children") !== -1 || g.indexOf("animation") !== -1;
    }).length;
    var rest = Math.max(0, items.length - kids);
    var verdict = "Balanced";
    if (!items.length) verdict = "No data";
    else if (kids === 0) verdict = "Add a family pick";
    else if (rest === 0) verdict = "All-kids night";
    else if (Math.abs(kids - rest) <= 2) verdict = "Balanced";
    else if (kids > rest) verdict = "Kid-heavy — add a grown-up pick";
    else verdict = "Grown-up-heavy — add a family pick";
    return { kids: kids, rest: rest, total: items.length, verdict: verdict };
  }

  // SMT3-010 cleanup candidates (dupe/low-bitrate hint: dup titles + bitrate attr parse)
  function cleanupCandidates(items) {
    var seen = {};
    var dupes = [];
    items.forEach(function (it) {
      var k = String(it.title || "").toLowerCase().trim();
      if (!k) return;
      if (seen[k]) { if (dupes.indexOf(it.title) === -1) dupes.push(it.title); }
      else seen[k] = true;
    });
    var low = items.filter(function (it) {
      var m = String(it.bitrate || "").match(/([\d.]+)\s*(mbps|mb\/s|kbps|k)/i);
      if (!m) return false;
      var v = parseFloat(m[1]);
      if (!Number.isFinite(v)) return false;
      var unit = m[2].toLowerCase();
      var kbps = unit.charAt(0) === "m" ? v * 1000 : v;
      return kbps < 1500;
    }).slice(0, 5).map(function (it) { return it.title + " (" + it.bitrate + ")"; });
    return { dupes: dupes.slice(0, 5), lowBitrate: low };
  }

  function ensureSection() {
    var sec = document.getElementById(SECTION_ID);
    if (sec) return sec;
    sec = document.createElement("section");
    sec.id = SECTION_ID;
    sec.className = "smt3-section";
    sec.setAttribute("aria-label", "Smart collections 3");
    var anchor = document.querySelector("main, #app, .content, body");
    (anchor || document.body).appendChild(sec);
    return sec;
  }

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    var st = document.createElement("style");
    st.id = STYLE_ID;
    st.textContent = ".smt3-section{margin:1rem 0;padding:.75rem 1rem;border:1px solid var(--line);border-radius:12px;background:var(--surface)}.smt3-section h2{font-size:1rem;margin:.25rem 0 .5rem}.smt3-grid{display:flex;flex-wrap:wrap;gap:.4rem}.smt3-chip{display:inline-flex;align-items:center;gap:.35em;padding:.25em .7em;border-radius:999px;border:1px solid var(--line);background:var(--surface-2);font-size:.8rem}.smt3-row{display:flex;gap:.5rem;align-items:center;flex-wrap:wrap;margin:.4rem 0}.smt3-muted{opacity:.75;font-size:.85rem}";
    document.head.appendChild(st);
  }

  function render(vm) {
    var sec = ensureSection();
    ensureStyle();
    var html = "";
    html += "<h2>Smart collections 3</h2>";
    var moods = vm.moods;
    var moodNames = Object.keys(moods);
    html += "<div class='smt3-row smt3-muted'>Moods: " + esc(moodNames.map(function (m) {
      return m + " (" + moods[m].length + ")";
    }).join(" · ") || "—") + "</div>";
    html += "<div class='smt3-grid'>" + moodNames.map(function (m) {
      return "<span class='smt3-chip'>" + esc(m) + ": " + esc(moods[m].slice(0, 3).join(", ") || "—") + "</span>";
    }).join("") + "</div>";
    var dec = vm.decade;
    html += "<div class='smt3-row smt3-muted'>Marathon: " + esc(dec.best ? dec.best + " (" + dec.bestCount + " titles)" : "need years in DOM") + "</div>";
    if (dec.labels.length) {
      html += "<div class='smt3-grid'>" + dec.labels.slice(0, 6).map(function (l) {
        return "<span class='smt3-chip'>" + esc(l) + " (" + dec.buckets[l].length + ")</span>";
      }).join("") + "</div>";
    }
    html += "<div class='smt3-row smt3-muted'>Director spotlight: " + esc(vm.director.name ? vm.director.name + " ×" + vm.director.count + " — " + vm.director.titles.join(", ") : "n/a (add data-director)") + "</div>";
    html += "<div class='smt3-row smt3-muted'>Unfinished: " + esc(vm.unfinished.length ? vm.unfinished.join(" · ") : "—") + "</div>";
    html += "<div class='smt3-row smt3-muted'>New seasons: " + esc(vm.seasons.length ? vm.seasons.join(" · ") : "—") + "</div>";
    html += "<div class='smt3-row smt3-muted'>Priority watchlist: " + esc(vm.priority.length ? vm.priority.join(" → ") : "—") + "</div>";
    html += "<div class='smt3-row smt3-muted'>Hidden gems: " + esc(vm.gems.length ? vm.gems.join(" · ") : "—") + "</div>";
    html += "<div class='smt3-row smt3-muted'>Binge plan: " + esc(vm.binge.queue) + " unwatched × ~" + esc(vm.binge.perEpMin) + "m ≈ " + esc(vm.binge.hours) + "h</div>";
    html += "<div class='smt3-row smt3-muted'>Family mix: " + esc(vm.mix.kids) + " kids / " + esc(vm.mix.rest) + " rest — " + esc(vm.mix.verdict) + "</div>";
    html += "<div class='smt3-row smt3-muted'>Cleanup: " +
      esc(vm.clean.dupes.length ? "dupes: " + vm.clean.dupes.join(", ") : "no dupes") + " · " +
      esc(vm.clean.lowBitrate.length ? "low-bitrate: " + vm.clean.lowBitrate.join(", ") : "no low-bitrate flags") + "</div>";
    sec.innerHTML = html;
  }

  function boot() {
    var items = readPageItems();
    Promise.all([
      fetchJson(STATUS_URL).catch(function () { return null; }),
      fetchJson(METRICS_URL).catch(function () { return null; })
    ]).then(function (pair) {
      var status = pair[0] || {};
      var metrics = pair[1] || {};
      void metrics;
      var playback = status.playback || null;
      render({
        moods: moodCollections(items),
        decade: decadeMarathon(items),
        director: directorSpotlight(items),
        unfinished: unfinishedSeries(items, playback),
        seasons: newSeasonAlert(items, playback),
        priority: watchlistPriority(items),
        gems: hiddenGems(items),
        binge: bingeEstimate(items, playback),
        mix: familyMix(items),
        clean: cleanupCandidates(items)
      });
    }).catch(function () {
      render({
        moods: moodCollections(items),
        decade: decadeMarathon(items),
        director: directorSpotlight(items),
        unfinished: unfinishedSeries(items, null),
        seasons: [],
        priority: watchlistPriority(items),
        gems: hiddenGems(items),
        binge: bingeEstimate(items, null),
        mix: familyMix(items),
        clean: cleanupCandidates(items)
      });
    });
  }

  function numUnused() { return num("0", 0); }
  void numUnused;

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
