(function () {
"use strict";
try { if (window.__plyeLoaded) return; window.__plyeLoaded = true; } catch (_) {}
try {
var DOC = document, WIN = window;
function $(sel, root) { try { return (root || DOC).querySelector(sel); } catch (_) { return null; } }
function $all(sel, root) { try { return Array.prototype.slice.call((root || DOC).querySelectorAll(sel)); } catch (_) { return []; } }
function mk(tag, cls, text) { var n = DOC.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; }
function lsGet(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : v; } catch (_) { return d; } }
function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (_) {} }
function lsGetJ(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } }
function lsSetJ(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} }
function toast(msg) { try { var t = DOC.getElementById("toast"); if (t) { t.textContent = msg; t.className = "toast show"; clearTimeout(toast._t); toast._t = setTimeout(function () { t.classList.remove("show"); }, 2400); } } catch (_) {} }
function video() {
  try {
    var v = $("video");
    if (v) return v;
    var vs = $all("video"); if (vs.length) return vs[0];
  } catch (_) {}
  return null;
}
function titleKey() {
  try {
    var p = $("#playback-status");
    if (p && p.textContent) { var t = p.textContent.trim().split("\n")[0].trim(); if (t && t.length > 1 && t.length < 140) return t.slice(0, 80); }
    var h = $("h1,h2,.detail-title,[data-title]");
    if (h && h.textContent && h.textContent.trim().length > 1) return h.textContent.trim().slice(0, 80);
    if (DOC.title) return DOC.title.replace(/\s*[|\-–]\s*Jellyfin.*$/i, "").trim().slice(0, 80) || "default";
  } catch (_) {}
  return "default";
}
function CSS() {
  if (DOC.getElementById("playe-style")) return;
  var s = DOC.createElement("style"); s.id = "playe-style";
  s.textContent = ".playe-bar{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin:0 0 10px;padding:8px;border:1px solid var(--accent-ring,#334);border-radius:10px;font-size:12px;background:var(--bg,#0e1522);color:var(--text,#e6edf7)}.playe-btn{cursor:pointer;border:1px solid var(--accent-ring,#334);border-radius:8px;padding:3px 10px;font-size:12px;background:transparent;color:var(--text,#e6edf7)}.playe-btn:hover{border-color:var(--accent,#4f8cff)}.playe-btn.is-on{color:#cfe1ff;border-color:var(--accent,#4f8cff)}.playe-badge{display:inline-flex;align-items:center;gap:4px;font-size:11px;padding:2px 8px;border-radius:999px;border:1px solid var(--accent-ring,#334);color:var(--muted,#999)}.playe-badge.is-on{color:#cfe1ff;border-color:var(--accent,#4f8cff)}.playe-sel{font:inherit;font-size:12px;padding:3px 8px;border-radius:8px;border:1px solid var(--accent-ring,#334);background:var(--bg,#0e1522);color:var(--text,#e6edf7)}.playe-side{position:fixed;top:64px;right:12px;z-index:60;width:min(280px,80vw);max-height:60vh;overflow:auto;background:var(--bg,#0e1522);color:var(--text,#e6edf7);border:1px solid var(--accent-ring,#334);border-radius:12px;padding:10px;font-size:12px}.playe-side button{cursor:pointer}.playe-hint{position:fixed;z-index:70;pointer-events:none;background:var(--bg,#0e1522);color:var(--text,#e6edf7);border:1px solid var(--accent-ring,#334);border-radius:8px;padding:4px 8px;font-size:12px;opacity:0;transition:opacity .15s}.playe-hint.show{opacity:1}.playe-chat{position:fixed;bottom:12px;right:12px;z-index:60;width:min(300px,86vw);background:var(--bg,#0e1522);color:var(--text,#e6edf7);border:1px solid var(--accent-ring,#334);border-radius:12px;padding:8px;font-size:12px}.playe-chat-list{max-height:160px;overflow:auto;margin:6px 0;display:flex;flex-direction:column;gap:4px}.playe-chat-row{background:rgba(127,140,160,.12);border-radius:8px;padding:4px 6px;word-break:break-word}.playe-chat-form{display:flex;gap:6px}.playe-chat-form input{flex:1;font:inherit;font-size:12px;padding:4px 8px;border-radius:8px;border:1px solid var(--accent-ring,#334);background:transparent;color:var(--text,#e6edf7)}body.playe-dualsub track::cue(:nth-child(2n)){color:#ffe9a8}body.playe-dualsub video::cue{font-size:1.05em}";
  try { DOC.head.appendChild(s); } catch (_) {}
}
function bar() {
  CSS();
  var b = DOC.getElementById("playe-bar");
  if (b) return b;
  b = mk("div", "playe-bar"); b.id = "playe-bar";
  b.setAttribute("role", "toolbar"); b.setAttribute("aria-label", "Playback enhancement wins");
  var anchor = $("#playback-status") || $("main.shell") || $("main") || DOC.body;
  try {
    if (anchor && anchor.id === "playback-status" && anchor.parentElement) anchor.parentElement.insertBefore(b, anchor);
    else if (anchor && anchor.firstChild) anchor.insertBefore(b, anchor.firstChild);
    else DOC.body.appendChild(b);
  } catch (_) { try { DOC.body.appendChild(b); } catch (_) {} }
  return b;
}

// PLYE-001
function wDualSub(host) {
  try {
    var KEY = "playe.dualsub";
    var btn = mk("button", "playe-btn", "Dual subs: off");
    btn.type = "button"; btn.title = "Toggle dual-subtitle display";
    function paint(on) {
      btn.textContent = "Dual subs: " + (on ? "on" : "off");
      btn.classList.toggle("is-on", !!on);
      btn.setAttribute("aria-pressed", on ? "true" : "false");
    }
    var on = lsGet(KEY, "0") === "1";
    function apply() {
      try { DOC.body.classList.toggle("playe-dualsub", on); } catch (_) {}
      try {
        var v = video(); if (!v) return;
        var tracks = v.textTracks || [];
        var shown = 0;
        for (var i = 0; i < tracks.length; i++) {
          try {
            if (tracks[i].mode === "showing") shown++;
            if (on && shown < 2 && tracks[i].mode === "disabled") { tracks[i].mode = "showing"; shown++; }
            if (!on && shown > 1 && tracks[i].mode === "showing") { tracks[i].mode = "disabled"; shown--; }
          } catch (_) {}
        }
      } catch (_) {}
    }
    paint(on); apply();
    btn.addEventListener("click", function () { on = !on; lsSet(KEY, on ? "1" : "0"); paint(on); apply(); toast("Dual subtitles " + (on ? "on" : "off")); });
    host.appendChild(btn);
  } catch (_) {}
}

// PLYE-002
function wAudioCycler(host) {
  try {
    var badge = mk("span", "playe-badge", "Audio: default");
    var btn = mk("button", "playe-btn", "Audio track");
    btn.type = "button"; btn.title = "Cycle audio tracks (when exposed)";
    function label() {
      try {
        var v = video();
        if (v && v.audioTracks && v.audioTracks.length) {
          for (var i = 0; i < v.audioTracks.length; i++) {
            if (v.audioTracks[i].enabled) return "Audio: " + (v.audioTracks[i].label || v.audioTracks[i].language || ("track " + (i + 1)));
          }
          return "Audio: " + v.audioTracks.length + " tracks";
        }
        var sel = $('audio, select[name="audio"], [data-audio-track]');
        if (sel && sel.getAttribute) { var l = sel.getAttribute("data-audio-track") || sel.getAttribute("aria-label"); if (l) return "Audio: " + l.slice(0, 32); }
      } catch (_) {}
      return "Audio: default";
    }
    function paint() { badge.textContent = label(); }
    paint();
    btn.addEventListener("click", function () {
      try {
        var v = video();
        if (v && v.audioTracks && v.audioTracks.length > 1) {
          var idx = 0;
          for (var i = 0; i < v.audioTracks.length; i++) { if (v.audioTracks[i].enabled) { idx = i; break; } }
          var next = (idx + 1) % v.audioTracks.length;
          for (var j = 0; j < v.audioTracks.length; j++) { try { v.audioTracks[j].enabled = (j === next); } catch (_) {} }
        }
      } catch (_) {}
      paint(); toast(badge.textContent);
    });
    try { WIN.setInterval(paint, 5000); } catch (_) {}
    host.appendChild(badge); host.appendChild(btn);
  } catch (_) {}
}

// PLYE-003
function wChapters(host) {
  try {
    var btn = mk("button", "playe-btn", "Chapters");
    btn.type = "button"; btn.title = "Chapter list sidebar";
    btn.setAttribute("aria-expanded", "false");
    var panel = null;
    function collect() {
      var out = [];
      try {
        var nodes = $all("[data-chapter], .chapter, [data-chapter-index], .chapter-item");
        nodes.forEach(function (n, i) {
          var t = (n.textContent || "").trim().slice(0, 60) || ("Chapter " + (i + 1));
          var sec = parseFloat(n.getAttribute("data-start") || n.getAttribute("data-time") || "NaN");
          out.push({ title: t, start: isNaN(sec) ? null : sec, el: n });
        });
        var v = video();
        if (!out.length && v && v.textTracks) {
          for (var k = 0; k < v.textTracks.length; k++) {
            try {
              var tr = v.textTracks[k];
              if (tr && tr.kind === "chapters" && tr.cues) {
                for (var c = 0; c < tr.cues.length; c++) { out.push({ title: (tr.cues[c].text || "").slice(0, 60) || ("Chapter " + (c + 1)), start: tr.cues[c].startTime, el: null }); }
                break;
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
      return out;
    }
    function toggle() {
      try {
        if (panel) { try { panel.remove(); } catch (_) {} panel = null; btn.setAttribute("aria-expanded", "false"); btn.classList.remove("is-on"); return; }
        panel = mk("div", "playe-side");
        panel.setAttribute("role", "complementary"); panel.setAttribute("aria-label", "Chapter list");
        var h = mk("div", null, "Chapters"); h.style.fontWeight = "700"; h.style.marginBottom = "6px";
        panel.appendChild(h);
        var list = collect();
        if (!list.length) panel.appendChild(mk("div", null, "No chapters found for this item."));
        list.forEach(function (ch) {
          var r = mk("button", "playe-btn", ch.title + (ch.start != null ? " · " + Math.round(ch.start) + "s" : ""));
          r.type = "button"; r.style.display = "block"; r.style.width = "100%"; r.style.margin = "4px 0"; r.style.textAlign = "left";
          r.addEventListener("click", function () {
            try {
              if (ch.start != null) { var v = video(); if (v) { try { v.currentTime = ch.start; } catch (_) {} } }
              else if (ch.el && ch.el.scrollIntoView) ch.el.scrollIntoView({ block: "center" });
            } catch (_) {}
          });
          panel.appendChild(r);
        });
        var close = mk("button", "playe-btn", "Close");
        close.type = "button"; close.style.marginTop = "6px";
        close.addEventListener("click", toggle);
        panel.appendChild(close);
        DOC.body.appendChild(panel);
        btn.setAttribute("aria-expanded", "true"); btn.classList.add("is-on");
      } catch (_) {}
    }
    btn.addEventListener("click", toggle);
    host.appendChild(btn);
  } catch (_) {}
}

// PLYE-004
function wScrubHint(host) {
  try {
    var hint = mk("div", "playe-hint", "");
    try { DOC.body.appendChild(hint); } catch (_) { return; }
    function fmt(s) { try { s = Math.max(0, Math.floor(s)); var m = Math.floor(s / 60), r = s % 60; return m + ":" + (r < 10 ? "0" : "") + r; } catch (_) { return ""; } }
    function show(text, x, y) { hint.textContent = text; hint.style.left = Math.max(8, x) + "px"; hint.style.top = Math.max(8, y - 34) + "px"; hint.classList.add("show"); }
    function hide() { hint.classList.remove("show"); }
    function guess(sel) {
      try {
        var v = video(); if (!v || !v.duration) return null;
        var el = sel.currentTarget || sel.target || null;
        return v.duration;
      } catch (_) { return null; }
    }
    ["input[type=range]", "[role=slider]", ".scrub-bar", ".seek-bar", "progress"].forEach(function (s) {
      $all(s).forEach(function (n) {
        try {
          if (n.__plyeScrub) return; n.__plyeScrub = true;
          n.addEventListener("mousemove", function (e) {
            try {
              var v = video(); if (!v || !v.duration) return;
              var r = n.getBoundingClientRect ? n.getBoundingClientRect() : null;
              var frac = 0.5;
              if (r && r.width) frac = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
              else if (n.max) frac = (parseFloat(n.value || "0") / parseFloat(n.max || "100"));
              show("Preview ~" + fmt(v.duration * frac), e.clientX || 0, e.clientY || 0);
            } catch (_) {}
          });
          n.addEventListener("mouseleave", hide);
        } catch (_) {}
      });
    });
    void guess; void host;
  } catch (_) {}
}

// PLYE-005
function wWheelVolume(host) {
  try {
    var KEY = "playe.wheelvol";
    var btn = mk("button", "playe-btn", "Wheel vol: on");
    btn.type = "button"; btn.title = "Wheel over video adjusts volume";
    var on = lsGet(KEY, "1") === "1";
    function paint() { btn.textContent = "Wheel vol: " + (on ? "on" : "off"); btn.classList.toggle("is-on", !!on); btn.setAttribute("aria-pressed", on ? "true" : "false"); }
    paint();
    btn.addEventListener("click", function () { on = !on; lsSet(KEY, on ? "1" : "0"); paint(); });
    host.appendChild(btn);
    $all("video").forEach(function (v) {
      try {
        if (v.__plyeWheel) return; v.__plyeWheel = true;
        v.addEventListener("wheel", function (e) {
          if (!on) return;
          try {
            e.preventDefault();
            var d = (e.deltaY || 0) > 0 ? -0.05 : 0.05;
            v.volume = Math.min(1, Math.max(0, (v.volume == null ? 1 : v.volume) + d));
            toast("Volume " + Math.round(v.volume * 100) + "%");
          } catch (_) {}
        }, { passive: false });
      } catch (_) {}
    });
    try {
      var mo = new MutationObserver(function () {
        $all("video").forEach(function (v) {
          try {
            if (v.__plyeWheel) return; v.__plyeWheel = true;
            v.addEventListener("wheel", function (e) {
              if (!on) return;
              try { e.preventDefault(); var d = (e.deltaY || 0) > 0 ? -0.05 : 0.05; v.volume = Math.min(1, Math.max(0, (v.volume == null ? 1 : v.volume) + d)); } catch (_) {}
            }, { passive: false });
          } catch (_) {}
        });
      });
      mo.observe(DOC.documentElement, { childList: true, subtree: true });
    } catch (_) {}
  } catch (_) {}
}

// PLYE-006
function wDoubleTap(host) {
  try {
    var hint = DOC.getElementById("playe-dtap");
    if (!hint) { hint = mk("div", "playe-hint", "Double-tap sides to ±10s"); hint.id = "playe-dtap"; try { DOC.body.appendChild(hint); } catch (_) {} }
    var btn = mk("button", "playe-btn", "Double-tap seek");
    btn.type = "button"; btn.title = "Double-tap / double-click sides to seek";
    btn.setAttribute("aria-pressed", "false");
    var lastTap = 0;
    function seek(dir) {
      try {
        var v = video(); if (!v) { toast("No video playing"); return; }
        try { v.currentTime = Math.max(0, (v.currentTime || 0) + dir * 10); } catch (_) {}
        hint.textContent = (dir < 0 ? "−10s" : "+10s"); hint.style.left = "50%"; hint.style.top = "18%";
        hint.classList.add("show"); setTimeout(function () { hint.classList.remove("show"); }, 600);
      } catch (_) {}
    }
    btn.addEventListener("click", function () { toast("Double-tap left/right of video to ±10s"); });
    $all("video").forEach(function (v) {
      try {
        if (v.__plyeDtap) return; v.__plyeDtap = true;
        v.addEventListener("dblclick", function (e) {
          try {
            var r = v.getBoundingClientRect ? v.getBoundingClientRect() : null;
            var dir = 1;
            if (r && e.clientX < r.left + r.width / 2) dir = -1;
            seek(dir);
          } catch (_) { seek(1); }
        });
        v.addEventListener("touchend", function (e) {
          try {
            var now = Date.now();
            if (now - lastTap < 350) {
              var x = (e.changedTouches && e.changedTouches[0] && e.changedTouches[0].clientX) || 0;
              var r = v.getBoundingClientRect ? v.getBoundingClientRect() : null;
              seek(r && x < r.left + r.width / 2 ? -1 : 1);
              lastTap = 0;
            } else lastTap = now;
          } catch (_) {}
        });
      } catch (_) {}
    });
    host.appendChild(btn);
  } catch (_) {}
}

// PLYE-007
function wSleepFade(host) {
  try {
    var sel = DOC.createElement("select"); sel.className = "playe-sel"; sel.title = "Sleep timer with fade-out";
    sel.setAttribute("aria-label", "Sleep timer");
    [["0", "Sleep: off"], ["15", "Sleep: 15m"], ["30", "Sleep: 30m"], ["45", "Sleep: 45m"], ["60", "Sleep: 60m"]].forEach(function (o) {
      var op = DOC.createElement("option"); op.value = o[0]; op.textContent = o[1]; sel.appendChild(op);
    });
    sel.value = lsGet("playe.sleep", "0");
    var timer = null, fadeTimer = null;
    function clear() { try { if (timer) clearTimeout(timer); } catch (_) {} try { if (fadeTimer) clearInterval(fadeTimer); } catch (_) {} timer = null; fadeTimer = null; }
    function fadeAndPause() {
      try {
        var v = video();
        if (!v) return;
        var vol0 = (v.volume == null ? 1 : v.volume);
        var steps = 20, i = 0;
        fadeTimer = WIN.setInterval(function () {
          try {
            i++;
            v.volume = Math.max(0, vol0 * (1 - i / steps));
            if (i >= steps) { try { clearInterval(fadeTimer); } catch (_) {} try { v.pause(); } catch (_) {} try { v.volume = vol0; } catch (_) {} toast("Sleep timer: paused"); }
          } catch (_) { try { clearInterval(fadeTimer); } catch (_) {} }
        }, 250);
      } catch (_) {}
    }
    sel.addEventListener("change", function () {
      clear(); lsSet("playe.sleep", sel.value);
      var m = parseInt(sel.value, 10) || 0;
      if (!m) { toast("Sleep timer off"); return; }
      toast("Sleep in " + m + "m (fades out)");
      timer = WIN.setTimeout(fadeAndPause, m * 60 * 1000);
    });
    host.appendChild(sel);
  } catch (_) {}
}

// PLYE-008
function wIntroMark(host) {
  try {
    function key() { return "playe.intro." + titleKey(); }
    var save = mk("button", "playe-btn", "Save intro");
    save.type = "button"; save.title = "Save current time as intro bookmark";
    var jump = mk("button", "playe-btn", "Intro ▸");
    jump.type = "button"; jump.title = "Jump to saved intro bookmark";
    save.addEventListener("click", function () {
      try {
        var v = video(); if (!v) { toast("No video playing"); return; }
        lsSet(key(), String(Math.floor(v.currentTime || 0))); toast("Intro saved");
      } catch (_) {}
    });
    jump.addEventListener("click", function () {
      try {
        var v = video(); if (!v) { toast("No video playing"); return; }
        var s = parseFloat(lsGet(key(), "NaN"));
        if (isNaN(s)) { toast("No intro bookmark"); return; }
        try { v.currentTime = Math.max(0, s); } catch (_) {}
      } catch (_) {}
    });
    host.appendChild(save); host.appendChild(jump);
  } catch (_) {}
}

// PLYE-009
function wRecapMark(host) {
  try {
    function key() { return "playe.recap." + titleKey(); }
    var save = mk("button", "playe-btn", "Save recap");
    save.type = "button"; save.title = "Save current time as recap bookmark";
    var jump = mk("button", "playe-btn", "Recap ▸");
    jump.type = "button"; jump.title = "Jump to saved recap bookmark";
    save.addEventListener("click", function () {
      try {
        var v = video(); if (!v) { toast("No video playing"); return; }
        lsSet(key(), String(Math.floor(v.currentTime || 0))); toast("Recap saved");
      } catch (_) {}
    });
    jump.addEventListener("click", function () {
      try {
        var v = video(); if (!v) { toast("No video playing"); return; }
        var s = parseFloat(lsGet(key(), "NaN"));
        if (isNaN(s)) { toast("No recap bookmark"); return; }
        try { v.currentTime = Math.max(0, s); } catch (_) {}
      } catch (_) {}
    });
    host.appendChild(save); host.appendChild(jump);
  } catch (_) {}
}

// PLYE-010
function wPartyChat(host) {
  try {
    var KEY = "playe.party";
    var btn = mk("button", "playe-btn", "Party chat");
    btn.type = "button"; btn.title = "Watch-party chat (local only)";
    btn.setAttribute("aria-expanded", "false");
    var box = null;
    function load() { return lsGetJ(KEY, []); }
    function render(list) {
      try {
        list.innerHTML = "";
        load().slice(-50).forEach(function (m) {
          var r = mk("div", "playe-chat-row", (m.n || "Me") + ": " + (m.t || ""));
          list.appendChild(r);
        });
        list.scrollTop = list.scrollHeight;
      } catch (_) {}
    }
    function toggle() {
      try {
        if (box) { try { box.remove(); } catch (_) {} box = null; btn.setAttribute("aria-expanded", "false"); btn.classList.remove("is-on"); return; }
        box = mk("div", "playe-chat");
        box.setAttribute("role", "dialog"); box.setAttribute("aria-label", "Watch-party chat (local only)");
        box.appendChild(mk("div", null, "Party chat · local only")).style.fontWeight = "700";
        var note = mk("div", "playe-badge", "stored in this browser only");
        box.appendChild(note);
        var list = mk("div", "playe-chat-list"); list.id = "playe-chat-list";
        box.appendChild(list); render(list);
        var form = mk("div", "playe-chat-form");
        var inp = DOC.createElement("input"); inp.type = "text"; inp.placeholder = "Message…"; inp.setAttribute("aria-label", "Chat message");
        var send = mk("button", "playe-btn", "Send"); send.type = "button";
        function push() {
          try {
            var t = (inp.value || "").trim(); if (!t) return;
            var h = load(); h.push({ n: "Me", t: t.slice(0, 300), at: Date.now() });
            lsSetJ(KEY, h.slice(-100)); inp.value = ""; render(list);
          } catch (_) {}
        }
        send.addEventListener("click", push);
        inp.addEventListener("keydown", function (e) { try { if (e.key === "Enter") push(); if (e.key === "Escape" && box) { box.remove(); box = null; } } catch (_) {} });
        var close = mk("button", "playe-btn", "Close"); close.type = "button";
        close.addEventListener("click", toggle);
        form.appendChild(inp); form.appendChild(send);
        box.appendChild(form); box.appendChild(close);
        DOC.body.appendChild(box);
        try { inp.focus(); } catch (_) {}
        btn.setAttribute("aria-expanded", "true"); btn.classList.add("is-on");
      } catch (_) {}
    }
    btn.addEventListener("click", toggle);
    host.appendChild(btn);
  } catch (_) {}
}

try {
  var b = bar();
  wDualSub(b); wAudioCycler(b); wChapters(b); wScrubHint(b); wWheelVolume(b);
  wDoubleTap(b); wSleepFade(b); wIntroMark(b); wRecapMark(b); wPartyChat(b);
} catch (_) {}
} catch (_) {}
})();
