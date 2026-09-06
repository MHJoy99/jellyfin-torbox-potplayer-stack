(function () {
  "use strict";
  try {
    var G = typeof globalThis !== "undefined" ? globalThis : Function("return this")();
    var W = (G && G.window) ? G.window : G;
    if (W.__spd5Loaded) { return; }
    W.__spd5Loaded = true;
    var D = (G && G.document) ? G.document : (typeof document !== "undefined" ? document : null);
    var S5 = W.__spd5 = W.__spd5 || {};

    var HEALTH_URL = "/api/health";
    var LIGHT_HEALTH_URL = "/api/health?light=1";
    var STATUS_URL = "/api/status";
    var ACTIVITY_URL = "/api/activity";
    var TIMELINE_URL = "/api/timeline";

    function safeFetch(url, opts) {
      if (typeof fetch !== "function") { return Promise.reject(new Error("fetch unavailable")); }
      return fetch(url, opts || { method: "GET", credentials: "same-origin" });
    }
    function onIdle(fn, timeout) {
      try {
        if (typeof requestIdleCallback === "function") {
          requestIdleCallback(fn, { timeout: timeout || 2000 });
          return;
        }
      } catch (e) {}
      setTimeout(function () { try { fn(); } catch (e2) {} }, 120);
    }
    function $(sel, root) {
      try { return (root || D).querySelector(sel); } catch (e) { return null; }
    }

    // SPD5-001 instant optimistic toasts (render toast before fetch settles, then reconcile).
    var _toastBox = null;
    function toastBox() {
      if (_toastBox && _toastBox.isConnected) { return _toastBox; }
      if (!D) { return null; }
      _toastBox = $("#spd5-toasts", D);
      if (_toastBox) { return _toastBox; }
      try {
        _toastBox = D.createElement("div");
        _toastBox.id = "spd5-toasts";
        _toastBox.setAttribute("aria-live", "polite");
        _toastBox.style.cssText = "position:fixed;right:12px;bottom:12px;z-index:9999;display:flex;flex-direction:column;gap:8px;pointer-events:none;";
        D.body.appendChild(_toastBox);
      } catch (e) { return null; }
      return _toastBox;
    }
    function toast(msg, kind) {
      try {
        var box = toastBox();
        if (!box) { return null; }
        var el = D.createElement("div");
        el.className = "spd5-toast spd5-toast-" + (kind || "info");
        el.textContent = String(msg == null ? "" : msg);
        el.style.cssText = "pointer-events:auto;background:#111827;color:#f9fafb;padding:8px 12px;border-radius:8px;font-size:13px;opacity:0.96;box-shadow:0 4px 14px rgba(0,0,0,.25);";
        box.appendChild(el);
        setTimeout(function () { try { el.remove(); } catch (e) {} }, 3200);
        return el;
      } catch (e) { return null; }
    }
    S5.toast = toast;
    S5.optimistic = function (label, promise, okLabel, errLabel) {
      var el = toast(label, "pending");
      Promise.resolve(promise).then(function (v) {
        if (el) { try { el.textContent = okLabel || (label + " ✓"); } catch (e) {} }
        return v;
      }, function (e) {
        if (el) { try { el.textContent = errLabel || (label + " ✗"); } catch (e2) {} }
        throw e;
      });
      return el;
    };

    // SPD5-002 prewarm status on idle (cache /api/status during idle, existing endpoint only).
    var _statusCache = { at: 0, data: null };
    S5.statusCache = _statusCache;
    S5.prewarmStatus = function () {
      onIdle(function () {
        if (_statusCache.data) { return; }
        safeFetch(STATUS_URL).then(function (r) { return r && r.json ? r.json() : null; })
          .then(function (j) { _statusCache.data = j; _statusCache.at = Date.now(); })
          .catch(function () {});
      }, 2500);
    };
    S5.getStatusCached = function () {
      if (_statusCache.data) { return Promise.resolve(_statusCache.data); }
      return safeFetch(STATUS_URL).then(function (r) { return r && r.json ? r.json() : null; })
        .then(function (j) { _statusCache.data = j; _statusCache.at = Date.now(); return j; });
    };

    // SPD5-003 delta patch DOM updater (only touch changed text/attrs, skip identical nodes).
    function patchText(el, next) {
      if (!el) { return false; }
      var s = String(next == null ? "" : next);
      if (el.textContent !== s) { el.textContent = s; return true; }
      return false;
    }
    function patchAttrs(el, attrs) {
      if (!el || !attrs) { return 0; }
      var n = 0;
      for (var k in attrs) {
        if (!Object.prototype.hasOwnProperty.call(attrs, k)) { continue; }
        try {
          var v = String(attrs[k]);
          if (el.getAttribute(k) !== v) { el.setAttribute(k, v); n += 1; }
        } catch (e) {}
      }
      return n;
    }
    S5.patch = function (target, text, attrs) {
      var el = typeof target === "string" ? $(target) : target;
      if (!el) { return false; }
      var changed = patchText(el, text);
      var a = patchAttrs(el, attrs);
      return changed || a > 0;
    };
    S5.patchList = function (selector, rows, keyFn, renderFn) {
      var root = $(selector);
      if (!root || !rows) { return 0; }
      var seen = {};
      var changed = 0;
      try {
        rows.forEach(function (row, i) {
          var key = keyFn ? keyFn(row, i) : String(i);
          seen[key] = true;
          var cell = root.querySelector('[data-key="' + key + '"]');
          var html = renderFn ? renderFn(row, i) : String(row);
          if (!cell) {
            var div = D.createElement("div");
            div.setAttribute("data-key", key);
            div.textContent = html;
            root.appendChild(div);
            changed += 1;
          } else if (cell.textContent !== html) {
            cell.textContent = html;
            changed += 1;
          }
        });
      } catch (e) {}
      return changed;
    };

    // SPD5-004 requestAnimationFrame batch (coalesce DOM writes into one frame).
    var _rafQueue = [];
    var _rafScheduled = false;
    function flushRaf() {
      _rafScheduled = false;
      var q = _rafQueue.splice(0, _rafQueue.length);
      for (var i = 0; i < q.length; i++) {
        try { q[i](); } catch (e) {}
      }
    }
    S5.batch = function (fn) {
      if (typeof fn !== "function") { return; }
      _rafQueue.push(fn);
      if (_rafScheduled) { return; }
      _rafScheduled = true;
      try {
        if (typeof requestAnimationFrame === "function") { requestAnimationFrame(flushRaf); return; }
      } catch (e) {}
      setTimeout(flushRaf, 16);
    };

    // SPD5-005 lazy charts below fold (IntersectionObserver-gated init, no upfront cost).
    S5.lazyCharts = function (selector, initFn) {
      if (!D) { return 0; }
      var nodes = [];
      try { nodes = Array.prototype.slice.call(D.querySelectorAll(selector || "[data-spd5-chart]")); } catch (e) { return 0; }
      if (!nodes.length) { return 0; }
      function init(el) {
        if (!el || el.getAttribute("data-spd5-done") === "1") { return; }
        try {
          el.setAttribute("data-spd5-done", "1");
          if (typeof initFn === "function") { initFn(el); }
          else { el.setAttribute("data-spd5-lazy", "ready"); }
        } catch (e) {}
      }
      try {
        if (typeof IntersectionObserver === "function") {
          var io = new IntersectionObserver(function (entries) {
            entries.forEach(function (en) {
              if (en.isIntersecting) { init(en.target); try { io.unobserve(en.target); } catch (e) {} }
            });
          }, { rootMargin: "200px" });
          nodes.forEach(function (n) { try { io.observe(n); } catch (e) {} });
          S5._chartObserver = io;
          return nodes.length;
        }
      } catch (e) {}
      onIdle(function () { nodes.forEach(init); });
      return nodes.length;
    };

    // SPD5-006 compressed health poll (light=1 only, skips when tab hidden).
    var _healthTimer = null;
    var _lastHealth = null;
    S5.lastHealth = function () { return _lastHealth; };
    S5.startLightHealthPoll = function (intervalMs) {
      if (_healthTimer) { return _healthTimer; }
      var ms = intervalMs || 15000;
      function tick() {
        if (D && D.hidden) { return; }
        safeFetch(LIGHT_HEALTH_URL).then(function (r) { return r && r.json ? r.json() : r; })
          .then(function (j) { _lastHealth = { at: Date.now(), data: j }; })
          .catch(function () {});
      }
      onIdle(tick, 2000);
      _healthTimer = setInterval(tick, ms);
      try { if (_healthTimer.unref) { _healthTimer.unref(); } } catch (e) {}
      return _healthTimer;
    };
    S5.stopLightHealthPoll = function () {
      if (_healthTimer) { try { clearInterval(_healthTimer); } catch (e) {} _healthTimer = null; }
    };
    S5.healthUrl = function () { return HEALTH_URL; };

    // SPD5-007 parallel timeline+activity boot (Promise.all, existing endpoints only).
    S5.bootTimelineActivity = function () {
      function asJson(url) {
        return safeFetch(url).then(function (r) { return r && r.json ? r.json() : null; });
      }
      return Promise.all([asJson(TIMELINE_URL), asJson(ACTIVITY_URL)]).then(function (pair) {
        return { timeline: pair[0], activity: pair[1] };
      });
    };

    // SPD5-008 cached service icons (in-memory clone cache, no refetch/re-decode).
    var _iconCache = {};
    S5.serviceIcon = function (name, img) {
      var key = String(name || "default").toLowerCase();
      if (_iconCache[key] && _iconCache[key].isConnected) {
        return _iconCache[key].cloneNode(true);
      }
      var node = null;
      try {
        if (typeof img === "string") {
          node = D.createElement("img");
          node.src = img;
          node.alt = String(name || "");
          node.loading = "lazy";
          node.decoding = "async";
        } else if (img && img.cloneNode) {
          node = img.cloneNode(true);
        } else {
          node = D.createElement("span");
          node.textContent = String(name || "?").slice(0, 1).toUpperCase();
        }
        _iconCache[key] = node;
        return node.cloneNode(true);
      } catch (e) { return null; }
    };
    S5.prewarmIcons = function (map) {
      if (!map) { return; }
      onIdle(function () {
        for (var k in map) {
          if (!Object.prototype.hasOwnProperty.call(map, k)) { continue; }
          try { S5.serviceIcon(k, map[k]); } catch (e) {}
        }
      });
    };

    // SPD5-009 zero-block font load (non-render-blocking swap, additive only).
    S5.loadFonts = function (hrefs) {
      if (!D) { return 0; }
      var list = hrefs || [];
      if (!list.length) {
        try {
          var existing = D.querySelectorAll('link[data-spd5-font]');
          if (existing && existing.length) { return existing.length; }
        } catch (e) {}
        return 0;
      }
      var n = 0;
      list.forEach(function (href) {
        try {
          var sel = 'link[data-spd5-font="' + href + '"]';
          if (D.querySelector(sel)) { return; }
          var link = D.createElement("link");
          link.rel = "stylesheet";
          link.href = href;
          link.media = "print";
          link.setAttribute("data-spd5-font", href);
          link.onload = function () { try { link.media = "all"; } catch (e) {} };
          (D.head || D.documentElement).appendChild(link);
          n += 1;
        } catch (e) {}
      });
      return n;
    };

    // SPD5-010 instant search index (idle-built lowercase index for instant filtering).
    var _searchIdx = { keys: [], text: [], at: 0 };
    S5.buildSearchIndex = function (items, keyFn, textFn) {
      _searchIdx.keys = [];
      _searchIdx.text = [];
      (items || []).forEach(function (it, i) {
        try {
          _searchIdx.keys.push(keyFn ? keyFn(it, i) : String(i));
          _searchIdx.text.push(String(textFn ? textFn(it, i) : it).toLowerCase());
        } catch (e) {}
      });
      _searchIdx.at = Date.now();
      return _searchIdx.keys.length;
    };
    S5.buildSearchIndexIdle = function (getItems, keyFn, textFn) {
      onIdle(function () {
        try {
          var items = typeof getItems === "function" ? getItems() : getItems;
          S5.buildSearchIndex(items || [], keyFn, textFn);
        } catch (e) {}
      });
    };
    S5.search = function (q, limit) {
      var needle = String(q == null ? "" : q).toLowerCase().trim();
      if (!needle) { return []; }
      var out = [];
      var max = limit || 20;
      for (var i = 0; i < _searchIdx.text.length && out.length < max; i++) {
        if (_searchIdx.text[i].indexOf(needle) !== -1) { out.push(_searchIdx.keys[i]); }
      }
      return out;
    };
  } catch (e) {
    try { if (typeof console !== "undefined" && console.warn) { console.warn("spd5-pack init failed", e); } } catch (e2) {}
  }
})();
