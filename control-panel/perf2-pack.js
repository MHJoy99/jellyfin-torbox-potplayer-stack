(function () {
  try {
    var G = typeof globalThis !== "undefined" ? globalThis : Function("return this")();
    var W = (G && G.window) ? G.window : G;
    var D = (G && G.document) ? G.document : (typeof document !== "undefined" ? document : null);
    var P2 = W.__perf2 = W.__perf2 || {};

    function now() { return Date.now(); }
    function idle(fn, ms) {
      try {
        if (W.requestIdleCallback) { W.requestIdleCallback(fn, { timeout: ms || 2000 }); return; }
      } catch (e) {}
      setTimeout(fn, 0);
    }
    function esc(s) {
      return String(s == null ? "" : s)
        .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;").replaceAll("'", "&#039;");
    }

    // PRF2-001 List virtualization helper (render only visible rows for 10k+ lists, spacer math).
    // Client-side only: caller supplies items + row renderer; never touches /api contracts.
    function virtualize(cfg) {
      cfg = cfg || {};
      var container = cfg.container || null;
      var items = cfg.items || [];
      var rowH = cfg.rowHeight > 0 ? cfg.rowHeight : 48;
      var renderRow = cfg.renderRow || function (item) { return "<div>" + esc(item) + "</div>"; };
      var overscan = cfg.overscan == null ? 5 : cfg.overscan;
      if (!container) return { update: function () {}, destroy: function () {} };
      var top = D ? D.createElement("div") : null;
      var body = D ? D.createElement("div") : null;
      var bottom = D ? D.createElement("div") : null;
      try {
        container.innerHTML = "";
        if (top && body && bottom) { container.appendChild(top); container.appendChild(body); container.appendChild(bottom); }
      } catch (e) { return { update: function () {}, destroy: function () {} }; }
      var raf = 0;
      function paint() {
        raf = 0;
        try {
          var st = container.scrollTop || 0;
          var vh = container.clientHeight || 400;
          var start = Math.max(0, Math.floor(st / rowH) - overscan);
          var end = Math.min(items.length, Math.ceil((st + vh) / rowH) + overscan);
          var html = "";
          for (var i = start; i < end; i++) { html += renderRow(items[i], i); }
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
      try { container.addEventListener("scroll", onScroll, { passive: true }); } catch (e) {}
      paint();
      return {
        update: function (next) { items = next || []; paint(); },
        refresh: paint,
        destroy: function () { try { container.removeEventListener("scroll", onScroll); } catch (e) {} }
      };
    }
    P2.virtualize = virtualize;

    // PRF2-002 Lazy-load posters via IntersectionObserver (data-src swap).
    function lazyPosters(root, selector) {
      root = root || D;
      if (!root) return function () {};
      var sel = selector || "img[data-src]";
      var imgs = [];
      try { imgs = Array.prototype.slice.call(root.querySelectorAll(sel)); } catch (e) { return function () {}; }
      if (!imgs.length) return function () {};
      function swap(img) {
        try {
          var src = img.getAttribute("data-src");
          if (!src || img.getAttribute("src") === src) return;
          img.setAttribute("src", src);
          img.removeAttribute("data-src");
          img.setAttribute("data-lazy", "done");
        } catch (e) {}
      }
      if (!("IntersectionObserver" in W)) { imgs.forEach(swap); return function () {}; }
      var io = null;
      try {
        io = new W.IntersectionObserver(function (entries) {
          for (var i = 0; i < entries.length; i++) {
            if (entries[i].isIntersecting) { swap(entries[i].target); try { io.unobserve(entries[i].target); } catch (e) {} }
          }
        }, { rootMargin: "200px 0px" });
        imgs.forEach(function (img) { try { io.observe(img); } catch (e) { swap(img); } });
      } catch (e) { imgs.forEach(swap); }
      return function () { try { if (io) io.disconnect(); } catch (e) {} };
    }
    P2.lazyPosters = lazyPosters;

    // PRF2-003 Thumbnail memory+disk cache (Map + CacheStorage/WebP prefer).
    var _thumbMem = new Map();
    var _THUMB_MAX = 200;
    var _webpOK = null;
    function webpPreferred() {
      if (_webpOK !== null) return _webpOK;
      try {
        var c = D ? D.createElement("canvas") : null;
        _webpOK = !!(c && c.toDataURL && c.toDataURL("image/webp").indexOf("image/webp") === 5);
      } catch (e) { _webpOK = false; }
      return _webpOK;
    }
    function thumbUrl(raw) {
      // Prefer WebP variant when the browser can decode it; server-owned bytes unchanged.
      if (!raw || typeof raw !== "string") return raw;
      if (!webpPreferred()) return raw;
      if (/[?&](format=|type=)/i.test(raw)) return raw;
      return raw + (raw.indexOf("?") === -1 ? "?" : "&") + "format=webp";
    }
    function thumbGet(key) {
      if (_thumbMem.has(key)) { var v = _thumbMem.get(key); _thumbMem.delete(key); _thumbMem.set(key, v); return Promise.resolve(v); }
      try {
        if (W.caches && W.caches.open) {
          return W.caches.open("perf2-thumbs-v1").then(function (c) {
            return c.match(key).then(function (res) {
              if (!res) return undefined;
              return res.blob().then(function (b) {
                var url = URL.createObjectURL(b);
                _thumbMem.set(key, url);
                if (_thumbMem.size > _THUMB_MAX) _thumbMem.delete(_thumbMem.keys().next().value);
                return url;
              });
            }, function () { return undefined; });
          }, function () { return undefined; });
        }
      } catch (e) {}
      return Promise.resolve(undefined);
    }
    function thumbPut(key, blob) {
      try {
        if (blob && W.caches && W.caches.open) {
          W.caches.open("perf2-thumbs-v1").then(function (c) {
            try { c.put(key, new Response(blob)); } catch (e) {}
          }, function () {});
        }
      } catch (e) {}
    }
    P2.thumbCache = { get: thumbGet, put: thumbPut, url: thumbUrl, mem: _thumbMem };

    // PRF2-004 Prefetch detail JSON on card hover (idle, deduped).
    var _prefetched = new Set();
    function prefetchDetail(url) {
      if (!url || _prefetched.has(url)) return Promise.resolve(null);
      _prefetched.add(url);
      return new Promise(function (resolve) {
        idle(function () {
          try {
            fetch(url, { credentials: "same-origin" }).then(function (r) {
              if (!r.ok) { _prefetched.delete(url); resolve(null); return; }
              r.json().then(resolve, function () { _prefetched.delete(url); resolve(null); });
            }, function () { _prefetched.delete(url); resolve(null); });
          } catch (e) { _prefetched.delete(url); resolve(null); }
        });
      });
    }
    function prefetchOnHover(root, selector, hrefOf) {
      root = root || D;
      if (!root || !root.addEventListener) return function () {};
      var sel = selector || "[data-detail]";
      function onOver(ev) {
        try {
          var t = ev.target && ev.target.closest ? ev.target.closest(sel) : null;
          if (!t) return;
          var url = typeof hrefOf === "function" ? hrefOf(t) : t.getAttribute("data-detail");
          if (url) prefetchDetail(url);
        } catch (e) {}
      }
      try { root.addEventListener("mouseover", onOver, { passive: true }); } catch (e) {}
      return function () { try { root.removeEventListener("mouseover", onOver); } catch (e) {} };
    }
    P2.prefetchDetail = prefetchDetail;
    P2.prefetchOnHover = prefetchOnHover;

    // PRF2-005 Debounced search input (150ms) with in-flight abort.
    function debouncedSearch(input, onQuery, waitMs) {
      if (!input || typeof onQuery !== "function") return function () {};
      var wait = waitMs == null ? 150 : waitMs;
      var timer = 0;
      var ctrl = null;
      function fire() {
        timer = 0;
        try { if (ctrl) ctrl.abort(); } catch (e) {}
        try { ctrl = W.AbortController ? new W.AbortController() : null; } catch (e) { ctrl = null; }
        var q = "";
        try { q = input.value; } catch (e) {}
        try { onQuery(q, ctrl ? ctrl.signal : undefined); } catch (e) {}
      }
      function onInput() {
        if (timer) { try { clearTimeout(timer); } catch (e) {} }
        timer = setTimeout(fire, wait);
      }
      try { input.addEventListener("input", onInput); } catch (e) {}
      return function () {
        if (timer) { try { clearTimeout(timer); } catch (e) {} timer = 0; }
        try { if (ctrl) ctrl.abort(); } catch (e) {}
        try { input.removeEventListener("input", onInput); } catch (e) {}
      };
    }
    P2.debouncedSearch = debouncedSearch;

    // PRF2-006 LocalStorage cache for library views (keyed + TTL).
    var LS_PREFIX = "perf2.views.";
    var LS_TTL_MS = 5 * 60 * 1000;
    function lsKey(key) { return LS_PREFIX + String(key || "default"); }
    function viewsGet(key) {
      try {
        var raw = W.localStorage ? W.localStorage.getItem(lsKey(key)) : null;
        if (!raw) return undefined;
        var o = JSON.parse(raw);
        if (!o || (now() - (o.t || 0)) > (o.ttl || LS_TTL_MS)) {
          try { W.localStorage.removeItem(lsKey(key)); } catch (e) {}
          return undefined;
        }
        return o.v;
      } catch (e) { return undefined; }
    }
    function viewsSet(key, value, ttlMs) {
      try {
        if (!W.localStorage) return;
        W.localStorage.setItem(lsKey(key), JSON.stringify({ v: value, t: now(), ttl: ttlMs || LS_TTL_MS }));
      } catch (e) {}
    }
    function viewsDel(key) { try { if (W.localStorage) W.localStorage.removeItem(lsKey(key)); } catch (e) {} }
    P2.viewCache = { get: viewsGet, set: viewsSet, del: viewsDel };

    // PRF2-007 Stale-while-revalidate refresh for cached views (show stale, update in bg).
    // Shows LocalStorage snapshot instantly, revalidates in background, then calls onUpdate.
    function viewsSWR(key, fetcher, onUpdate, ttlMs) {
      var stale = viewsGet(key);
      var fresh = null;
      try {
        fresh = Promise.resolve().then(fetcher).then(function (v) {
          viewsSet(key, v, ttlMs);
          try { if (onUpdate) onUpdate(v, stale !== undefined); } catch (e) {}
          return v;
        }, function (e) {
          if (stale !== undefined) { try { if (onUpdate) onUpdate(stale, true); } catch (x) {} return stale; }
          throw e;
        });
      } catch (e) { fresh = Promise.reject(e); }
      return { stale: stale, fresh: fresh };
    }
    P2.viewsSWR = viewsSWR;

    // PRF2-008 Request singleflight (coalesce identical in-flight GETs).
    var _flight = new Map();
    function singleflight(key, worker) {
      if (_flight.has(key)) return _flight.get(key);
      var p = null;
      try { p = Promise.resolve().then(worker); }
      catch (e) { return Promise.reject(e); }
      _flight.set(key, p);
      function done() { _flight.delete(key); }
      try { p.then(done, done); } catch (e) {}
      return p;
    }
    function getSingleflight(url, opts) {
      return singleflight("GET " + url, function () {
        return fetch(url, opts || { credentials: "same-origin" }).then(function (r) {
          if (!r.ok) throw new Error("http " + r.status);
          return r.json();
        });
      });
    }
    P2.singleflight = singleflight;
    P2.getSingleflight = getSingleflight;

    // PRF2-009 Client ETag/If-None-Match cache layer honoring server validators.
    // Never alters /api contracts: only sends validators the server already issued.
    var _etag = new Map();
    function etagGet(url, opts) {
      var hit = _etag.get(url);
      var headers = {};
      try {
        var src = (opts && opts.headers) || {};
        for (var k in src) headers[k] = src[k];
      } catch (e) {}
      if (hit && hit.etag && !headers["If-None-Match"]) headers["If-None-Match"] = hit.etag;
      var o = {};
      try { for (var j in (opts || {})) o[j] = opts[j]; } catch (e) {}
      o.headers = headers;
      o.credentials = o.credentials || "same-origin";
      return fetch(url, o).then(function (r) {
        if (r.status === 304 && hit) return hit.body;
        return r.clone().json().then(function (body) {
          try {
            var tag = r.headers ? r.headers.get("ETag") : null;
            if (tag) {
              _etag.set(url, { etag: tag, body: body });
              if (_etag.size > 300) _etag.delete(_etag.keys().next().value);
            }
          } catch (e) {}
          return body;
        }, function () { return r.text(); });
      });
    }
    P2.etagGet = etagGet;

    // PRF2-010 Preload hints injector (preconnect/dns-prefetch for API hosts).
    var _hintsDone = new Set();
    function preloadHints(hosts) {
      if (!D || !D.head) return 0;
      var list = hosts || [];
      if (!list.length) {
        try {
          var h = W.location ? W.location.origin : null;
          list = h ? [h] : [];
        } catch (e) { list = []; }
      }
      var added = 0;
      list.forEach(function (origin) {
        if (!origin || _hintsDone.has(origin)) return;
        _hintsDone.add(origin);
        try {
          var pre = D.createElement("link");
          pre.rel = "preconnect";
          pre.href = origin;
          pre.crossOrigin = "anonymous";
          D.head.appendChild(pre);
          var dns = D.createElement("link");
          dns.rel = "dns-prefetch";
          dns.href = origin;
          D.head.appendChild(dns);
          added += 2;
        } catch (e) {}
      });
      return added;
    }
    P2.preloadHints = preloadHints;
  } catch (e) { /* perf2-pack disabled */ }
})();
