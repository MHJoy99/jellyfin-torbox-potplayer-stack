(function () {
  "use strict";
  try {
    var G = typeof globalThis !== "undefined" ? globalThis : Function("return this")();
    var W = (G && G.window) ? G.window : G;
    if (W.__spd4Loaded) { return; }
    W.__spd4Loaded = true;
    var D = (G && G.document) ? G.document : (typeof document !== "undefined" ? document : null);
    var S4 = W.__spd4 = W.__spd4 || {};

    var HEALTH_URL = "/api/health";
    var STATUS_URL = "/api/status";
    var ACTIVITY_URL = "/api/activity";
    var METRICS_URL = "/api/metrics";
    var TIMELINE_URL = "/api/timeline";
    var CONFIG_URL = "/api/config";
    var ACTION_URL = "/api/action";
    var RESTART_URL = "/api/restart";
    var LIGHT_HEALTH_URL = "/api/health?light=1";

    function safeFetch(url, opts) {
      if (typeof fetch !== "function") { return Promise.reject(new Error("fetch unavailable")); }
      return fetch(url, opts || { method: "GET", credentials: "same-origin" });
    }

    // SPD4-001 parallel health fan-out with concurrency 3 (existing endpoints only).
    function fanOut3(urls, fetchFn) {
      var list = (urls || [HEALTH_URL, STATUS_URL, METRICS_URL]).slice();
      var limit = 3;
      var doFetch = fetchFn || safeFetch;
      var out = new Array(list.length);
      var idx = 0, active = 0;
      return new Promise(function (resolve) {
        if (!list.length) { resolve(out); return; }
        function next() {
          while (active < limit && idx < list.length) {
            (function (i) {
              var u = list[i];
              active += 1;
              var p = null;
              try { p = Promise.resolve().then(function () { return doFetch(u); }); }
              catch (e) { out[i] = { ok: false, url: u, error: e }; active -= 1; next(); return; }
              p.then(function (v) { out[i] = { ok: true, url: u, value: v }; },
                function (e) { out[i] = { ok: false, url: u, error: e }; })
                .then(function () {
                  active -= 1;
                  if (idx >= list.length && active === 0) { resolve(out); }
                  else { next(); }
                });
            })(idx);
            idx += 1;
          }
        }
        next();
      });
    }
    S4.fanOut3 = fanOut3;
    S4.healthFanOut = function (fetchFn) { return fanOut3([HEALTH_URL, STATUS_URL, METRICS_URL], fetchFn); };

    // SPD4-002 stale-while-revalidate for timeline (/api/timeline only).
    var _tlCache = { at: 0, data: null, inflight: null };
    var TL_TTL_MS = 30000;
    function timelineSWR(force) {
      var now = Date.now();
      var fresh = _tlCache.data && (now - _tlCache.at) < TL_TTL_MS;
      function revalidate() {
        if (_tlCache.inflight) { return _tlCache.inflight; }
        _tlCache.inflight = safeFetch(TIMELINE_URL)
          .then(function (r) { return r && r.json ? r.json() : null; })
          .then(function (j) { _tlCache.data = j; _tlCache.at = Date.now(); return j; })
          .catch(function () { return _tlCache.data; })
          .then(function (v) { _tlCache.inflight = null; return v; });
        return _tlCache.inflight;
      }
      if (force) { return revalidate(); }
      if (_tlCache.data) {
        if (!fresh) { try { revalidate(); } catch (e) {} }
        return Promise.resolve(_tlCache.data);
      }
      return revalidate();
    }
    S4.timelineSWR = timelineSWR;

    // SPD4-003 optimistic restart button state (additive delegation; no wiring changes).
    function optimisticRestart() {
      if (!D || !D.addEventListener) { return false; }
      if (S4._optRestartBound) { return true; }
      S4._optRestartBound = true;
      D.addEventListener("click", function (ev) {
        try {
          var b = ev.target && ev.target.closest ? ev.target.closest("button[data-action='restart']") : null;
          if (!b || b.disabled) { return; }
          if (b.dataset.spd4Opt === "1") { return; }
          b.dataset.spd4Opt = "1";
          var orig = b.textContent;
          b.disabled = true;
          b.setAttribute("aria-busy", "true");
          b.textContent = "Restarting…";
          var done = function () {
            try {
              b.disabled = false;
              b.removeAttribute("aria-busy");
              b.textContent = orig;
              delete b.dataset.spd4Opt;
            } catch (e) {}
          };
          setTimeout(done, 8000);
          S4._optRestartDone = done;
        } catch (e) {}
      }, true);
      return true;
    }
    S4.optimisticRestart = optimisticRestart;
    try { optimisticRestart(); } catch (e) {}

    // SPD4-004 skeleton shimmer for service cards (additive CSS class only).
    function ensureSkeletons() {
      if (!D) { return false; }
      if (D.getElementById("spd4-skeleton-css")) { return true; }
      try {
        var st = D.createElement("style");
        st.id = "spd4-skeleton-css";
        st.textContent = ".spd4-skel{position:relative;overflow:hidden;background:rgba(127,127,127,.18);border-radius:8px;min-height:14px}" +
          ".spd4-skel::after{content:'';position:absolute;inset:0;transform:translateX(-100%);" +
          "background:linear-gradient(90deg,transparent,rgba(255,255,255,.25),transparent);" +
          "animation:spd4shimmer 1.2s infinite}" +
          "@keyframes spd4shimmer{to{transform:translateX(100%)}}" +
          "@media (prefers-reduced-motion:reduce){.spd4-skel::after{animation:none}}";
        (D.head || D.documentElement).appendChild(st);
        return true;
      } catch (e) { return false; }
    }
    function skeletonize(cards) {
      ensureSkeletons();
      try {
        var els = cards || (D ? D.querySelectorAll("[data-service-card],.service-card") : []);
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          if (el && el.classList && !el.dataset.spd4Skel) {
            el.dataset.spd4Skel = "1";
            el.classList.add("spd4-skel");
            (function (n) { setTimeout(function () { try { n.classList.remove("spd4-skel"); } catch (e) {} }, 2500); })(el);
          }
        }
      } catch (e) {}
      return true;
    }
    S4.ensureSkeletons = ensureSkeletons;
    S4.skeletonize = skeletonize;

    // SPD4-005 progressive activity-log append (renders /api/activity incrementally).
    function appendActivity(container, items) {
      if (!D || !container || !items || !items.length) { return 0; }
      try {
        var frag = D.createDocumentFragment();
        for (var i = 0; i < items.length; i++) {
          var it = items[i];
          var li = D.createElement("li");
          li.className = "spd4-act";
          li.textContent = String((it && (it.text || it.msg || it.title)) || ("event-" + i));
          frag.appendChild(li);
        }
        container.appendChild(frag);
        while (container.children.length > 300) { container.removeChild(container.firstChild); }
        return items.length;
      } catch (e) { return 0; }
    }
    function activityAppend(url) {
      return safeFetch(url || ACTIVITY_URL)
        .then(function (r) { return r && r.json ? r.json() : []; })
        .then(function (j) {
          var list = Array.isArray(j) ? j : (j && j.items) || [];
          var box = D ? (D.querySelector("[data-activity-log]") || D.getElementById("activity-log")) : null;
          if (box) { appendActivity(box, list.slice(0, 50)); }
          return list.length;
        })
        .catch(function () { return 0; });
    }
    S4.appendActivity = appendActivity;
    S4.activityAppend = activityAppend;

    // SPD4-006 backoff retry for 5xx only (existing endpoints; no retry on 4xx/network abort).
    function fetchRetry5xx(url, opts, tries) {
      tries = (tries == null || tries < 1) ? 3 : tries;
      var attempt = 0;
      function once() {
        attempt += 1;
        return safeFetch(url, opts).then(function (r) {
          var st = r ? r.status : 0;
          if (st >= 500 && st <= 599 && attempt < tries) {
            var wait = Math.min(2000, 150 * Math.pow(2, attempt - 1));
            return new Promise(function (res) { setTimeout(res, wait); }).then(once);
          }
          return r;
        }, function (e) {
          if (e && e.name === "AbortError") { throw e; }
          if (attempt < tries && e && e.status >= 500) {
            var wait2 = Math.min(2000, 150 * Math.pow(2, attempt - 1));
            return new Promise(function (res) { setTimeout(res, wait2); }).then(once);
          }
          throw e;
        });
      }
      return once();
    }
    S4.fetchRetry5xx = fetchRetry5xx;

    // SPD4-007 cancel in-flight on refresh (shared AbortController).
    var _ctl = null;
    function refreshFetch(url, opts) {
      try { if (_ctl) { _ctl.abort(); } } catch (e) {}
      try {
        if (typeof AbortController !== "undefined") {
          _ctl = new AbortController();
          opts = opts || {};
          opts.signal = _ctl.signal;
        }
      } catch (e) {}
      return safeFetch(url, opts);
    }
    function cancelInflight() { try { if (_ctl) { _ctl.abort(); } } catch (e) {} _ctl = null; }
    S4.refreshFetch = refreshFetch;
    S4.cancelInflight = cancelInflight;

    // SPD4-008 prefetch Jellyfin web on hover (link prefetch hint + warm light health).
    function prefetchOnHover() {
      if (!D || !D.addEventListener) { return false; }
      if (S4._hoverBound) { return true; }
      S4._hoverBound = true;
      var warmed = false;
      D.addEventListener("mouseover", function (ev) {
        try {
          var a = ev.target && ev.target.closest ? ev.target.closest("a[href]") : null;
          if (!a) { return; }
          var href = a.getAttribute("href") || "";
          var isWeb = href.indexOf("/web") !== -1 || /jellyfin/i.test(href);
          if (!isWeb) { return; }
          if (!D.querySelector("link[data-spd4-prefetch]")) {
            var l = D.createElement("link");
            l.rel = "prefetch";
            l.href = href;
            l.setAttribute("data-spd4-prefetch", "1");
            (D.head || D.documentElement).appendChild(l);
          }
          if (!warmed) {
            warmed = true;
            safeFetch(LIGHT_HEALTH_URL).catch(function () {});
            setTimeout(function () { warmed = false; }, 60000);
          }
        } catch (e) {}
      }, { passive: true });
      return true;
    }
    S4.prefetchOnHover = prefetchOnHover;
    try { prefetchOnHover(); } catch (e) {}

    // SPD4-009 compress localStorage prefs (JSON min, namespaced, guarded).
    var PREF_PREFIX = "jf.spd4.";
    function prefSave(name, obj) {
      try {
        if (typeof localStorage === "undefined") { return false; }
        var s = JSON.stringify(obj);
        s = s.replace(/\s+/g, " ");
        localStorage.setItem(PREF_PREFIX + String(name), s);
        return true;
      } catch (e) { return false; }
    }
    function prefLoad(name, fallback) {
      try {
        if (typeof localStorage === "undefined") { return fallback; }
        var s = localStorage.getItem(PREF_PREFIX + String(name));
        if (s == null) { return fallback; }
        return JSON.parse(s);
      } catch (e) { return fallback; }
    }
    S4.prefSave = prefSave;
    S4.prefLoad = prefLoad;

    // SPD4-010 fast-path light /api/health?light=1 poll (short timeout, additive helper).
    var _lightTimer = null;
    function lightPoll(cb, intervalMs) {
      var iv = intervalMs || 15000;
      function tick() {
        var ctrl = null;
        var opts = { method: "GET", credentials: "same-origin" };
        try {
          if (typeof AbortController !== "undefined") {
            ctrl = new AbortController();
            opts.signal = ctrl.signal;
            setTimeout(function () { try { ctrl.abort(); } catch (e) {} }, 4000);
          }
        } catch (e) {}
        safeFetch(LIGHT_HEALTH_URL, opts).then(function (r) {
          return (r && r.json) ? r.json().catch(function () { return null; }) : null;
        }).then(function (j) { try { if (cb) { cb(null, j); } } catch (e) {} })
          .catch(function (e) { try { if (cb) { cb(e, null); } } catch (e2) {} });
      }
      tick();
      try { if (_lightTimer) { clearInterval(_lightTimer); } } catch (e) {}
      try { _lightTimer = setInterval(tick, iv); } catch (e) {}
      S4._lightTimer = _lightTimer;
      return function stop() { try { if (_lightTimer) { clearInterval(_lightTimer); } } catch (e) {} _lightTimer = null; };
    }
    S4.lightPoll = lightPoll;
    S4.urls = { health: HEALTH_URL, status: STATUS_URL, activity: ACTIVITY_URL, metrics: METRICS_URL, timeline: TIMELINE_URL, config: CONFIG_URL, action: ACTION_URL, restart: RESTART_URL, light: LIGHT_HEALTH_URL };
  } catch (e) {}
})();
