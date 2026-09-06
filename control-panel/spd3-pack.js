(function(){
try{
var G = typeof globalThis !== "undefined" ? globalThis : Function("return this")();
var W = (G && G.window) ? G.window : G;
var D = (G && G.document) ? G.document : (typeof document !== "undefined" ? document : null);
var S3 = W.__spd3 = W.__spd3 || {};

// SPD3-001
var PREBUILT_HEADERS = null;
function prebuiltHeaders(){
  if (PREBUILT_HEADERS) return PREBUILT_HEADERS;
  try{
    if (W.Headers){ PREBUILT_HEADERS = new W.Headers({ "Accept": "application/json", "X-Requested-With": "fetch" }); }
    else { PREBUILT_HEADERS = { "Accept": "application/json", "X-Requested-With": "fetch" }; }
  }catch(e){ PREBUILT_HEADERS = { "Accept": "application/json" }; }
  return PREBUILT_HEADERS;
}
function pooledFetch(url, opts){
  opts = opts || {};
  var o = { method: opts.method || "GET", credentials: opts.credentials || "same-origin", keepalive: true, mode: "same-origin", redirect: "follow", referrerPolicy: "no-referrer" };
  if (opts.headers){ o.headers = opts.headers; }
  else { o.headers = prebuiltHeaders(); }
  if (opts.body != null) o.body = opts.body;
  if (opts.signal) o.signal = opts.signal;
  return fetch(url, o);
}
S3.pooledFetch = pooledFetch;
S3.prebuiltHeaders = prebuiltHeaders;

// SPD3-002
function fanOut(workers, limit){
  limit = (limit == null || limit < 1) ? 4 : limit;
  var list = workers ? workers.slice() : [];
  var out = new Array(list.length);
  var idx = 0, active = 0;
  return new Promise(function(resolve){
    if (!list.length){ resolve(out); return; }
    function next(){
      while (active < limit && idx < list.length){
        (function(i){
          var w = list[i];
          active++;
          var p = null;
          try{ p = Promise.resolve().then(w); }catch(e){ out[i] = { ok: false, error: e }; active--; next(); return; }
          p.then(function(v){ out[i] = { ok: true, value: v }; }, function(e){ out[i] = { ok: false, error: e }; }).then(function(){ active--; if (idx >= list.length && active === 0){ resolve(out); } else { next(); } });
        })(idx++);
      }
    }
    next();
  });
}
S3.fanOut = fanOut;

// SPD3-003
function incrementalSync(prev, nextList, fns){
  fns = fns || {};
  var keyFn = fns.key || function(x){ return x && x.id; };
  var verFn = fns.version || function(x){ return x && (x.mtime || x.updated || x.rev || 0); };
  var next = new Map();
  var mount = fns.mount || null;
  for (var i = 0; i < (nextList || []).length; i++){
    var item = nextList[i], k = null;
    try{ k = keyFn(item, i); }catch(e){ continue; }
    if (k == null) continue;
    next.set(k, item);
    var old = prev ? prev.get(k) : undefined;
    var changed = (old === undefined) || (verFn(old) !== verFn(item));
    if (changed){
      try{ if (fns.upsert) fns.upsert(k, item, old, mount); }catch(e){}
    }
  }
  if (prev){
    prev.forEach(function(_, k){
      if (!next.has(k)){ try{ if (fns.remove) fns.remove(k, mount); }catch(e){} }
    });
  }
  return next;
}
S3.incrementalSync = incrementalSync;

// SPD3-004
function deferHeavy(fn, timeoutMs){
  var run = function(deadline){
    try{ fn(deadline || null); }catch(e){}
  };
  try{
    if (W.requestIdleCallback){ W.requestIdleCallback(run, { timeout: timeoutMs || 2500 }); return true; }
  }catch(e){}
  try{
    if (D && D.readyState === "loading"){ D.addEventListener("DOMContentLoaded", function(){ setTimeout(run, 0); }, { once: true }); }
    else { setTimeout(run, 0); }
  }catch(e2){ setTimeout(run, 0); }
  return true;
}
S3.deferHeavy = deferHeavy;

// SPD3-005
var _splash = null, _splashBar = null, _splashLabel = null;
function splashStage(label, pct){
  try{
    if (!D || !D.body) return false;
    if (!_splash){
      _splash = D.createElement("div");
      _splash.id = "boot-splash";
      _splash.setAttribute("role", "status");
      _splash.setAttribute("aria-live", "polite");
      var css = "#boot-splash{position:fixed;inset:0;z-index:9999;display:flex;align-items:center;justify-content:center;background:#0b0e14;color:#e6edf3}#boot-splash .box{width:min(420px,86vw);text-align:center}#boot-splash .bar{height:6px;border-radius:4px;background:#1c2530;overflow:hidden;margin-top:12px}#boot-splash .bar>i{display:block;height:100%;width:0;background:#3fb950;transition:width .25s ease}#boot-splash .lbl{font:13px/1.4 system-ui,sans-serif;opacity:.85}";
      var st = D.createElement("style"); st.textContent = css;
      var box = D.createElement("div"); box.className = "box";
      _splashLabel = D.createElement("div"); _splashLabel.className = "lbl"; _splashLabel.textContent = "Loading…";
      var bar = D.createElement("div"); bar.className = "bar";
      _splashBar = D.createElement("i");
      bar.appendChild(_splashBar); box.appendChild(_splashLabel); box.appendChild(bar);
      _splash.appendChild(st); _splash.appendChild(box);
      D.body.appendChild(_splash);
    }
    if (label != null && _splashLabel) _splashLabel.textContent = String(label);
    if (pct != null && _splashBar){
      var p = Math.max(0, Math.min(100, Number(pct) || 0));
      _splashBar.style.width = p + "%";
    }
    if (pct != null && Number(pct) >= 100){
      var el = _splash;
      _splash = null; _splashBar = null; _splashLabel = null;
      setTimeout(function(){ try{ if (el && el.parentNode) el.parentNode.removeChild(el); }catch(e){} }, 300);
    }
    return true;
  }catch(e){ return false; }
}
S3.splashStage = splashStage;

// SPD3-006
function withTimeout(worker, ms, fallback){
  ms = (ms == null) ? 15000 : ms;
  var hasFallback = arguments.length >= 3;
  return new Promise(function(resolve, reject){
    var done = false, timer = 0;
    var finish = function(fn, v){ if (done) return; done = true; try{ clearTimeout(timer); }catch(e){} fn(v); };
    try{
      timer = setTimeout(function(){
        if (hasFallback){ finish(resolve, (typeof fallback === "function") ? fallback() : fallback); }
        else { finish(reject, new Error("timeout after " + ms + "ms")); }
      }, ms);
    }catch(e){}
    var p = null;
    try{
      if (typeof worker === "function"){
        var C = W.AbortController || null, ctrl = null;
        try{ if (C) ctrl = new C(); }catch(e){}
        p = Promise.resolve().then(function(){ return worker(ctrl ? ctrl.signal : undefined); });
        p.then(function(v){ finish(resolve, v); }, function(e2){ finish(reject, e2); });
        var t = timer;
        if (ctrl){ var to = setTimeout(function(){ try{ ctrl.abort(); }catch(e){} }, ms); p.then(function(){ try{ clearTimeout(to); }catch(e){} }, function(){ try{ clearTimeout(to); }catch(e){} }); }
        void t;
      } else {
        Promise.resolve(worker).then(function(v){ finish(resolve, v); }, function(e2){ finish(reject, e2); });
      }
    }catch(e){ finish(reject, e); }
  });
}
S3.withTimeout = withTimeout;

// SPD3-007
function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
function getRetry(url, opts){
  opts = opts || {};
  var retries = (opts.retries == null) ? 3 : opts.retries;
  var base = (opts.baseMs == null) ? 300 : opts.baseMs;
  var max = (opts.maxMs == null) ? 4000 : opts.maxMs;
  var ms = opts.timeoutMs == null ? 15000 : opts.timeoutMs;
  var attempt = 0;
  function once(){
    return withTimeout(function(signal){
      var o = { headers: prebuiltHeaders() };
      if (signal) o.signal = signal;
      return pooledFetch(url, o).then(function(r){
        if (r.ok) return r;
        if (r.status >= 500 || r.status === 429) throw new Error("http " + r.status);
        return r;
      });
    }, ms);
  }
  function loop(){
    return once().catch(function(e){
      if (attempt >= retries) throw e;
      var back = Math.min(max, base * Math.pow(2, attempt));
      var jit = Math.floor(Math.random() * Math.min(500, back));
      attempt++;
      return sleep(back + jit).then(loop);
    });
  }
  return loop();
}
S3.getRetry = getRetry;

// SPD3-008
var PANEL_VERSION = "3.0.0";
var VER_KEY = "panel.cache.version";
function versionedCache(prefix){
  prefix = prefix || "panel.cache.";
  var current = null;
  try{ current = localStorage.getItem(VER_KEY); }catch(e){}
  if (current !== PANEL_VERSION){
    try{
      var drop = [];
      for (var i = 0; i < localStorage.length; i++){
        var k = localStorage.key(i);
        if (k && k.indexOf(prefix) === 0) drop.push(k);
      }
      for (var j = 0; j < drop.length; j++){ try{ localStorage.removeItem(drop[j]); }catch(e){} }
      try{ localStorage.setItem(VER_KEY, PANEL_VERSION); }catch(e2){}
    }catch(e){}
  }
  return {
    version: PANEL_VERSION,
    get: function(k, fb){ try{ var raw = localStorage.getItem(prefix + k); return raw == null ? fb : JSON.parse(raw); }catch(e){ return fb; } },
    set: function(k, v){ try{ localStorage.setItem(prefix + k, JSON.stringify(v)); return true; }catch(e){ return false; } },
    del: function(k){ try{ localStorage.removeItem(prefix + k); }catch(e){} }
  };
}
S3.versionedCache = versionedCache;
S3.PANEL_VERSION = PANEL_VERSION;

// SPD3-009
function refetchOnVisible(refetch, waitMs){
  waitMs = (waitMs == null) ? 5000 : waitMs;
  var last = 0, pending = false;
  function throttled(){
    var n = Date.now();
    if (n - last < waitMs){ pending = true; return; }
    last = n; pending = false;
    try{ refetch(); }catch(e){}
  }
  function onTimer(){
    if (pending){ pending = false; last = Date.now(); try{ refetch(); }catch(e){} }
  }
  try{
    if (D) D.addEventListener("visibilitychange", function(){ if (!D.hidden) throttled(); });
    if (W){ W.addEventListener("focus", throttled); W.addEventListener("online", throttled); }
    setInterval(onTimer, Math.max(1000, waitMs));
  }catch(e){}
  return throttled;
}
S3.refetchOnVisible = refetchOnVisible;

// SPD3-010
var _banner = null, _queued = 0;
function setQueued(n){ _queued = Math.max(0, Number(n) || 0); paintBanner(); return _queued; }
function queueWhileOffline(action){
  var online = true;
  try{ online = (typeof navigator === "undefined") ? true : navigator.onLine !== false; }catch(e){}
  if (online){ try{ return Promise.resolve().then(action); }catch(e){ return Promise.reject(e); } }
  _queued++;
  try{ paintBanner(); }catch(e){}
  return new Promise(function(resolve){
    function flush(){
      if ((typeof navigator !== "undefined" && navigator.onLine === false)) return;
      try{ W.removeEventListener("online", flush); }catch(e){}
      _queued = Math.max(0, _queued - 1);
      try{ paintBanner(); }catch(e2){}
      try{ resolve(action()); }catch(e3){ resolve(undefined); }
    }
    try{ W.addEventListener("online", flush); }catch(e){ resolve(undefined); }
  });
}
function paintBanner(){
  try{
    if (!D || !D.body) return false;
    var online = (typeof navigator === "undefined") ? true : navigator.onLine !== false;
    if (online && _queued === 0){
      if (_banner && _banner.parentNode){ _banner.parentNode.removeChild(_banner); }
      _banner = null;
      return true;
    }
    if (!_banner){
      _banner = D.createElement("div");
      _banner.id = "offline-banner";
      _banner.setAttribute("role", "alert");
      _banner.style.cssText = "position:fixed;left:50%;bottom:14px;transform:translateX(-50%);z-index:9998;padding:8px 14px;border-radius:8px;background:#7a2e1d;color:#fff;font:13px/1.4 system-ui,sans-serif;box-shadow:0 4px 18px rgba(0,0,0,.35)";
      D.body.appendChild(_banner);
    }
    _banner.textContent = online
      ? ("Back online — " + _queued + " queued action(s) flushing…")
      : ("Offline — " + _queued + " queued action(s). Changes will flush on reconnect.");
    try{
      _banner.style.background = online ? "#1d5c34" : "#7a2e1d";
    }catch(e){}
    return true;
  }catch(e){ return false; }
}
function watchOnline(){
  try{
    if (!W || !W.addEventListener) return false;
    W.addEventListener("online", paintBanner);
    W.addEventListener("offline", paintBanner);
    try{ paintBanner(); }catch(e){}
    return true;
  }catch(e){ return false; }
}
try{ watchOnline(); }catch(e){}
S3.offlineBanner = { paint: paintBanner, watch: watchOnline, queue: queueWhileOffline, setQueued: setQueued };
} catch(e) {}
})();
