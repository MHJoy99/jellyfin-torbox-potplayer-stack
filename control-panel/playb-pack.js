(function () {
"use strict";
try {
var DOC = document, WIN = window;
function $(sel, root) { try { return (root || DOC).querySelector(sel); } catch (_) { return null; } }
function $all(sel, root) { try { return Array.prototype.slice.call((root || DOC).querySelectorAll(sel)); } catch (_) { return []; } }
function mk(tag, cls, text) { var n = DOC.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }
function lsGet(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
function ssGet(k, d) { try { var v = sessionStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function ssSet(k, v) { try { sessionStorage.setItem(k, v); } catch (_) {} }
function toast(msg) { var t = DOC.getElementById("toast"); if (t) { t.textContent = msg; t.className = "toast show"; clearTimeout(toast._t); toast._t = setTimeout(function () { t.classList.remove("show"); }, 4200); } }
function esc(s) { return String(s == null ? "" : s); }
function curTitle() {
  var p = $("#playback-status");
  if (p && p.textContent) { var t = p.textContent.trim().split("\n")[0].trim(); if (t && t.length > 2 && t.length < 140) return t; }
  var h = $("h1, h2, .detail-title, [data-title]");
  if (h && h.textContent && h.textContent.trim().length > 1 && h.textContent.trim().length < 140) return h.textContent.trim();
  var d = DOC.title; if (d && d.length > 1) return d.replace(/\s*[|\-–]\s*Jellyfin.*$/i, "").trim() || d;
  return "";
}
function curLib() {
  var a = DOC.querySelector("[data-library], [data-collection], .library-active, .nav-active");
  if (a) { var k = a.getAttribute("data-library") || a.getAttribute("data-collection") || a.textContent; if (k) return k.trim().slice(0, 40) || "default"; }
  var t = DOC.title; if (t) return t.slice(0, 40);
  return "default";
}
function videos() { return $all("video"); }
function libItems() {
  var sels = ["#services .service-card[data-service-id]", ".library-item", ".poster-card", "[data-item-id]", ".card[data-title]", ".item[data-title]"];
  for (var i = 0; i < sels.length; i++) { var n = $all(sels[i]); if (n.length) return n; }
  return [];
}
function visible(items) { return items.filter(function (n) { try { if (n.style && n.style.display === "none") return false; if (n.offsetParent !== null) return true; var r = n.getBoundingClientRect(); return r.width > 0 && r.height > 0; } catch (_) { return true; } }); }
function itemLabel(n) {
  try {
    var t = n.getAttribute("data-title") || n.getAttribute("data-name") || n.getAttribute("aria-label") || n.getAttribute("title") || "";
    if (!t) { var h = n.querySelector("h1,h2,h3,h4,.title,.name,strong"); if (h && h.textContent) t = h.textContent.trim(); }
    if (!t && n.textContent) t = n.textContent.trim().split("\n")[0].trim();
    return (t || "item").slice(0, 80);
  } catch (_) { return "item"; }
}
function itemGenre(n) {
  try {
    var g = n.getAttribute("data-genre") || n.getAttribute("data-genres") || "";
    if (g) return g;
    var c = n.querySelector(".genre, [data-genre], .meta-genre");
    if (c && c.textContent) return c.textContent.trim();
    return "";
  } catch (_) { return ""; }
}
function trailerUrl() {
  try {
    var a = DOC.querySelector("[data-trailer-url], [data-trailer]");
    if (a) { var u = a.getAttribute("data-trailer-url") || a.getAttribute("data-trailer") || a.getAttribute("href"); if (u && /^https?:/i.test(u)) return u; }
    var links = $all('a[href*="youtube.com/watch"], a[href*="youtu.be/"]');
    for (var i = 0; i < links.length; i++) { var h = links[i].getAttribute("href"); if (h) return h; }
    var emb = $("trailer, .trailer-video, video[data-trailer]");
    if (emb && emb.getAttribute("src") && /^https?:/i.test(emb.getAttribute("src"))) return emb.getAttribute("src");
    return "";
  } catch (_) { return ""; }
}
function CSS() {
  if (DOC.getElementById("playb-style")) return;
  var s = DOC.createElement("style"); s.id = "playb-style";
  s.textContent = ".playb-bar{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:0 0 10px;padding:8px;border:1px solid var(--accent-ring,#334);border-radius:10px;font-size:12px;background:transparent}.playb-badge{display:inline-flex;align-items:center;gap:4px;font-size:11px;padding:2px 8px;border-radius:999px;border:1px solid var(--accent-ring,#334);color:var(--muted,#999)}.playb-badge.is-on{color:#cfe1ff;border-color:var(--accent,#4f8cff)}.playb-btn{cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:8px;padding:3px 10px;font-size:12px;background:transparent;color:var(--text,#e6edf7)}.playb-btn:hover{border-color:var(--accent,#4f8cff)}.playb-sel{font:inherit;font-size:12px;padding:3px 8px;border-radius:8px;border:1px solid var(--accent-ring,#334);background:var(--bg,#0e1522);color:var(--text,#e6edf7)}.playb-row{display:flex;gap:8px;overflow-x:auto;padding:8px;border:1px solid var(--accent-ring,#334);border-radius:10px;margin:8px 0}.playb-rec{min-width:140px;max-width:180px;border:1px solid var(--accent-ring,#334);border-radius:8px;padding:8px;font-size:12px;color:var(--text,#e6edf7)}.playb-rating{display:inline-flex;gap:4px;align-items:center;font-size:11px;border:1px solid var(--accent-ring,#334);border-radius:999px;padding:1px 8px;margin:2px 4px 2px 0;color:var(--muted,#999)}.playb-tip{position:fixed;z-index:99;pointer-events:none;background:var(--bg,#0e1522);color:var(--text,#e6edf7);border:1px solid var(--accent-ring,#334);border-radius:8px;padding:4px 8px;font-size:11px;display:none}.playb-locked{filter:blur(6px);pointer-events:none;user-select:none}.playb-flash{outline:2px solid var(--accent,#4f8cff)!important;outline-offset:2px}";
  DOC.head.appendChild(s);
}
function bar() {
  CSS();
  var b = DOC.getElementById("playb-bar");
  if (b) return b;
  b = mk("div", "playb-bar"); b.id = "playb-bar";
  b.setAttribute("role", "toolbar"); b.setAttribute("aria-label", "Playback wins");
  var anchor = $("#playback-status") || $("main.shell") || $("main") || DOC.body;
  try {
    if (anchor && anchor.id === "playback-status" && anchor.parentElement) anchor.parentElement.insertBefore(b, anchor);
    else if (anchor && anchor.firstChild) anchor.insertBefore(b, anchor.firstChild);
    else (DOC.body).appendChild(b);
  } catch (_) { try { DOC.body.appendChild(b); } catch (_) {} }
  return b;
}

// PLYB-001
function wSleep() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playb-sleep")) return;
    var lab = mk("span", "playb-badge", "Sleep: off"); lab.id = "playb-sleep-badge"; lab.setAttribute("role", "status"); lab.setAttribute("aria-live", "polite");
    var sel = DOC.createElement("select"); sel.id = "playb-sleep"; sel.className = "playb-sel"; sel.setAttribute("aria-label", "Sleep timer");
    [["off", "Sleep: off"], ["episode", "Stop after episode"], ["30", "Sleep 30 min"], ["60", "Sleep 60 min"]].forEach(function (o) { var op = DOC.createElement("option"); op.value = o[0]; op.textContent = o[1]; sel.appendChild(op); });
    sel.value = lsGet("playb.sleep", "off");
    var st = { timer: 0, tick: 0, until: 0 };
    function clear() { try { clearTimeout(st.timer); } catch (_) {} try { clearInterval(st.tick); } catch (_) {} st.timer = 0; st.tick = 0; }
    function paint(left) { lab.textContent = !left ? "Sleep: off" : ("Sleep " + left); lab.classList.toggle("is-on", !!left); }
    function stopAll(why) { try { videos().forEach(function (v) { try { v.pause(); } catch (_) {} }); } catch (_) {} paint(""); try { sel.value = "off"; lsSet("playb.sleep", "off"); } catch (_) {} toast(why || "Sleep timer stopped playback."); }
    function arm() {
      clear(); paint("");
      var v = sel.value; try { lsSet("playb.sleep", v); } catch (_) {}
      if (v === "off") return;
      if (v === "episode") { paint("after episode"); toast("Sleep: stops after current episode."); return; }
      var mins = parseInt(v, 10); if (!mins) return;
      st.until = Date.now() + mins * 60000;
      paint(mins + "m left");
      st.tick = setInterval(function () { var ms = st.until - Date.now(); if (ms <= 0) { clear(); stopAll("Sleep timer: playback paused."); return; } paint(Math.ceil(ms / 60000) + "m left"); }, 15000);
      st.timer = setTimeout(function () { clear(); stopAll("Sleep timer: playback paused."); }, mins * 60000);
    }
    sel.addEventListener("change", arm);
    DOC.addEventListener("ended", function (e) { try { if (sel.value === "episode" && e.target && e.target.tagName === "VIDEO") stopAll("Stopped after episode (sleep timer)."); } catch (_) {} }, true);
    try {
      var last = DOC.getElementById("playback-status");
      if (last) { var mo = new MutationObserver(function () { try { if (sel.value === "episode") paint("after episode"); } catch (_) {} }); mo.observe(last, { childList: true, subtree: true }); }
    } catch (_) {}
    b.appendChild(sel); b.appendChild(lab);
    if (sel.value !== "off") arm();
  } catch (_) {}
}

// PLYB-002
function wSpeed() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playb-speed")) return;
    var sel = DOC.createElement("select"); sel.id = "playb-speed"; sel.className = "playb-sel"; sel.setAttribute("aria-label", "Playback speed (remembered per library)");
    [["0.75", "0.75x"], ["1", "1x"], ["1.25", "1.25x"], ["1.5", "1.5x"], ["1.75", "1.75x"], ["2", "2x"]].forEach(function (o) { var op = DOC.createElement("option"); op.value = o[0]; op.textContent = o[1]; sel.appendChild(op); });
    function key() { return "playb.speed." + curLib(); }
    function apply() { var r = parseFloat(sel.value) || 1; try { videos().forEach(function (v) { try { v.playbackRate = r; } catch (_) {} }); } catch (_) {} }
    try { sel.value = lsGet(key(), "1"); } catch (_) { sel.value = "1"; }
    sel.title = "Speed memory for: " + curLib();
    sel.addEventListener("change", function () { try { lsSet(key(), sel.value); } catch (_) {} apply(); toast("Speed " + sel.value + "x remembered for this library."); });
    ["loadedmetadata", "play"].forEach(function (ev) { DOC.addEventListener(ev, function (e) { try { if (e.target && e.target.tagName === "VIDEO") { var want = parseFloat(lsGet(key(), "1")) || 1; try { e.target.playbackRate = want; } catch (_) {} if (String(want) !== sel.value) sel.value = String(want); } } catch (_) {} }, true); });
    try { var mo = new MutationObserver(function () { apply(); }); mo.observe(DOC.body, { childList: true, subtree: true }); } catch (_) {}
    b.appendChild(sel);
    apply();
  } catch (_) {}
}

// PLYB-003
function wTrailerBtn() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playb-trailer")) return;
    var btn = mk("button", "playb-btn", "▶ Trailer"); btn.id = "playb-trailer"; btn.type = "button";
    function refresh() {
      var u = trailerUrl();
      btn.hidden = !u;
      btn.title = u || "No trailer exposed for this item";
      btn.onclick = function () { if (u) { try { WIN.open(u, "_blank", "noopener"); } catch (_) { location.href = u; } } };
      var det = $("[data-detail], .detail-actions, .item-actions, #item-detail");
      if (det && u && !DOC.getElementById("playb-trailer-inline")) {
        var ib = mk("button", "playb-btn", "▶ Trailer"); ib.id = "playb-trailer-inline"; ib.type = "button";
        ib.onclick = btn.onclick; try { det.appendChild(ib); } catch (_) {}
      }
      if (!u) { var ib2 = DOC.getElementById("playb-trailer-inline"); if (ib2) ib2.remove(); }
    }
    b.appendChild(btn);
    refresh();
    try { var mo = new MutationObserver(function () { refresh(); }); mo.observe(DOC.body, { childList: true, subtree: true }); } catch (_) {}
  } catch (_) {}
}

// PLYB-004
function wRecs() {
  try {
    if (DOC.getElementById("playb-recs")) return;
    var host = $("#playback-status");
    var wrap = mk("div", null, ""); wrap.id = "playb-recs"; wrap.hidden = true;
    var h = mk("div", "playb-badge", "Because you watched"); wrap.appendChild(h);
    var row = mk("div", "playb-row"); row.id = "playb-recs-row"; wrap.appendChild(row);
    try {
      if (host && host.parentElement) host.parentElement.insertBefore(wrap, host.nextSibling);
      else { var m = $("main.shell") || DOC.body; m.appendChild(wrap); }
    } catch (_) {}
    function paint() {
      try {
        var items = libItems();
        if (items.length < 2) { wrap.hidden = true; return; }
        var last = curTitle();
        try { if (last) lsSet("playb.lastWatched", last.slice(0, 80)); } catch (_) {}
        var seed = (lsGet("playb.lastWatched", "") || last || "").toLowerCase();
        var counts = {};
        items.forEach(function (n) { var g = (itemGenre(n) || "").toLowerCase(); g.split(/[,/|·•]/).forEach(function (x) { x = x.trim(); if (x) counts[x] = (counts[x] || 0) + 1; }); });
        var top = Object.keys(counts).sort(function (a, c) { return counts[c] - counts[a]; })[0] || "";
        var picks = items.filter(function (n) { var l = itemLabel(n).toLowerCase(); if (seed && l && seed.indexOf(l.slice(0, 12)) >= 0) return false; if (!top) return true; return (itemGenre(n) || "").toLowerCase().indexOf(top) >= 0; }).slice(0, 6);
        if (!picks.length) picks = visible(items).slice(0, 6);
        if (!picks.length) { wrap.hidden = true; return; }
        row.innerHTML = "";
        picks.forEach(function (n) {
          var c = mk("div", "playb-rec", itemLabel(n));
          c.title = "Genre match" + (top ? ": " + top : "") + " — click to jump";
          c.tabIndex = 0; c.setAttribute("role", "button");
          function go() { try { n.scrollIntoView({ block: "nearest", behavior: "smooth" }); n.classList.add("playb-flash"); setTimeout(function () { n.classList.remove("playb-flash"); }, 1600); } catch (_) {} }
          c.addEventListener("click", go);
          c.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); go(); } });
          row.appendChild(c);
        });
        h.textContent = "Because you watched" + (seed ? ": " + seed.slice(0, 40) : "") + (top ? " · " + top : "");
        wrap.hidden = false;
      } catch (_) { try { wrap.hidden = true; } catch (_) {} }
    }
    paint();
    try { var mo = new MutationObserver(function () { paint(); }); mo.observe(DOC.body, { childList: true, subtree: true }); } catch (_) {}
  } catch (_) {}
}

// PLYB-005
function wPin() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playb-pin")) return;
    var btn = mk("button", "playb-btn", "🔒 PIN"); btn.id = "playb-pin"; btn.type = "button";
    btn.title = "Parental PIN per library. Client-side convenience only — not server security.";
    function hash(s) { var x = 0; for (var i = 0; i < s.length; i++) { x = ((x << 5) - x + s.charCodeAt(i)) | 0; } return "h" + (x >>> 0).toString(16); }
    function key() { return "playb.pin." + curLib(); }
    function locked() { try { return !!lsGet(key(), "") && ssGet("playb.unlocked." + curLib(), "") !== "1"; } catch (_) { return false; } }
    function paintLocks() {
      var items = libItems();
      items.forEach(function (n) { try { n.classList.toggle("playb-locked", locked()); } catch (_) {} });
      btn.textContent = locked() ? "🔒 Locked" : "🔓 PIN";
    }
    btn.addEventListener("click", function () {
      try {
        var k = key();
        var saved = lsGet(k, "");
        if (!saved) {
          var p1 = ""; try { p1 = WIN.prompt("Set a PIN for library '" + curLib() + "'. Stored locally as a hash. Client-side convenience only, not server security.", "") || ""; } catch (_) {}
          if (!p1) return;
          lsSet(k, hash(p1)); ssSet("playb.unlocked." + curLib(), "1");
          toast("PIN set for this library (local convenience lock).");
        } else if (locked()) {
          var p2 = ""; try { p2 = WIN.prompt("Enter PIN for '" + curLib() + "':", "") || ""; } catch (_) {}
          if (hash(p2) === saved) { ssSet("playb.unlocked." + curLib(), "1"); toast("Unlocked for this session."); }
          else { toast("Wrong PIN."); return; }
        } else {
          if (WIN.confirm("Lock '" + curLib() + "' again? (Double-OK clears PIN: press Cancel at next prompt to keep it.)")) {
            ssSet("playb.unlocked." + curLib(), "");
            var clr = false; try { clr = WIN.confirm("Clear the saved PIN entirely?"); } catch (_) {}
            if (clr) { try { localStorage.removeItem(k); } catch (_) {} }
          }
        }
        paintLocks();
      } catch (_) {}
    });
    b.appendChild(btn);
    paintLocks();
    try { var mo = new MutationObserver(function () { paintLocks(); }); mo.observe(DOC.body, { childList: true, subtree: true }); } catch (_) {}
  } catch (_) {}
}

// PLYB-006
function wSubs() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playb-subs")) return;
    var btn = mk("button", "playb-btn", "⬇ Subtitles"); btn.id = "playb-subs"; btn.type = "button";
    btn.title = "Open OpenSubtitles search prefilled with current title";
    btn.addEventListener("click", function () {
      var t = curTitle() || "jellyfin";
      var u = "https://www.opensubtitles.org/en/search2/" + encodeURIComponent(t) + "/all";
      try { WIN.open(u, "_blank", "noopener"); } catch (_) { location.href = u; }
    });
    b.appendChild(btn);
  } catch (_) {}
}

// PLYB-007
function wChapters() {
  try {
    var tip = mk("div", "playb-tip", ""); tip.id = "playb-tip"; DOC.body.appendChild(tip);
    function chapters() {
      try {
        if (WIN.__chapters && WIN.__chapters.length) return WIN.__chapters;
        var n = DOC.querySelector("[data-chapters]");
        if (n) { var j = JSON.parse(n.getAttribute("data-chapters")); if (j && j.length) return j; }
        var list = $all(".chapter, [data-chapter], .chapter-item");
        if (list.length) return list.map(function (c, i) { return { title: (c.textContent || ("Chapter " + (i + 1))).trim().slice(0, 60), time: i * 600 }; });
      } catch (_) {}
      return [];
    }
    function fmt(s) { s = Math.max(0, Math.floor(s || 0)); var m = Math.floor(s / 60), h = Math.floor(m / 60); s = s % 60; m = m % 60; function p(x) { return (x < 10 ? "0" : "") + x; } return h ? h + ":" + p(m) + ":" + p(s) : p(m) + ":" + p(s); }
    function bindSeek(seek) {
      if (!seek || seek._playb) return; seek._playb = 1;
      seek.addEventListener("mousemove", function (e) {
        try {
          var r = seek.getBoundingClientRect();
          var frac = (e.clientX - r.left) / Math.max(1, r.width);
          frac = Math.min(1, Math.max(0, frac));
          var v = videos()[0];
          var dur = (v && v.duration && isFinite(v.duration)) ? v.duration : 3600;
          var t = frac * dur;
          var ch = chapters();
          var label = fmt(t);
          for (var i = 0; i < ch.length; i++) {
            var ct = Number(ch[i].start || ch[i].time || ch[i].seconds || 0);
            var nx = (i + 1 < ch.length) ? Number(ch[i + 1].start || ch[i + 1].time || ch[i + 1].seconds || Infinity) : Infinity;
            if (t >= ct && t < nx) { label = fmt(t) + (ch[i].title ? " · " + esc(ch[i].title) : ""); break; }
          }
          tip.textContent = label;
          tip.style.display = "block";
          tip.style.left = Math.min(WIN.innerWidth - 120, Math.max(8, e.clientX + 12)) + "px";
          tip.style.top = (r.top - 30) + "px";
        } catch (_) {}
      });
      seek.addEventListener("mouseleave", function () { tip.style.display = "none"; });
    }
    function scan() {
      $all('input[type="range"], progress, .seek-bar, .progress-bar, video').forEach(function (n) {
        try {
          if (n.tagName === "VIDEO") { var p = n.parentElement ? n.parentElement.querySelector('input[type="range"], progress') : null; if (p) bindSeek(p); }
          else bindSeek(n);
        } catch (_) {}
      });
    }
    scan();
    try { var mo = new MutationObserver(function () { scan(); }); mo.observe(DOC.body, { childList: true, subtree: true }); } catch (_) {}
  } catch (_) {}
}

// PLYB-008
function wRatings() {
  try {
    function paint() {
      $all("#services .service-card[data-service-id], .library-item, [data-item-id], .poster-card").forEach(function (n) {
        if (n._playbR) return;
        try {
          var imdb = n.getAttribute("data-imdb") || n.getAttribute("data-imdb-rating") || "";
          var tmdb = n.getAttribute("data-tmdb") || n.getAttribute("data-tmdb-rating") || "";
          var r = n.getAttribute("data-rating") || "";
          if (!imdb && !tmdb && !r) {
            var c = n.querySelector(".rating, [data-rating], .imdb, .tmdb");
            if (c) r = (c.textContent || "").trim().slice(0, 12);
          }
          if (!imdb && !tmdb && !r) return;
          n._playbR = 1;
          var host = n.querySelector("h1,h2,h3,h4,.title,.name") || n;
          function badge(t) { var s = mk("span", "playb-rating", t); try { host.appendChild(DOC.createTextNode(" ")); host.appendChild(s); } catch (_) {} }
          if (imdb) badge("IMDb " + String(imdb).slice(0, 6));
          if (tmdb) badge("TMDB " + String(tmdb).slice(0, 6));
          if (r && !imdb && !tmdb) badge("★ " + String(r).slice(0, 8));
        } catch (_) {}
      });
    }
    paint();
    try { var mo = new MutationObserver(function () { paint(); }); mo.observe(DOC.body, { childList: true, subtree: true }); } catch (_) {}
  } catch (_) {}
}

// PLYB-009
function wHoverPreview() {
  try {
    function arm(card) {
      if (!card || card._playbH) return; card._playbH = 1;
      var url = card.getAttribute("data-trailer-url") || card.getAttribute("data-preview") || card.getAttribute("data-trailer") || "";
      if (!url) { var a = card.querySelector("a[href]"); if (a) { var h = a.getAttribute("href") || ""; if (/\.mp4($|\?)|\.webm($|\?)/i.test(h)) url = h; } }
      if (!url || !/^https?:/i.test(url)) return;
      var pv = null;
      card.addEventListener("mouseenter", function () {
        try {
          if (pv) return;
          pv = DOC.createElement("video");
          pv.muted = true; pv.loop = true; pv.playsInline = true; pv.preload = "metadata";
          pv.src = url; pv.style.cssText = "position:absolute;inset:0;width:100%;height:100%;object-fit:cover;border-radius:8px;background:#000";
          var cs = WIN.getComputedStyle ? WIN.getComputedStyle(card) : null;
          if (!cs || cs.position === "static") card.style.position = "relative";
          card.appendChild(pv);
          var pr = pv.play(); if (pr && pr.catch) pr.catch(function () {});
        } catch (_) {}
      });
      card.addEventListener("mouseleave", function () { try { if (pv) { pv.pause(); pv.removeAttribute("src"); pv.remove(); pv = null; } } catch (_) {} });
    }
    function scan() { libItems().forEach(arm); $all(".poster, img[poster]").forEach(function (n) { arm(n.closest ? (n.closest(".card, .item, .poster-card, .library-item") || n) : n); }); }
    scan();
    try { var mo = new MutationObserver(function () { scan(); }); mo.observe(DOC.body, { childList: true, subtree: true }); } catch (_) {}
  } catch (_) {}
}

// PLYB-010
function wSurprise() {
  try {
    var b = bar(); if (!b || DOC.getElementById("playb-surprise")) return;
    var btn = mk("button", "playb-btn", "🎲 Surprise me"); btn.id = "playb-surprise"; btn.type = "button";
    btn.title = "Random pick from currently visible (filtered) items";
    btn.addEventListener("click", function () {
      try {
        var pool = visible(libItems());
        if (!pool.length) { toast("Surprise me: no visible items under current filters."); return; }
        var pick = pool[Math.floor(Math.random() * pool.length)];
        try { pick.scrollIntoView({ block: "nearest", behavior: "smooth" }); } catch (_) {}
        pick.classList.add("playb-flash");
        setTimeout(function () { try { pick.classList.remove("playb-flash"); } catch (_) {} }, 1800);
        toast("🎲 " + itemLabel(pick) + " (" + pool.length + " visible)");
      } catch (_) {}
    });
    b.appendChild(btn);
  } catch (_) {}
}
try { wSleep(); } catch (_) {}
try { wSpeed(); } catch (_) {}
try { wTrailerBtn(); } catch (_) {}
try { wRecs(); } catch (_) {}
try { wPin(); } catch (_) {}
try { wSubs(); } catch (_) {}
try { wChapters(); } catch (_) {}
try { wRatings(); } catch (_) {}
try { wHoverPreview(); } catch (_) {}
try { wSurprise(); } catch (_) {}
} catch (_) {}
})();
