"use strict";
(function () {
  if (typeof window === "undefined" || typeof document === "undefined") return;
  if (window.__plycLoaded) return;
  window.__plycLoaded = true;

  function vid() {
    try {
      if (window.__player && window.__player.video) return window.__player.video;
      if (window.playbackManager && typeof window.playbackManager.currentMediaElement === "function") {
        var m = window.playbackManager.currentMediaElement();
        if (m) return m;
      }
    } catch (_) { /* ignore */ }
    return document.querySelector("video");
  }

  function ensureBar() {
    var bar = document.getElementById("playc-bar");
    if (bar) return bar;
    bar = document.createElement("div");
    bar.id = "playc-bar";
    bar.setAttribute("role", "toolbar");
    bar.setAttribute("aria-label", "Playback wins");
    try { document.body.appendChild(bar); } catch (_) { return null; }
    return bar;
  }

  function ensureStyle() {
    if (document.getElementById("playc-style")) return;
    var st = document.createElement("style");
    st.id = "playc-style";
    st.textContent = [
      ":root{--plyc-bg:#14161c;--plyc-fg:#e8eaf0;--plyc-accent:#7c6cf0;--plyc-muted:#9aa0b4;}",
      "#playc-bar{position:fixed;right:12px;bottom:12px;z-index:9999;display:flex;flex-wrap:wrap;gap:6px;",
      "max-width:min(420px,90vw);padding:8px;border-radius:12px;background:var(--plyc-bg);color:var(--plyc-fg);",
      "border:1px solid rgba(255,255,255,.12);box-shadow:0 8px 24px rgba(0,0,0,.45);font:12px/1.4 system-ui,sans-serif;}",
      "#playc-bar button,#playc-bar select,#playc-bar input{background:#1e2230;color:var(--plyc-fg);",
      "border:1px solid rgba(255,255,255,.14);border-radius:8px;padding:4px 8px;font-size:12px;cursor:pointer;}",
      "#playc-bar button[aria-pressed='true']{outline:2px solid var(--plyc-accent);}",
      "#playc-bar input[type=range]{padding:0;}",
      "#playc-resume-row{display:flex;gap:6px;align-items:center;width:100%;overflow-x:auto;}",
      "#playc-resume-row .playc-card{display:flex;gap:6px;align-items:center;white-space:nowrap;}",
      "#playc-resume-row progress{width:64px;height:8px;}",
      ".playc-theater-dim{position:fixed;inset:0;background:rgba(0,0,0,.72);z-index:9998;pointer-events:none;}",
      ".playc-countdown{position:fixed;right:16px;bottom:110px;z-index:10000;background:var(--plyc-bg);",
      "color:var(--plyc-fg);border:1px solid var(--plyc-accent);border-radius:10px;padding:8px 10px;}"
    ].join("\n");
    try { document.head.appendChild(st); } catch (_) { /* no-op */ }
  }

  function btn(label, title, onClick) {
    var b = document.createElement("button");
    b.type = "button";
    b.textContent = label;
    if (title) b.title = title;
    b.addEventListener("click", onClick);
    return b;
  }

  function init() {
    ensureStyle();
    var bar = ensureBar();
    if (!bar) return;

    // PLYC-001 resume-all row with progress
    try {
      var row = document.createElement("div");
      row.id = "playc-resume-row";
      row.setAttribute("aria-label", "Resume all");
      var cards = Array.prototype.slice.call(document.querySelectorAll("[data-resume],.resume-card,.card"));
      if (!cards.length) {
        var ph = document.createElement("span");
        ph.style.color = "var(--plyc-muted)";
        ph.textContent = "Nothing to resume";
        row.appendChild(ph);
      } else {
        cards.slice(0, 12).forEach(function (c) {
          var wrap = document.createElement("span");
          wrap.className = "playc-card";
          var label = c.getAttribute("data-title") || c.getAttribute("aria-label") || (c.textContent || "").trim().slice(0, 24) || "Item";
          var pct = parseFloat(c.getAttribute("data-progress") || c.getAttribute("data-position") || "0") || 0;
          var name = document.createElement("span");
          name.textContent = label;
          var prog = document.createElement("progress");
          prog.max = 100;
          prog.value = Math.max(0, Math.min(100, pct));
          var go = btn("Resume", "Resume " + label, function () {
            try { c.click(); } catch (_) { /* no-op */ }
          });
          wrap.appendChild(name);
          wrap.appendChild(prog);
          wrap.appendChild(go);
          row.appendChild(wrap);
        });
      }
      bar.appendChild(row);
    } catch (_) { /* PLYC-001 no-op when absent */ }

    // PLYC-002 auto-skip credits detector (time-based)
    try {
      var skipOn = false;
      var skipBtn = btn("Skip credits: off", "Auto-skip last 30s when enabled", function () {
        skipOn = !skipOn;
        skipBtn.textContent = "Skip credits: " + (skipOn ? "on" : "off");
        skipBtn.setAttribute("aria-pressed", String(skipOn));
      });
      skipBtn.setAttribute("aria-pressed", "false");
      bar.appendChild(skipBtn);
      document.addEventListener("timeupdate", function () {
        if (!skipOn) return;
        var v = vid();
        if (!v || !isFinite(v.duration) || !v.duration) return;
        try {
          if (v.duration - v.currentTime <= 30 && v.duration > 40) v.currentTime = Math.max(0, v.duration - 1);
        } catch (_) { /* no-op */ }
      }, true);
    } catch (_) { /* PLYC-002 no-op */ }

    // PLYC-003 audio-boost toggle
    try {
      var boostOn = false;
      var boostBtn = btn("Boost: off", "Audio boost via gain", function () {
        var v = vid();
        if (!v) return;
        boostOn = !boostOn;
        try {
          if (boostOn) { v.dataset.plycVol = String(v.volume); v.volume = Math.min(1, (parseFloat(v.dataset.plycVol) || 0.8) * 1.5 > 1 ? 1 : (parseFloat(v.dataset.plycVol) || 0.8) * 1.5); }
          else if (v.dataset.plycVol) { v.volume = parseFloat(v.dataset.plycVol); }
        } catch (_) { /* no-op */ }
        boostBtn.textContent = "Boost: " + (boostOn ? "on" : "off");
        boostBtn.setAttribute("aria-pressed", String(boostOn));
      });
      boostBtn.setAttribute("aria-pressed", "false");
      bar.appendChild(boostBtn);
    } catch (_) { /* PLYC-003 no-op */ }

    // PLYC-004 brightness/gamma quick slider
    try {
      var slider = document.createElement("input");
      slider.type = "range";
      slider.min = "50";
      slider.max = "150";
      slider.value = "100";
      slider.title = "Brightness";
      slider.setAttribute("aria-label", "Brightness");
      slider.addEventListener("input", function () {
        var v = vid();
        if (!v) return;
        try { v.style.filter = "brightness(" + (parseInt(slider.value, 10) / 100) + ")"; } catch (_) { /* no-op */ }
      });
      bar.appendChild(slider);
    } catch (_) { /* PLYC-004 no-op */ }

    // PLYC-005 aspect-ratio cycler
    try {
      var modes = ["auto", "16/9", "4/3", "21/9", "fill"];
      var idx = 0;
      var arBtn = btn("Aspect: auto", "Cycle aspect ratio", function () {
        var v = vid();
        idx = (idx + 1) % modes.length;
        var m = modes[idx];
        arBtn.textContent = "Aspect: " + m;
        if (!v) return;
        try {
          if (m === "auto") { v.style.objectFit = ""; v.style.aspectRatio = ""; }
          else if (m === "fill") { v.style.objectFit = "fill"; v.style.aspectRatio = ""; }
          else { v.style.objectFit = "contain"; v.style.aspectRatio = m; }
        } catch (_) { /* no-op */ }
      });
      bar.appendChild(arBtn);
    } catch (_) { /* PLYC-005 no-op */ }

    // PLYC-006 frame-step buttons
    try {
      var backBtn = btn("−1f", "Step back one frame", function () {
        var v = vid();
        if (!v) return;
        try { v.pause(); v.currentTime = Math.max(0, v.currentTime - 1 / 30); } catch (_) { /* no-op */ }
      });
      var fwdBtn = btn("+1f", "Step forward one frame", function () {
        var v = vid();
        if (!v) return;
        try { v.pause(); v.currentTime = Math.min(v.duration || Infinity, v.currentTime + 1 / 30); } catch (_) { /* no-op */ }
      });
      bar.appendChild(backBtn);
      bar.appendChild(fwdBtn);
    } catch (_) { /* PLYC-006 no-op */ }

    // PLYC-007 loop-section A-B
    try {
      var a = null, b = null, looping = false;
      var loopBtn = btn("A-B: set A", "Loop section A-B", function () {
        var v = vid();
        if (!v) return;
        if (a === null) { a = v.currentTime; loopBtn.textContent = "A-B: set B"; }
        else if (b === null) { b = v.currentTime; if (b < a) { var t = a; a = b; b = t; } loopBtn.textContent = "A-B: loop on"; looping = true; }
        else { a = null; b = null; looping = false; loopBtn.textContent = "A-B: set A"; }
      });
      bar.appendChild(loopBtn);
      document.addEventListener("timeupdate", function () {
        if (!looping || a === null || b === null) return;
        var v = vid();
        if (!v) return;
        try { if (v.currentTime >= b || v.currentTime < a) v.currentTime = a; } catch (_) { /* no-op */ }
      }, true);
    } catch (_) { /* PLYC-007 no-op */ }

    // PLYC-008 playback speed presets row
    try {
      [0.75, 1, 1.25, 1.5, 2].forEach(function (rate) {
        var s = btn(rate + "x", "Set speed " + rate + "x", function () {
          var v = vid();
          if (!v) return;
          try { v.playbackRate = rate; } catch (_) { /* no-op */ }
        });
        bar.appendChild(s);
      });
    } catch (_) { /* PLYC-008 no-op */ }

    // PLYC-009 episode auto-next countdown custom 5/10/30s
    try {
      var sel = document.createElement("select");
      sel.setAttribute("aria-label", "Auto-next countdown");
      sel.title = "Auto-next countdown";
      ["5", "10", "30"].forEach(function (s, i) {
        var o = document.createElement("option");
        o.value = s;
        o.textContent = "Next: " + s + "s";
        if (i === 1) o.selected = true;
        sel.appendChild(o);
      });
      var timer = null, overlay = null;
      function clearNext() {
        if (timer) { clearInterval(timer); timer = null; }
        if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
        overlay = null;
      }
      sel.addEventListener("change", function () {
        clearNext();
        var v = vid();
        if (!v) return;
        var secs = parseInt(sel.value, 10) || 10;
        overlay = document.createElement("div");
        overlay.className = "playc-countdown";
        try { document.body.appendChild(overlay); } catch (_) { return; }
        timer = setInterval(function () {
          try {
            overlay.textContent = "Next episode in " + secs + "s (click to cancel)";
            if (secs <= 0) {
              clearNext();
              var nxt = document.querySelector("[data-next-episode],.next-episode,.playc-next");
              if (nxt) nxt.click();
            }
            secs -= 1;
          } catch (_) { clearNext(); }
        }, 1000);
        overlay.addEventListener("click", clearNext);
      });
      bar.appendChild(sel);
    } catch (_) { /* PLYC-009 no-op */ }

    // PLYC-010 theater-mode dim
    try {
      var dimOn = false, dimEl = null;
      var dimBtn = btn("Theater: off", "Dim surrounding page", function () {
        dimOn = !dimOn;
        try {
          if (dimOn) {
            dimEl = document.createElement("div");
            dimEl.className = "playc-theater-dim";
            document.body.appendChild(dimEl);
            var v = vid();
            if (v && v.style) v.style.position = "relative", v.style.zIndex = "9999";
          } else if (dimEl && dimEl.parentNode) {
            dimEl.parentNode.removeChild(dimEl);
            dimEl = null;
          }
        } catch (_) { /* no-op */ }
        dimBtn.textContent = "Theater: " + (dimOn ? "on" : "off");
        dimBtn.setAttribute("aria-pressed", String(dimOn));
      });
      dimBtn.setAttribute("aria-pressed", "false");
      bar.appendChild(dimBtn);
    } catch (_) { /* PLYC-010 no-op */ }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
})();
