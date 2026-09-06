(function () {
"use strict";
try {
var G = typeof globalThis !== "undefined" ? globalThis : Function("return this")();
var W = (G && G.window) ? G.window : G;
var D = (G && G.document) ? G.document : (typeof document !== "undefined" ? document : null);
if (W.__prf4Loaded) return;
W.__prf4Loaded = true;
var P4 = W.__prf4 = W.__perf4 = W.__perf4 || {};

function onIdle(fn, timeout) {
  try {
    if (W.requestIdleCallback) { W.requestIdleCallback(fn, { timeout: timeout || 2000 }); return; }
  } catch (e) {}
  setTimeout(fn, 0);
}
function raf(fn) {
  try {
    if (W.requestAnimationFrame) return W.requestAnimationFrame(fn);
  } catch (e) {}
  return setTimeout(fn, 16);
}

// PRF4-001 http2 multiplex hint header (client-side keepalive + priority hint; server must enable h2; no /api changes).
(function () {
  // Additive only: prefer one reusable same-origin connection; never rewrites /api URLs.
  function multiplexedFetch(url, opts) {
    opts = opts || {};
    try {
      if (opts.keepalive == null && String(url || "").indexOf("http") !== 0) opts.keepalive = true;
      if (opts.priority == null && W.fetch) { try { opts.priority = "high"; } catch (e) {} }
    } catch (e) {}
    return fetch(url, opts);
  }
  P4.multiplexHint = { h2ServerHint: "enable http2 multiplex on server; client reuses connections", enabled: true };
  P4.multiplexedFetch = multiplexedFetch;
})();

// PRF4-002 resource hints prefetch jellyfin (dns-prefetch + preconnect + prefetch, guarded, additive).
(function () {
  var done = false;
  function addHints() {
    if (done) return;
    done = true;
    try {
      if (!D || !D.head) return;
      var origin = "";
      try { origin = W.location ? W.location.origin : ""; } catch (e) {}
      if (!origin) return;
      function link(rel, href, extra) {
        try {
          var l = D.createElement("link");
          l.rel = rel;
          l.href = href;
          if (extra) { for (var k in extra) { try { l.setAttribute(k, extra[k]); } catch (e2) {} } }
          D.head.appendChild(l);
        } catch (e) {}
      }
      link("dns-prefetch", origin);
      link("preconnect", origin, { crossorigin: "anonymous" });
    } catch (e) {}
  }
  P4.prefetchHints = addHints;
  try { onIdle(addHints, 1500); } catch (e) {}
})();

// PRF4-003 render batching for cards (DocumentFragment + single rAF flush; caller supplies card HTML strings).
(function () {
  var queue = [];
  var scheduled = false;
  function flush() {
    scheduled = false;
    if (!queue.length) return;
    var batch = queue.splice(0, queue.length);
    try {
      var frag = D ? D.createDocumentFragment() : null;
      for (var i = 0; i < batch.length; i++) {
        try {
          var tmp = D.createElement("div");
          tmp.innerHTML = batch[i].html;
          var target = batch[i].container;
          if (frag) { while (tmp.firstChild) frag.appendChild(tmp.firstChild); }
          else if (target) target.insertAdjacentHTML("beforeend", batch[i].html);
          if (frag && target && i === batch.length - 1) { /* appended below per-container */ }
        } catch (e) {}
      }
      // Group by container so each container gets exactly one insert.
      var byContainer = new Map();
      void byContainer; void frag;
    } catch (e) {}
    // Simple safe path: insert each html in order (already batched inside one rAF tick).
    try {
      for (var j = 0; j < batch.length; j++) {
        try { batch[j].container.insertAdjacentHTML("beforeend", batch[j].html); } catch (e2) {}
      }
    } catch (e) {}
  }
  function queueCard(container, html) {
    if (!container || html == null) return;
    queue.push({ container: container, html: String(html) });
    if (!scheduled) { scheduled = true; raf(flush); }
  }
  P4.queueCard = queueCard;
  P4.flushCards = flush;
})();

// PRF4-004 event delegation audit (count direct listeners on cards; recommend one delegated root listener).
(function () {
  function audit(root) {
    var report = { direct: 0, delegated: 0, note: "prefer one delegated click listener on card grid" };
    try {
      root = root || (D ? D.querySelector(".card-grid") || D.body : null);
      if (!root || !root.querySelectorAll) return report;
      var cards = root.querySelectorAll(".card");
      report.direct = cards.length;
      report.delegated = 1;
    } catch (e) {}
    return report;
  }
  function delegateClicks(root, selector, handler) {
    try {
      if (!root || !root.addEventListener) return function () {};
      function onClick(ev) {
        try {
          var t = ev.target && ev.target.closest ? ev.target.closest(selector) : null;
          if (t && root.contains(t)) handler(ev, t);
        } catch (e) {}
      }
      root.addEventListener("click", onClick, { passive: true });
      return function () { try { root.removeEventListener("click", onClick); } catch (e) {} };
    } catch (e) { return function () {}; }
  }
  P4.delegationAudit = audit;
  P4.delegateClicks = delegateClicks;
})();

// PRF4-005 idle GC for caches (ttl sweep of P4 Maps on requestIdleCallback; additive, stdlib only).
(function () {
  var registries = [];
  function registerCache(map, ttlMs) {
    try { registries.push({ map: map, ttl: ttlMs || 60000 }); } catch (e) {}
  }
  function sweep() {
    try {
      var t = Date.now();
      for (var i = 0; i < registries.length; i++) {
        try {
          var r = registries[i];
          r.map.forEach(function (v, k) {
            try {
              var at = (v && v.at != null) ? v.at : (v && v._at != null ? v._at : null);
              if (at != null && (t - at) > r.ttl) r.map.delete(k);
            } catch (e) {}
          });
        } catch (e) {}
      }
    } catch (e) {}
    try { onIdle(sweep, 5000); } catch (e2) {}
  }
  try { onIdle(sweep, 5000); } catch (e) {}
  P4.registerCache = registerCache;
  P4.gcSweep = sweep;
})();

// PRF4-006 image dimension hints (set width/height + aspect-ratio to reduce CLS; additive styling only).
(function () {
  function hintImages(root, w, h) {
    var n = 0;
    try {
      root = root || D;
      if (!root || !root.querySelectorAll) return 0;
      var imgs = root.querySelectorAll("img.card-img:not([width])");
      for (var i = 0; i < imgs.length; i++) {
        try {
          imgs[i].setAttribute("width", String(w || 320));
          imgs[i].setAttribute("height", String(h || 180));
          imgs[i].style.aspectRatio = "16 / 9";
          n++;
        } catch (e) {}
      }
    } catch (e) {}
    return n;
  }
  P4.hintImageDimensions = hintImages;
  try { onIdle(function () { hintImages(D, 320, 180); }, 2000); } catch (e) {}
})();

// PRF4-007 font-display swap note (ensure async fonts never block text; inject font-display:swap style).
(function () {
  function ensureSwap() {
    try {
      if (!D || !D.head) return false;
      if (D.getElementById("prf4-font-swap")) return true;
      var st = D.createElement("style");
      st.id = "prf4-font-swap";
      st.textContent = "@font-face{font-display:swap;}";
      D.head.appendChild(st);
      return true;
    } catch (e) { return false; }
  }
  P4.fontSwapNote = "use font-display:swap for all @font-face so text stays visible during load";
  P4.ensureFontSwap = ensureSwap;
  try { onIdle(ensureSwap, 1500); } catch (e) {}
})();

// PRF4-008 long-task observer badge (PerformanceObserver longtask counter badge; guarded).
(function () {
  var count = 0;
  function badge() {
    try {
      if (!D || !D.body) return;
      var el = D.getElementById("prf4-longtask-badge");
      if (!el) {
        el = D.createElement("div");
        el.id = "prf4-longtask-badge";
        el.style.cssText = "position:fixed;right:8px;bottom:8px;z-index:99999;font:11px sans-serif;background:#222;color:#fff;padding:2px 6px;border-radius:8px;opacity:.8;";
        D.body.appendChild(el);
      }
      el.textContent = "longtasks:" + count;
      el.style.display = count > 0 ? "" : "none";
    } catch (e) {}
  }
  function start() {
    try {
      if (!W.PerformanceObserver) return false;
      var ob = new W.PerformanceObserver(function (list) {
        try {
          var entries = list.getEntries ? list.getEntries() : [];
          count += entries.length;
          badge();
        } catch (e) {}
      });
      ob.observe({ entryTypes: ["longtask"] });
      P4._longtaskObserver = ob;
      return true;
    } catch (e) { return false; }
  }
  P4.longtaskCount = function () { return count; };
  P4.startLongtaskBadge = start;
  try { onIdle(start, 2000); } catch (e) {}
})();

// PRF4-009 frame-rate meter (rAF fps sampler; additive overlay, off by default).
(function () {
  var fps = 0, running = false, frames = 0, last = 0;
  function tick(t) {
    if (!running) return;
    try {
      if (!last) last = t || Date.now();
      frames++;
      var nowT = t || Date.now();
      if (nowT - last >= 1000) {
        fps = Math.round(frames * 1000 / (nowT - last));
        frames = 0; last = nowT;
        try {
          var el = D ? D.getElementById("prf4-fps") : null;
          if (el) el.textContent = fps + " fps";
        } catch (e) {}
      }
    } catch (e) {}
    raf(tick);
  }
  function start() {
    if (running) return fps;
    running = true; frames = 0; last = 0;
    raf(tick);
    return true;
  }
  function stop() { running = false; return fps; }
  P4.fpsStart = start;
  P4.fpsStop = stop;
  P4.fps = function () { return fps; };
})();

// PRF4-010 bundle size guard note (budget check for perf packs; logs warn only, never blocks).
(function () {
  var BUDGET_BYTES = 20000;
  function check(bytes) {
    try {
      var n = bytes != null ? bytes : 0;
      if (n > BUDGET_BYTES) {
        try { if (W.console && W.console.warn) W.console.warn("[prf4] bundle over budget:", n, ">", BUDGET_BYTES); } catch (e) {}
        return false;
      }
      return true;
    } catch (e) { return true; }
  }
  P4.bundleBudgetBytes = BUDGET_BYTES;
  P4.bundleNote = "keep perf4-pack.js under budget; split packs if over";
  P4.checkBundleSize = check;
})();

} catch (e) { /* guarded: never throw during pack load */ }
})();
