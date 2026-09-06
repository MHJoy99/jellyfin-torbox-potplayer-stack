(function () {
"use strict";
try {
var G = typeof globalThis !== "undefined" ? globalThis : Function("return this")();
var W = (G && G.window) ? G.window : G;
var D = (G && G.document) ? G.document : (typeof document !== "undefined" ? document : null);
if (W.__prf3Loaded) return;
W.__prf3Loaded = true;
var P3 = W.__prf3 = W.__perf3 = W.__perf3 || {};

/* Shared tiny helpers (no deps, stdlib only). */
function nowMs() { return Date.now(); }
function onIdle(fn, timeout) {
  try {
    if (W.requestIdleCallback) { W.requestIdleCallback(fn, { timeout: timeout || 2000 }); return; }
  } catch (e) {}
  setTimeout(fn, 0);
}
function debounceLocal(fn, wait) {
  var t = 0;
  wait = wait == null ? 200 : wait;
  return function () {
    var self = this, args = arguments;
    if (t) { try { clearTimeout(t); } catch (e) {} }
    t = setTimeout(function () { t = 0; fn.apply(self, args); }, wait);
  };
}

// PRF3-001 request coalescing cache by URL (dedupe in-flight fetch by method+URL; additive fetch wrapper).
(function () {
  var inflight = new Map();
  function keyOf(url, opts) {
    var m = "GET";
    try { if (opts && opts.method) m = String(opts.method).toUpperCase(); } catch (e) {}
    return m + " " + String(url);
  }
  function coalescedFetch(url, opts) {
    var k = keyOf(url, opts);
    if (inflight.has(k)) return inflight.get(k);
    var p = null;
    try { p = Promise.resolve().then(function () { return fetch(url, opts); }); }
    catch (e) { return Promise.reject(e); }
    inflight.set(k, p);
    var done = function () { inflight.delete(k); };
    p.then(done, done);
    return p;
  }
  P3.coalescedFetch = coalescedFetch;
  P3._inflight = inflight;
})();

// PRF3-002 background revalidate SWR for /api/status (serve stale cache, refresh in background).
(function () {
  var cache = { body: null, at: 0, pending: false };
  var TTL = 15000;
  function readStatus(opts) {
    opts = opts || {};
    var url = opts.url || "/api/status";
    var stale = (cache.body !== null && (nowMs() - cache.at) < (opts.ttl || TTL)) ? cache.body : null;
    function revalidate() {
      if (cache.pending) return cache.pending;
      var fetcher = P3.coalescedFetch || function (u, o) { return fetch(u, o); };
      cache.pending = Promise.resolve().then(function () { return fetcher(url, { method: "GET" }); })
        .then(function (r) { if (!r.ok) throw new Error("http " + r.status); return r.json(); })
        .then(function (j) { cache.body = j; cache.at = nowMs(); cache.pending = false; return j; },
          function (e) { cache.pending = false; throw e; });
      return cache.pending;
    }
    if (stale !== null) { try { revalidate().catch(function () {}); } catch (e) {} return Promise.resolve(stale); }
    return revalidate();
  }
  P3.swrStatus = readStatus;
  P3._swrCache = cache;
})();

// PRF3-003 image lazy with blur-up (IntersectionObserver swaps data-src, CSS blur until loaded).
(function () {
  var SEL = "img[data-prf3-src], img[data-src]";
  function arm(root) {
    if (!D) return;
    var scope = root || D;
    var imgs = null;
    try { imgs = scope.querySelectorAll(SEL); } catch (e) { return; }
    if (!imgs || !imgs.length) return;
    function loadOne(img) {
      try {
        var src = img.getAttribute("data-prf3-src") || img.getAttribute("data-src");
        if (!src) return;
        if (img.classList) img.classList.add("prf3-blur");
        var done = function () { try { if (img.classList) img.classList.remove("prf3-blur"); } catch (e) {} };
        img.addEventListener("load", done, { once: true });
        img.setAttribute("src", src);
        img.removeAttribute("data-prf3-src"); img.removeAttribute("data-src");
      } catch (e) {}
    }
    var started = false;
    try {
      if ("IntersectionObserver" in W) {
        var io = new W.IntersectionObserver(function (entries) {
          for (var i = 0; i < entries.length; i++) {
            if (entries[i].isIntersecting) { loadOne(entries[i].target); try { io.unobserve(entries[i].target); } catch (e) {} }
          }
        }, { rootMargin: "200px" });
        for (var j = 0; j < imgs.length; j++) { try { io.observe(imgs[j]); } catch (e) { loadOne(imgs[j]); } }
        P3._lazyIO = io;
        started = true;
      }
    } catch (e) { started = false; }
    if (!started) { for (var k = 0; k < imgs.length; k++) loadOne(imgs[k]); }
  }
  function boot() {
    if (!D) return;
    try {
      if (!D.getElementById("prf3-blur-style")) {
        var st = D.createElement("style");
        st.id = "prf3-blur-style";
        st.textContent = "img.prf3-blur{filter:blur(8px);transition:filter .3s ease;}";
        (D.head || D.documentElement).appendChild(st);
      }
    } catch (e) {}
    arm(D);
    try {
      if ("MutationObserver" in W && D.body) {
        var mo = new W.MutationObserver(debounceLocal(function () { arm(D); }, 300));
        mo.observe(D.body, { childList: true, subtree: true });
        P3._lazyMO = mo;
      }
    } catch (e) {}
  }
  P3.lazyImages = arm;
  onIdle(boot, 2500);
})();

// PRF3-004 list windowing for activity-log (render visible slice on scroll, spacer math).
(function () {
  function windowList(cfg) {
    cfg = cfg || {};
    var container = cfg.container || null;
    if (!container && D) {
      try { container = D.querySelector("#activity-log, [data-activity-log], .activity-log"); } catch (e) {}
    }
    var items = cfg.items || null;
    var rowH = cfg.rowHeight > 0 ? cfg.rowHeight : 44;
    var overscan = cfg.overscan == null ? 6 : cfg.overscan;
    var renderRow = cfg.renderRow || function (el) {
      try { return el.outerHTML || ""; } catch (e) { return ""; }
    };
    if (!container) return { update: function () {}, destroy: function () {} };
    if (!items) {
      try { items = Array.prototype.slice.call(container.children); } catch (e) { items = []; }
    }
    if (!items.length) return { update: function () {}, destroy: function () {} };
    var top = null, body = null, bottom = null, dead = false, raf = 0;
    try {
      top = D.createElement("div"); body = D.createElement("div"); bottom = D.createElement("div");
      container.innerHTML = "";
      container.appendChild(top); container.appendChild(body); container.appendChild(bottom);
    } catch (e) { return { update: function () {}, destroy: function () {} }; }
    function paint() {
      raf = 0;
      if (dead) return;
      try {
        var st = container.scrollTop || 0;
        var vh = container.clientHeight || 400;
        var start = Math.max(0, Math.floor(st / rowH) - overscan);
        var end = Math.min(items.length, Math.ceil((st + vh) / rowH) + overscan);
        var html = "";
        for (var i = start; i < end; i++) html += renderRow(items[i], i);
        body.innerHTML = html;
        top.style.height = (start * rowH) + "px";
        bottom.style.height = ((items.length - end) * rowH) + "px";
      } catch (e) {}
    }
    function onScroll() {
      if (raf) return;
      var r = W.requestAnimationFrame || function (f) { return setTimeout(f, 16); };
      raf = r(paint);
    }
    try { container.addEventListener("scroll", onScroll, { passive: true }); } catch (e) {
      try { container.addEventListener("scroll", onScroll); } catch (e2) {}
    }
    paint();
    return {
      update: function (next) { if (next) items = next; paint(); },
      destroy: function () {
        dead = true;
        try { container.removeEventListener("scroll", onScroll); } catch (e) {}
      }
    };
  }
  P3.windowActivityLog = windowList;
})();

// PRF3-005 idle-boot defer non-critical (queue non-critical init until browser is idle).
(function () {
  var queue = [];
  var scheduled = false;
  function flush(deadline) {
    scheduled = false;
    var budget = 40;
    try {
      if (deadline && typeof deadline.timeRemaining === "function") {
        while (queue.length && deadline.timeRemaining() > 0) (queue.shift())();
        if (queue.length) schedule();
        return;
      }
    } catch (e) {}
    var t0 = nowMs();
    while (queue.length && (nowMs() - t0) < budget) {
      var fn = queue.shift();
      try { fn(); } catch (e) {}
    }
    if (queue.length) schedule();
  }
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    onIdle(function () { flush(null); }, 2000);
  }
  function deferIdle(fn) {
    if (typeof fn !== "function") return;
    queue.push(fn);
    schedule();
  }
  P3.deferIdle = deferIdle;
})();

// PRF3-006 memory cap for logs (trim log containers to newest 500 rows).
(function () {
  var MAX = 500;
  var SEL = "#activity-log, [data-activity-log], .activity-log, #log-list, [data-log-list]";
  function trimOne(el, max) {
    try {
      var limit = max > 0 ? max : MAX;
      while (el.children.length > limit) {
        try { el.removeChild(el.firstChild); } catch (e) { break; }
      }
    } catch (e) {}
  }
  function trimAll(root, max) {
    if (!D) return 0;
    var scope = root || D;
    var n = 0;
    try {
      var list = scope.querySelectorAll(SEL);
      for (var i = 0; i < list.length; i++) {
        var before = list[i].children.length;
        trimOne(list[i], max);
        if (list[i].children.length < before) n++;
      }
    } catch (e) {}
    return n;
  }
  function boot() {
    if (!D) return;
    trimAll(D, MAX);
    try {
      if ("MutationObserver" in W && D.body) {
        var onMut = debounceLocal(function () { trimAll(D, MAX); }, 400);
        var mo = new W.MutationObserver(onMut);
        mo.observe(D.body, { childList: true, subtree: true });
        P3._logCapMO = mo;
      } else {
        setInterval(function () { trimAll(D, MAX); }, 10000);
      }
    } catch (e) {}
  }
  P3.capLogs = trimAll;
  P3.LOG_MAX = MAX;
  onIdle(boot, 2000);
})();

// PRF3-007 CSS containment for cards (content-visibility + contain, additive stylesheet only).
(function () {
  function boot() {
    if (!D) return;
    try {
      if (D.getElementById("prf3-contain-style")) return;
      var st = D.createElement("style");
      st.id = "prf3-contain-style";
      st.textContent = [
        ".card,[data-card],.panel-card,.media-card{content-visibility:auto;contain-intrinsic-size:auto 220px;contain:layout style;}",
        ".log-row,.activity-row{contain:layout style;}"
      ].join("\n");
      (D.head || D.documentElement).appendChild(st);
    } catch (e) {}
  }
  P3.containCards = boot;
  onIdle(boot, 2000);
})();

// PRF3-008 preconnect to jellyfin/proxy origins (link preconnect + dns-prefetch, no fetch issued).
(function () {
  function origins() {
    var out = [];
    function push(u) {
      try {
        var a = D.createElement("a");
        a.href = u;
        var o = a.protocol + "//" + a.host;
        if (o && out.indexOf(o) < 0 && /^https?:\/\//.test(o)) out.push(o);
      } catch (e) {}
    }
    try {
      if (D && D.querySelectorAll) {
        var els = D.querySelectorAll("a[href], img[src], script[src]");
        for (var i = 0; i < Math.min(els.length, 50); i++) {
          var u = els[i].getAttribute("href") || els[i].getAttribute("src") || "";
          if (/^https?:\/\//.test(u)) push(u);
        }
      }
    } catch (e) {}
    try {
      if (W.location && /^https?:/.test(W.location.href)) push(W.location.href);
    } catch (e) {}
    return out.slice(0, 6);
  }
  function boot(list) {
    if (!D) return;
    try {
      var head = D.head || D.getElementsByTagName("head")[0];
      if (!head) return;
      var items = (list && list.length) ? list : origins();
      for (var i = 0; i < items.length; i++) {
        try {
          if (head.querySelector('link[data-prf3="preconnect"][href="' + items[i] + '"]')) continue;
          var l1 = D.createElement("link");
          l1.setAttribute("rel", "preconnect");
          l1.setAttribute("href", items[i]);
          l1.setAttribute("crossorigin", "");
          l1.setAttribute("data-prf3", "preconnect");
          head.appendChild(l1);
          var l2 = D.createElement("link");
          l2.setAttribute("rel", "dns-prefetch");
          l2.setAttribute("href", items[i]);
          l2.setAttribute("data-prf3", "preconnect");
          head.appendChild(l2);
        } catch (e) {}
      }
    } catch (e) {}
  }
  P3.preconnect = boot;
  onIdle(function () { boot(); }, 2500);
})();

// PRF3-009 debounce refresh button (collapse rapid clicks into one handler run).
(function () {
  function arm(root, wait) {
    if (!D) return 0;
    var scope = root || D;
    var n = 0;
    try {
      var btns = scope.querySelectorAll("[data-refresh], #refresh, #refresh-btn, .refresh-btn");
      for (var i = 0; i < btns.length; i++) {
        (function (btn) {
          try {
            if (btn.__prf3Debounced) return;
            btn.__prf3Debounced = true;
            var orig = btn.onclick;
            var run = debounceLocal(function (ev) {
              try {
                if (typeof orig === "function") orig.call(btn, ev);
                else if (btn.dataset && btn.dataset.refreshFn && W[btn.dataset.refreshFn]) W[btn.dataset.refreshFn]();
                else btn.dispatchEvent(new Event("prf3:refresh"));
              } catch (e) {}
            }, wait == null ? 400 : wait);
            btn.addEventListener("click", function (ev) {
              try {
                ev.stopImmediatePropagation();
                ev.preventDefault();
              } catch (e) {}
              run(ev);
            }, true);
            n++;
          } catch (e) {}
        })(btns[i]);
      }
    } catch (e) {}
    return n;
  }
  function boot() { arm(D, 400); }
  P3.debounceRefresh = arm;
  onIdle(boot, 2000);
})();

// PRF3-010 service-worker-less offline fallback banner (online/offline listeners, DOM banner only).
(function () {
  var bannerId = "prf3-offline-banner";
  function banner(show) {
    if (!D) return;
    try {
      var el = D.getElementById(bannerId);
      if (show) {
        if (!el) {
          el = D.createElement("div");
          el.id = bannerId;
          el.setAttribute("role", "status");
          el.textContent = "You appear to be offline — showing last known data. Reconnect to refresh.";
          try {
            el.style.cssText = "position:fixed;left:12px;right:12px;bottom:12px;z-index:9999;" +
              "padding:10px 14px;border-radius:8px;background:#3a2b00;color:#ffe9a8;" +
              "border:1px solid #a07d00;font:13px/1.4 system-ui,sans-serif;text-align:center;";
          } catch (e) {}
          (D.body || D.documentElement).appendChild(el);
        }
        el.style.display = "";
      } else if (el) {
        el.style.display = "none";
      }
    } catch (e) {}
  }
  function boot() {
    try {
      banner(!W.navigator || W.navigator.onLine === false);
      W.addEventListener("online", function () { banner(false); });
      W.addEventListener("offline", function () { banner(true); });
    } catch (e) {}
  }
  P3.offlineBanner = banner;
  if (D && D.readyState === "loading") {
    try { D.addEventListener("DOMContentLoaded", boot); } catch (e) { onIdle(boot, 1500); }
  } else {
    onIdle(boot, 1500);
  }
})();

} catch (e) {}
})();
