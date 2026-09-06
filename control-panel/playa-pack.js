(function () {
"use strict";
try {
// Playa pack: additive playback-experience helpers. Reuses existing video/player hooks, never breaks playback.
var W = typeof window !== "undefined" ? window : this;
var D = typeof document !== "undefined" ? document : null;
var P = (W.__playa = W.__playa || {});
var LS = { prog: "playa.progress", skip: "playa.skipRanges", av: "playa.avprefs", off: "playa.subOffset", qual: "playa.quality" };
function G(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function SV(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
function GJ(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } }
function SJ(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} }
function E(id) { try { return D ? D.getElementById(id) : null; } catch (_) { return null; } }
function MK(t, c, x) { var n = D.createElement(t); if (c) n.className = c; if (x != null) n.textContent = x; return n; }
function TS(m) { try { var t = E("toast"); if (t) { t.textContent = m; t.className = "toast show"; clearTimeout(TS._t); TS._t = setTimeout(function () { t.classList.remove("show"); }, 3200); } } catch (_) {} }
function ON(n, e, f) { try { if (n) n.addEventListener(e, f); } catch (_) {} }
function CP(t, msg) {
  function fb() { try { var ta = D.createElement("textarea"); ta.value = t; D.body.appendChild(ta); ta.select(); D.execCommand("copy"); ta.remove(); } catch (_) {} TS(msg || "Copied."); }
  try { if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(function () { TS(msg || "Copied."); }, fb); else fb(); } catch (_) { fb(); }
}
function VID() { try { return D ? D.querySelector("video") : null; } catch (_) { return null; } }
function PH() {
  try {
    if (P.hook) return P.hook;
    if (W.__player && typeof W.__player === "object") return W.__player;
    if (W.playbackManager) return W.playbackManager;
    if (W.ApiClient) return W.ApiClient;
    return null;
  } catch (_) { return null; }
}
function SHOWID() {
  try {
    var v = VID();
    if (v && v.getAttribute("data-show-id")) return v.getAttribute("data-show-id");
    if (D) { var m = D.querySelector("[data-show-id],[data-series-id]"); if (m) return m.getAttribute("data-show-id") || m.getAttribute("data-series-id"); }
    var pb = E("playback-status"); if (pb && pb.textContent) return pb.textContent.trim().slice(0, 48) || "default";
    return (document.title || "default").slice(0, 48);
  } catch (_) { return "default"; }
}
function CSS() {
  if (!D || E("playa-style")) return;
  var s = D.createElement("style"); s.id = "playa-style";
  s.textContent = ".playa-row{display:flex;gap:10px;overflow-x:auto;padding:10px;border:1px solid var(--accent-ring,#334);border-radius:12px;margin:10px 0;background:var(--bg,#0e1522)}.playa-card{min-width:180px;max-width:220px;border:1px solid var(--accent-ring,#334);border-radius:10px;padding:8px;font-size:12px;cursor:pointer;background:transparent;color:inherit}.playa-card:hover{border-color:var(--accent,#4f8cff)}.playa-bar{height:5px;border-radius:99px;background:rgba(127,140,160,.3);margin-top:6px;overflow:hidden}.playa-bar i{display:block;height:100%;background:var(--accent,#4f8cff)}.playa-tools{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:10px 0;padding:8px;border:1px solid var(--accent-ring,#334);border-radius:10px;font-size:12px}.playa-btn{cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:8px;padding:3px 10px;font-size:12px;background:transparent;color:inherit}.playa-btn:hover{border-color:var(--accent,#4f8cff)}.playa-overlay{position:fixed;right:14px;bottom:14px;z-index:95;background:var(--bg,#0e1522);border:1px solid var(--accent-ring,#334);border-radius:12px;padding:12px 14px;font-size:13px;box-shadow:0 10px 30px rgba(0,0,0,.45);max-width:min(340px,90vw)}.playa-skip{position:fixed;right:16px;bottom:76px;z-index:95;display:flex;gap:8px}.playa-menu{position:absolute;z-index:99;background:var(--bg,#0e1522);border:1px solid var(--accent-ring,#334);border-radius:10px;padding:6px;min-width:170px;font-size:12px}";
  D.head.appendChild(s);
}
function MOUNT() {
  try {
    if (!D) return null;
    var host = E("playback-status") || D.querySelector("main.shell") || D.body;
    if (!host) return null;
    var wrap = E("playa-tools");
    if (!wrap) {
      wrap = MK("div", "playa-tools"); wrap.id = "playa-tools"; wrap.setAttribute("role", "toolbar"); wrap.setAttribute("aria-label", "Playback extras");
      if (host.id === "playback-status" && host.parentNode) host.parentNode.insertBefore(wrap, host.nextSibling);
      else host.insertBefore(wrap, host.firstChild);
    }
    return wrap;
  } catch (_) { return null; }
}
// PLYA-001
function w001() {
  try {
    if (!D || E("playa-row")) return;
    CSS(); var host = MOUNT(); if (!host) return;
    var row = MK("div", "playa-row"); row.id = "playa-row"; row.setAttribute("aria-label", "Continue watching");
    host.parentNode.insertBefore(row, host.nextSibling);
    P.renderContinue = function () {
      try {
        var store = GJ(LS.prog, {});
        try { var legacy = GJ("jellyfin.resume", null) || GJ("jellyfin.panel.resume", null); if (legacy && typeof legacy === "object") { Object.keys(legacy).forEach(function (k) { if (!store[k]) store[k] = legacy[k]; }); } } catch (_) {}
        try {
          var dom = D.querySelectorAll("[data-resume],[data-positionticks],[data-progress]");
          Array.prototype.forEach.call(dom, function (n) {
            var id = n.getAttribute("data-id") || n.getAttribute("data-item-id") || n.textContent.trim().slice(0, 40);
            var pct = parseFloat(n.getAttribute("data-progress") || n.getAttribute("data-positionticks") || "0");
            if (id && !store[id]) store[id] = { title: id, pct: isFinite(pct) && pct <= 1 ? pct : 0, url: "", updated: Date.now() };
          });
        } catch (_) {}
        while (row.firstChild) row.removeChild(row.firstChild);
        var keys = Object.keys(store).sort(function (a, b) { return (store[b].updated || 0) - (store[a].updated || 0); }).slice(0, 12);
        if (!keys.length) { row.appendChild(MK("span", "", "Continue watching: nothing saved yet — play anything and progress appears here.")); return; }
        keys.forEach(function (k) {
          var it = store[k] || {};
          var pct = Math.max(0, Math.min(1, Number(it.pct || (it.d ? it.t / it.d : 0)) || 0));
          var c = MK("button", "playa-card"); c.type = "button"; c.title = "Resume " + (it.title || k);
          var t = MK("div", "", (it.title || k).slice(0, 60)); c.appendChild(t);
          var sub = MK("div", "", Math.round(pct * 100) + "%" + (it.t && it.d ? " · " + Math.round(it.t) + "s / " + Math.round(it.d) + "s" : "")); sub.style.opacity = ".75"; c.appendChild(sub);
          var bar = MK("div", "playa-bar"); var fill = MK("i", ""); fill.style.width = (pct * 100).toFixed(1) + "%"; bar.appendChild(fill); c.appendChild(bar);
          ON(c, "click", function () {
            try {
              if (it.url) { W.location.href = it.url + (it.t ? (it.url.indexOf("?") >= 0 ? "&" : "?") + "t=" + Math.floor(it.t) : ""); return; }
              var v = VID(); if (v && isFinite(it.t)) { try { v.currentTime = it.t; v.play(); } catch (_) {} TS("Resumed at " + Math.floor(it.t) + "s."); }
              else TS("Resume point: " + Math.floor(it.t || 0) + "s.");
            } catch (_) {}
          });
          row.appendChild(c);
        });
      } catch (_) {}
    };
    P.saveProgress = function (id, t, d, title, url) {
      try { var s = GJ(LS.prog, {}); s[id] = { t: t, d: d, pct: d ? t / d : 0, title: title || id, url: url || "", updated: Date.now() }; var ks = Object.keys(s).slice(-60); var o = {}; ks.forEach(function (k) { o[k] = s[k]; }); SJ(LS.prog, o); if (P.renderContinue) P.renderContinue(); } catch (_) {}
    };
    var v = VID();
    if (v && !v._playaProg) {
      v._playaProg = 1;
      var tick = 0;
      ON(v, "timeupdate", function () {
        try { if (++tick % 4) return; if (!v.duration || !isFinite(v.duration)) return; P.saveProgress(SHOWID(), v.currentTime, v.duration, D.title, W.location.href); } catch (_) {}
      });
    }
    P.renderContinue();
  } catch (_) {}
}
// PLYA-002
function w002() {
  try {
    P.upNext = function (nextUrl, nextTitle) {
      try {
        if (!D) return;
        var old = E("playa-upnext"); if (old) old.remove();
        try { if (nextUrl) P.prefetch(nextUrl); } catch (_) {}
        var ov = MK("div", "playa-overlay"); ov.id = "playa-upnext"; ov.setAttribute("role", "dialog"); ov.setAttribute("aria-label", "Up next");
        var left = 10;
        ov.appendChild(MK("div", "", "Up next: " + String(nextTitle || nextUrl || "next episode")));
        var cd = MK("div", "", "Starting in 10s…"); cd.style.opacity = ".8"; cd.style.margin = "6px 0"; ov.appendChild(cd);
        var row = MK("div", ""); row.style.display = "flex"; row.style.gap = "8px";
        var go = MK("button", "playa-btn", "Play now"); go.type = "button";
        var cx = MK("button", "playa-btn", "Cancel"); cx.type = "button";
        row.appendChild(go); row.appendChild(cx); ov.appendChild(row); D.body.appendChild(ov);
        var done = false;
        function fin(url) { if (done) return; done = true; try { clearInterval(iv); } catch (_) {} try { ov.remove(); } catch (_) {} if (url && W.location) W.location.href = url; }
        ON(go, "click", function () { fin(nextUrl); });
        ON(cx, "click", function () { done = true; try { clearInterval(iv); } catch (_) {} try { ov.remove(); } catch (_) {} TS("Auto-advance cancelled."); });
        var iv = setInterval(function () { left -= 1; if (left <= 0) { fin(nextUrl); return; } try { cd.textContent = "Starting in " + left + "s…"; } catch (_) {} }, 1000);
        try { ov._timer = iv; } catch (_) {}
      } catch (_) {}
    };
    var v = VID();
    if (v && !v._playaEnded) { v._playaEnded = 1; ON(v, "ended", function () { try { var nx = P.nextUrl ? P.nextUrl() : null; if (nx) P.upNext(nx.url, nx.title); } catch (_) {} }); }
    P.nextUrl = P.nextUrl || function () {
      try {
        var a = D.querySelector("[data-next-url],a[data-next-episode],.next-episode a"); if (a) return { url: a.href || a.getAttribute("data-next-url"), title: a.textContent.trim().slice(0, 80) };
        return null;
      } catch (_) { return null; }
    };
  } catch (_) {}
}
// PLYA-003
function w003() {
  try {
    P.skipRanges = function () { return GJ(LS.skip, {}); };
    P.setSkip = function (show, kind, s, e) { try { var m = GJ(LS.skip, {}); m[show] = m[show] || {}; m[show][kind] = [Number(s), Number(e)]; SJ(LS.skip, m); TS("Saved " + kind + " " + s + "s–" + e + "s for " + show + "."); } catch (_) {} };
    if (!D || E("playa-skipbar")) return;
    var bar = MK("div", "playa-skip"); bar.id = "playa-skipbar"; D.body.appendChild(bar);
    function paint() {
      try {
        while (bar.firstChild) bar.removeChild(bar.firstChild);
        var v = VID(); if (!v) return;
        var m = GJ(LS.skip, {})[SHOWID()]; if (!m) return;
        var t = v.currentTime;
        [["intro", "Skip intro"], ["recap", "Skip recap"]].forEach(function (pair) {
          var r = m[pair[0]]; if (!r) return;
          if (t >= r[0] - 2 && t <= r[1] + 1) {
            var b = MK("button", "playa-btn", pair[1] + " ≫"); b.type = "button";
            ON(b, "click", function () { try { v.currentTime = r[1] + 0.1; try { v.play(); } catch (_) {} } catch (_) {} });
            bar.appendChild(b);
          }
        });
      } catch (_) {}
    }
    var v2 = VID(); if (v2) ON(v2, "timeupdate", paint);
    setInterval(paint, 1500);
    var tools = MOUNT();
    if (tools && !E("playa-skipcfg")) { var c = MK("button", "playa-btn", "Skip times"); c.id = "playa-skipcfg"; c.type = "button"; c.title = "Set intro/recap ranges for this show (seconds)"; ON(c, "click", function () { try { var cur = GJ(LS.skip, {})[SHOWID()] || {}; var i = W.prompt("Intro range (start-end seconds):", cur.intro ? cur.intro.join("-") : "0-0"); if (i == null) return; var r = W.prompt("Recap range (start-end seconds):", cur.recap ? cur.recap.join("-") : "0-0"); if (r == null) return; function pr(s) { var p = String(s).split("-"); return [parseFloat(p[0]) || 0, parseFloat(p[1]) || 0]; } var m = GJ(LS.skip, {}); m[SHOWID()] = { intro: pr(i), recap: pr(r) }; SJ(LS.skip, m); TS("Skip ranges saved."); } catch (_) {} }); tools.appendChild(c); }
  } catch (_) {}
}
// PLYA-004
function w004() {
  try {
    P.avprefs = function () { return GJ(LS.av, {}); };
    P.applyAV = function () {
      try {
        var pref = GJ(LS.av, {})[SHOWID()]; if (!pref) return;
        var h = PH();
        try { if (h && typeof h.setAudioTrack === "function" && pref.audio != null) h.setAudioTrack(pref.audio); } catch (_) {}
        try { if (h && typeof h.setSubtitleTrack === "function" && pref.subs != null) h.setSubtitleTrack(pref.subs); } catch (_) {}
        var v = VID();
        if (v) {
          try { if (pref.subs === -1) { Array.prototype.forEach.call(v.textTracks || [], function (t) { t.mode = "disabled"; }); } } catch (_) {}
          try { v.setAttribute("data-playa-audio", pref.audio == null ? "" : String(pref.audio)); v.setAttribute("data-playa-subs", pref.subs == null ? "" : String(pref.subs)); } catch (_) {}
        }
      } catch (_) {}
    };
    var tools = MOUNT();
    if (tools && D && !E("playa-avsave")) {
      var b = MK("button", "playa-btn", "Remember A/V"); b.id = "playa-avsave"; b.type = "button"; b.title = "Remember audio/subtitle choice for this show";
      ON(b, "click", function () {
        try {
          var h = PH(); var audio = null, subs = null;
          try { if (h && typeof h.getAudioTrack === "function") audio = h.getAudioTrack(); } catch (_) {}
          try { if (h && typeof h.getSubtitleTrack === "function") subs = h.getSubtitleTrack(); } catch (_) {}
          var v = VID();
          if (audio == null && v) audio = v.getAttribute("data-playa-audio") || "default";
          if (subs == null && v) subs = v.getAttribute("data-playa-subs") || "default";
          var m = GJ(LS.av, {}); m[SHOWID()] = { audio: audio, subs: subs }; SJ(LS.av, m); TS("A/V preference saved for this show.");
        } catch (_) {}
      });
      tools.appendChild(b);
    }
    var v2 = VID(); if (v2 && !v2._playaAV) { v2._playaAV = 1; ON(v2, "play", function () { try { P.applyAV(); } catch (_) {} }); }
    try { P.applyAV(); } catch (_) {}
  } catch (_) {}
}
// PLYA-005
function w005() {
  try {
    P.subOffset = function () { return Number(G(LS.off, "0")) || 0; };
    P.applySubOffset = function (ms) {
      try {
        SV(LS.off, String(ms));
        var h = PH();
        if (h && typeof h.setSubtitleOffset === "function") { h.setSubtitleOffset(ms); return true; }
        try { if (h) h.subtitleOffset = ms; } catch (_) {}
        var v = VID();
        if (v) { try { v.setAttribute("data-playa-suboffset", String(ms)); } catch (_) {} }
        return false;
      } catch (_) { return false; }
    };
    var tools = MOUNT();
    if (tools && D && !E("playa-suboff")) {
      var wrap = MK("span", ""); wrap.id = "playa-suboff"; wrap.title = "Subtitle offset (stored; applied via player hook when available)";
      var lab = MK("span", "", "Subs "); lab.style.opacity = ".75"; wrap.appendChild(lab);
      var m = MK("button", "playa-btn", "−500ms"); m.type = "button";
      var cur = MK("span", "", " " + P.subOffset() + "ms "); cur.id = "playa-suboff-cur";
      var p = MK("button", "playa-btn", "+500ms"); p.type = "button";
      ON(m, "click", function () { var n = P.subOffset() - 500; P.applySubOffset(n); try { cur.textContent = " " + n + "ms "; } catch (_) {} TS("Subtitle offset " + n + "ms."); });
      ON(p, "click", function () { var n = P.subOffset() + 500; P.applySubOffset(n); try { cur.textContent = " " + n + "ms "; } catch (_) {} TS("Subtitle offset " + n + "ms."); });
      wrap.appendChild(m); wrap.appendChild(cur); wrap.appendChild(p); tools.appendChild(wrap);
    }
  } catch (_) {}
}
// PLYA-006
function w006() {
  try {
    P.streamUrls = function () {
      try {
        var out = [];
        var v = VID();
        if (v) {
          if (v.currentSrc) out.push({ label: "current", url: v.currentSrc });
          if (v.src) out.push({ label: "src", url: v.src });
          Array.prototype.forEach.call(v.querySelectorAll("source[src]"), function (s) { out.push({ label: s.getAttribute("label") || s.getAttribute("data-quality") || "source", url: s.src }); });
        }
        Array.prototype.forEach.call(D.querySelectorAll("[data-stream-url]"), function (n) { var u = n.getAttribute("data-stream-url"); if (u) out.push({ label: n.getAttribute("data-quality") || n.textContent.trim().slice(0, 24) || "stream", url: u }); });
        var seen = {}, uniq = [];
        out.forEach(function (o) { if (o.url && !seen[o.url]) { seen[o.url] = 1; uniq.push(o); } });
        return uniq;
      } catch (_) { return []; }
    };
    P.switchQuality = function (url, label) {
      try {
        var v = VID(); if (!v || !url) return false;
        var t = 0; try { t = v.currentTime || 0; } catch (_) {}
        var playing = false; try { playing = !v.paused; } catch (_) {}
        try { v.src = url; try { v.setAttribute("data-playa-quality", label || url); } catch (_) {} SV(LS.qual, label || url); } catch (_) { return false; }
        try { v.load(); } catch (_) {}
        function resume() { try { v.currentTime = t; } catch (_) {} try { if (playing) v.play(); } catch (_) {} try { v.removeEventListener("loadedmetadata", resume); } catch (_) {} }
        try { v.addEventListener("loadedmetadata", resume); setTimeout(resume, 1500); } catch (_) {}
        TS("Quality: " + (label || "switched") + " (position kept).");
        return true;
      } catch (_) { return false; }
    };
    var tools = MOUNT();
    if (tools && D && !E("playa-quality")) {
      var b = MK("button", "playa-btn", "Quality ▾"); b.id = "playa-quality"; b.type = "button";
      ON(b, "click", function () {
        try {
          var old = E("playa-qmenu"); if (old) { old.remove(); return; }
          var list = P.streamUrls();
          if (!list.length) { TS("No alternate stream URLs found."); return; }
          var menu = MK("div", "playa-menu"); menu.id = "playa-qmenu";
          list.forEach(function (o) {
            var it = MK("button", "playa-btn", o.label); it.type = "button"; it.style.display = "block"; it.style.width = "100%"; it.style.margin = "2px 0"; it.title = o.url;
            ON(it, "click", function () { P.switchQuality(o.url, o.label); try { menu.remove(); } catch (_) {} });
            menu.appendChild(it);
          });
          tools.style.position = tools.style.position || "relative"; tools.appendChild(menu);
          setTimeout(function () { ON(D, "click", function h(ev) { try { if (!menu.contains(ev.target) && ev.target !== b) { menu.remove(); D.removeEventListener("click", h); } } catch (_) {} }); }, 0);
        } catch (_) {}
      });
      tools.appendChild(b);
    }
  } catch (_) {}
}
// PLYA-007
function w007() {
  try {
    P.prefetch = function (url) {
      try {
        if (!url || !D) return false;
        if (D.querySelector('link[data-playa-prefetch="' + url + '"]')) return true;
        var l = D.createElement("link"); l.rel = "prefetch"; l.href = url; l.setAttribute("data-playa-prefetch", url);
        D.head.appendChild(l);
        try { var v = D.createElement("video"); v.preload = "metadata"; v.src = url; v.style.display = "none"; v.setAttribute("data-playa-prebuffer", "1"); D.body.appendChild(v); setTimeout(function () { try { v.remove(); } catch (_) {} }, 60000); } catch (_) {}
        return true;
      } catch (_) { return false; }
    };
  } catch (_) {}
}
// PLYA-008
function w008() {
  try {
    P.randomEpisode = function () {
      try {
        var eps = Array.prototype.slice.call(D.querySelectorAll("a[data-episode-id],[data-episode] a,.episode-card a,.episode a,a[href*='episode' i]"));
        eps = eps.filter(function (a) { return a && (a.href || a.getAttribute("data-url")); });
        if (!eps.length) {
          var cards = Array.prototype.slice.call(D.querySelectorAll("[data-episode-id],[data-ep]"));
          if (cards.length) { var pick = cards[Math.floor(Math.random() * cards.length)]; try { pick.click(); TS("Shuffling…"); return true; } catch (_) {} }
          TS("No episode list found on this page."); return false;
        }
        var el = eps[Math.floor(Math.random() * eps.length)];
        var url = el.href || el.getAttribute("data-url");
        if (url) { W.location.href = url; return true; }
        try { el.click(); return true; } catch (_) { return false; }
      } catch (_) { return false; }
    };
    var tools = MOUNT();
    if (tools && D && !E("playa-shuffle")) {
      var b = MK("button", "playa-btn", "🔀 Random episode"); b.id = "playa-shuffle"; b.type = "button"; b.title = "Play a random episode from this series";
      ON(b, "click", function () { P.randomEpisode(); });
      tools.appendChild(b);
    }
  } catch (_) {}
}
// PLYA-009
function w009() {
  try {
    P.roomLink = function () {
      try {
        var v = VID(); var t = 0; try { t = Math.floor(v ? v.currentTime : 0); } catch (_) {}
        var room = ""; try { room = (G("playa.room", "") || ""); } catch (_) {}
        if (!room) { room = "r" + Math.random().toString(36).slice(2, 8); try { SV("playa.room", room); } catch (_) {} }
        var base = String(W.location.href).split("?")[0].split("#")[0];
        return base + "?room=" + encodeURIComponent(room) + "&t=" + t + "#playa=" + t;
      } catch (_) { return String(W.location.href); }
    };
    var tools = MOUNT();
    if (tools && D && !E("playa-room")) {
      var b = MK("button", "playa-btn", "Watch together 🔗"); b.id = "playa-room"; b.type = "button"; b.title = "Copy a shared-timestamp link for this position";
      ON(b, "click", function () { try { CP(P.roomLink(), "Room link copied — share it to sync."); } catch (_) {} });
      tools.appendChild(b);
    }
    try {
      var m = /[?&#]t=(\d+)/.exec(W.location.search + W.location.hash) || /playa=(\d+)/.exec(W.location.hash);
      if (m) { var t0 = parseInt(m[1], 10); var v2 = VID(); if (v2 && isFinite(t0) && t0 > 0) { ON(v2, "loadedmetadata", function () { try { v2.currentTime = t0; TS("Synced to shared position " + t0 + "s."); } catch (_) {} }); } }
    } catch (_) {}
  } catch (_) {}
}
// PLYA-010
function w010() {
  try {
    P.pip = function () {
      try {
        var v = VID(); if (!v) { TS("No video on this page."); return false; }
        if (D.pictureInPictureElement) { try { D.exitPictureInPicture(); return true; } catch (_) { return false; } }
        if (typeof v.requestPictureInPicture === "function") { v.requestPictureInPicture().then(function () {}, function () { TS("Picture-in-picture blocked."); }); return true; }
        try { v.setAttribute("data-playa-pip", "1"); } catch (_) {}
        TS("Picture-in-picture not supported here."); return false;
      } catch (_) { return false; }
    };
    var tools = MOUNT();
    if (tools && D && !E("playa-pip")) {
      var b = MK("button", "playa-btn", "PiP ⧉"); b.id = "playa-pip"; b.type = "button"; b.title = "Toggle picture-in-picture for the current video";
      ON(b, "click", function () { P.pip(); });
      tools.appendChild(b);
    }
  } catch (_) {}
}
[w001, w002, w003, w004, w005, w006, w007, w008, w009, w010].forEach(function (f) { try { f(); } catch (_) {} });
try { TS("Playback extras ready."); } catch (_) {}
} catch (_) {}
})();
