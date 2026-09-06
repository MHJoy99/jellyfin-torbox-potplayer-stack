(function(){
try{
var G = typeof globalThis !== "undefined" ? globalThis : Function("return this")();
var W = (G && G.window) ? G.window : G;
var D = (G && G.document) ? G.document : (typeof document !== "undefined" ? document : null);
var S2 = W.__speed2 = W.__speed2 || {};
// T001
function lru(max, onEvict){ var m = new Map(); max = max > 0 ? max : 100; return { get: function(k){ if(!m.has(k)) return undefined; var v = m.get(k); m.delete(k); m.set(k, v); return v; }, set: function(k, v){ if(m.has(k)) m.delete(k); m.set(k, v); if(m.size > max){ var fk = m.keys().next().value; var fv = m.get(fk); m.delete(fk); if(onEvict) onEvict(fk, fv); } return v; }, has: function(k){ return m.has(k); }, del: function(k){ m.delete(k); }, clear: function(){ m.clear(); }, size: function(){ return m.size; } }; }
S2.lru = lru;
// T002
function memoUnary(fn, max){ var c = lru(max || 200); return function(a){ var hit = c.get(a); if(hit !== undefined) return hit; var v = fn(a); c.set(a, v); return v; }; }
S2.memoUnary = memoUnary;
// T003
function memoJson(fn, max){ var c = lru(max || 200); return function(o){ var k = typeof o === "string" ? o : JSON.stringify(o); var hit = c.get(k); if(hit !== undefined) return hit; var v = fn(o); c.set(k, v); return v; }; }
S2.memoJson = memoJson;
// T004
function memoWeak(fn){ var c = (typeof WeakMap !== "undefined") ? new WeakMap() : null; var fb = lru(200); return function(o){ if(o !== null && (typeof o === "object" || typeof o === "function") && c){ if(c.has(o)) return c.get(o); var v = fn(o); c.set(o, v); return v; } var k = String(o); var h = fb.get(k); if(h !== undefined) return h; var v2 = fn(o); fb.set(k, v2); return v2; }; }
S2.memoWeak = memoWeak;
// T005
function ttlCache(ttlMs, max){ var c = lru(max || 300); var now = function(){ return Date.now(); }; return { get: function(k){ var e = c.get(k); if(!e) return undefined; if(now() - e.t > (ttlMs || 30000)){ c.del(k); return undefined; } return e.v; }, set: function(k, v){ c.set(k, { v: v, t: now() }); return v; }, del: function(k){ c.del(k); }, clear: function(){ c.clear(); } }; }
S2.ttlCache = ttlCache;
// T006
function debounce(fn, wait){ var t = 0; wait = wait == null ? 150 : wait; return function(){ var self = this, args = arguments; if(t) { try{ clearTimeout(t); }catch(e){} } t = setTimeout(function(){ t = 0; fn.apply(self, args); }, wait); }; }
S2.debounce = debounce;
// T007
function throttle(fn, wait){ var last = 0, t = 0, la = null, ls = null; wait = wait == null ? 200 : wait; return function(){ var self = this, args = arguments; var n = Date.now(); var rem = wait - (n - last); la = args; ls = self; if(rem <= 0){ if(t){ try{ clearTimeout(t); }catch(e){} t = 0; } last = n; fn.apply(self, args); } else if(!t){ t = setTimeout(function(){ t = 0; last = Date.now(); fn.apply(ls, la); }, rem); } }; }
S2.throttle = throttle;
// T008
function rafThrottle(fn){ var tick = false, la = null, ls = null; function run(){ tick = false; fn.apply(ls, la); } return function(){ la = arguments; ls = this; if(tick) return; tick = true; var r = W.requestAnimationFrame || function(f){ return setTimeout(f, 16); }; r(run); }; }
S2.rafThrottle = rafThrottle;
// T009
function rafQueue(){ var q = [], tick = false; function flush(){ tick = false; var items = q; q = []; for(var i = 0; i < items.length; i++){ try{ items[i][0].apply(items[i][1], items[i][2] || []); }catch(e){} } } return function(fn, self, args){ q.push([fn, self, args]); if(tick) return; tick = true; var r = W.requestAnimationFrame || function(f){ return setTimeout(f, 16); }; r(flush); }; }
S2.rafQueue = rafQueue;
var _writeBatch = null;
// T010
function batchWrite(fn, self, args){ if(!_writeBatch) _writeBatch = rafQueue(); _writeBatch(fn, self, args); }
S2.batchWrite = batchWrite;
// T011
function idleDefer(fn, self, args, timeout){ var run = function(){ try{ fn.apply(self, args || []); }catch(e){} }; try{ if(W.requestIdleCallback){ W.requestIdleCallback(run, { timeout: timeout || 2000 }); return; } }catch(e){} setTimeout(run, 0); }
S2.idleDefer = idleDefer;
// T012
function microDefer(fn, self, args){ var run = function(){ try{ fn.apply(self, args || []); }catch(e){} }; try{ if(typeof queueMicrotask === "function"){ queueMicrotask(run); return; } }catch(e){} try{ Promise.resolve().then(run); }catch(e2){ setTimeout(run, 0); } }
S2.microDefer = microDefer;
// T013
var _tickers = [];
var _tickerTimer = 0;
function addTicker(fn, ms){ var item = { fn: fn, ms: ms || 1000, acc: 0, dead: false }; _tickers.push(item); if(!_tickerTimer){ _tickerTimer = setInterval(function(){ for(var i = _tickers.length - 1; i >= 0; i--){ var t = _tickers[i]; if(t.dead){ _tickers.splice(i, 1); continue; } t.acc += 250; if(t.acc >= t.ms){ t.acc = 0; try{ t.fn(); }catch(e){} } } if(_tickers.length === 0){ try{ clearInterval(_tickerTimer); }catch(e){} _tickerTimer = 0; } }, 250); } return function(){ item.dead = true; }; }
S2.addTicker = addTicker;
// T014
function once(fn){ var done = false, out; return function(){ if(done) return out; done = true; out = fn.apply(this, arguments); return out; }; }
S2.once = once;
// T015
var _flight = new Map();
function singleflight(key, worker){ if(_flight.has(key)) return _flight.get(key); var p = null; try{ p = Promise.resolve().then(worker); }catch(e){ return Promise.reject(e); } _flight.set(key, p); var done = function(){ _flight.delete(key); }; p.then(done, done); return p; }
S2.singleflight = singleflight;
// T016
function fetchWithTimeout(url, opts, ms){ opts = opts || {}; ms = ms == null ? 15000 : ms; var C = W.AbortController; if(!C){ return fetch(url, opts); } var c = new C(); var t = setTimeout(function(){ try{ c.abort(); }catch(e){} }, ms); var o = {}; for(var k in opts){ o[k] = opts[k]; } o.signal = c.signal; return fetch(url, o).then(function(r){ try{ clearTimeout(t); }catch(e){} return r; }, function(e){ try{ clearTimeout(t); }catch(x){} throw e; }); }
S2.fetchWithTimeout = fetchWithTimeout;
// T017
function fetchJsonFast(url, opts, ms){ return fetchWithTimeout(url, opts, ms == null ? 15000 : ms).then(function(r){ if(!r.ok) throw new Error("http " + r.status); return r.json(); }); }
S2.fetchJsonFast = fetchJsonFast;
// T018
var _textMem = lru(100);
function fetchTextCached(url, ms){ var hit = _textMem.get(url); if(hit !== undefined) return Promise.resolve(hit); return fetchWithTimeout(url, null, ms == null ? 15000 : ms).then(function(r){ if(!r.ok) throw new Error("http " + r.status); return r.text(); }).then(function(t){ _textMem.set(url, t); return t; }); }
S2.fetchTextCached = fetchTextCached;
// T019
var _getMem = ttlCache(20000, 300);
function getCached(url, ms){ var hit = _getMem.get(url); if(hit !== undefined) return Promise.resolve(hit); return fetchJsonFast(url, null, ms).then(function(j){ _getMem.set(url, j); return j; }); }
S2.getCached = getCached;
// T020
function staleWhileRevalidate(url, ms){ var hit = _getMem.get(url); if(hit !== undefined){ idleDefer(function(){ fetchJsonFast(url, null, ms).then(function(j){ _getMem.set(url, j); }, function(){}); }); return Promise.resolve(hit); } return getCached(url, ms); }
S2.staleWhileRevalidate = staleWhileRevalidate;
// T021
function parseJsonFast(s, fb){ if(typeof s !== "string") return fb; s = s.replace(/^\uFEFF/, ""); if(s === "" || s === "null") return fb == null ? null : fb; try{ return JSON.parse(s); }catch(e){ return fb; } }
S2.parseJsonFast = parseJsonFast;
// T022
function stringifyFast(v, fb){ try{ var s = JSON.stringify(v); return s == null ? (fb || "") : s; }catch(e){ return fb || ""; } }
S2.stringifyFast = stringifyFast;
// T023
function pick(o, keys){ var out = {}; if(!o) return out; for(var i = 0; i < keys.length; i++){ var k = keys[i]; if(k in o) out[k] = o[k]; } return out; }
S2.pick = pick;
// T024
function pickMany(arr, keys){ if(!arr || !arr.length) return []; var out = new Array(arr.length); for(var i = 0; i < arr.length; i++) out[i] = pick(arr[i], keys); return out; }
S2.pickMany = pickMany;
// T025
function cap(arr, n){ if(!arr) return []; if(arr.length <= n) return arr; return arr.slice(0, n); }
S2.cap = cap;
// T026
function joinFast(parts, sep){ if(!parts) return ""; return parts.join(sep == null ? "" : sep); }
S2.joinFast = joinFast;
// T027
var _tplMem = lru(200);
function tpl(key, make){ var hit = _tplMem.get(key); if(hit !== undefined) return hit; var v = make(); _tplMem.set(key, v); return v; }
S2.tpl = tpl;
// T028
var _escMap = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
function escHtml(s){ s = s == null ? "" : String(s); if(s === "") return ""; if(s.indexOf("&") < 0 && s.indexOf("<") < 0 && s.indexOf(">") < 0 && s.indexOf('"') < 0 && s.indexOf("'") < 0) return s; return s.replace(/[&<>"']/g, function(c){ return _escMap[c]; }); }
S2.escHtml = escHtml;
// T029
function escAttr(s){ s = s == null ? "" : String(s); if(s === "") return ""; if(s.indexOf('"') < 0 && s.indexOf("&") < 0 && s.indexOf("<") < 0) return s; return s.replace(/[<"&]/g, function(c){ return _escMap[c]; }); }
S2.escAttr = escAttr;
// T030
var _numFmtMem = lru(50);
function numFmt(locale, optsKey, opts){ var k = (locale || "") + "|" + (optsKey || ""); var hit = _numFmtMem.get(k); if(hit !== undefined) return hit; var f = null; try{ f = new Intl.NumberFormat(locale || undefined, opts || undefined); }catch(e){ f = null; } _numFmtMem.set(k, f); return f; }
S2.numFmt = numFmt;
// T031
function intComma(n){ n = Math.round(Number(n) || 0); var neg = n < 0 ? "-" : ""; n = Math.abs(n); var s = String(n); var out = []; while(s.length > 3){ out.unshift(s.slice(-3)); s = s.slice(0, -3); } out.unshift(s); return neg + out.join(","); }
S2.intComma = intComma;
// T032
var _tsMem = lru(500);
function fmtTime(ts){ var k = Math.floor((Number(ts) || 0) / 1000); var hit = _tsMem.get(k); if(hit !== undefined) return hit; var v = ""; try{ v = new Date(k * 1000).toLocaleString(); }catch(e){ v = String(ts); } _tsMem.set(k, v); return v; }
S2.fmtTime = fmtTime;
// T033
var _relMem = lru(500);
function relTime(ts, nowMs){ var n = nowMs || Date.now(); var d = n - (Number(ts) || 0); var k = Math.floor(d / 5000); var hit = _relMem.get(k + ":" + Math.floor(n / 60000)); if(hit !== undefined) return hit; var v = d < 10000 ? "just now" : d < 60000 ? Math.floor(d / 1000) + "s ago" : d < 3600000 ? Math.floor(d / 60000) + "m ago" : d < 86400000 ? Math.floor(d / 3600000) + "h ago" : Math.floor(d / 86400000) + "d ago"; _relMem.set(k + ":" + Math.floor(n / 60000), v); return v; }
S2.relTime = relTime;
// T034
var _dayMem = lru(300);
function dayKey(ts){ var k = Math.floor((Number(ts) || 0) / 86400000); var hit = _dayMem.get(k); if(hit !== undefined) return hit; var v = ""; try{ v = new Date(k * 86400000).toDateString(); }catch(e){ v = String(k); } _dayMem.set(k, v); return v; }
S2.dayKey = dayKey;
// T035
function classBatch(el, add, remove){ if(!el || !el.classList) return; if(remove && remove.length){ for(var i = 0; i < remove.length; i++) el.classList.remove(remove[i]); } if(add && add.length){ for(var j = 0; j < add.length; j++) el.classList.add(add[j]); } }
S2.classBatch = classBatch;
// T036
function toggleMany(root, sel, cls, on){ if(!root || !root.querySelectorAll) return; var list = root.querySelectorAll(sel); for(var i = 0; i < list.length; i++){ if(on) list[i].classList.add(cls); else list[i].classList.remove(cls); } }
S2.toggleMany = toggleMany;
// T037
var _styleQ = [];
var _styleTick = false;
function styleBatch(el, props){ _styleQ.push([el, props]); if(_styleTick) return; _styleTick = true; var r = W.requestAnimationFrame || function(f){ return setTimeout(f, 16); }; r(function(){ _styleTick = false; var items = _styleQ; _styleQ = []; for(var i = 0; i < items.length; i++){ try{ var el2 = items[i][0], p = items[i][1]; for(var k in p) el2.style[k] = p[k]; }catch(e){} } }); }
S2.styleBatch = styleBatch;
// T038
function readBatch(els, fn){ var out = new Array(els.length); for(var i = 0; i < els.length; i++){ try{ out[i] = fn(els[i], i); }catch(e){ out[i] = undefined; } } return out; }
S2.readBatch = readBatch;
// T039
function setTransform(el, x, y, scale){ if(!el || !el.style) return; var t = "translate3d(" + (x || 0) + "px," + (y || 0) + "px,0)"; if(scale && scale !== 1) t += " scale(" + scale + ")"; el.style.transform = t; }
S2.setTransform = setTransform;
// T040
function setOpacity(el, v){ if(!el || !el.style) return; el.style.opacity = String(v); }
S2.setOpacity = setOpacity;
// T041
var _hubs = [];
function delegate(root, type, sel, fn, opts){ if(!root || !root.addEventListener) return function(){}; function h(e){ var t = e.target; try{ if(t && t.closest){ var m = t.closest(sel); if(m && root.contains(m)){ fn(e, m); return; } } }catch(x){} var els = null; try{ els = root.querySelectorAll(sel); }catch(e2){ return; } for(var i = 0; i < els.length; i++){ if(els[i] === t || (els[i].contains && els[i].contains(t))){ fn(e, els[i]); return; } } } root.addEventListener(type, h, opts || false); _hubs.push([root, type, h]); return function(){ try{ root.removeEventListener(type, h, opts || false); }catch(e){} }; }
S2.delegate = delegate;
// T042
function delegateClick(root, sel, fn){ return delegate(root, "click", sel, fn, false); }
S2.delegateClick = delegateClick;
// T043
function delegateInput(root, sel, fn, ms){ var d = debounce(function(e, m){ fn(e, m); }, ms == null ? 150 : ms); return delegate(root, "input", sel, d, false); }
S2.delegateInput = delegateInput;
// T044
function onPassive(el, type, fn){ if(!el || !el.addEventListener) return function(){}; var opts = false; try{ opts = { passive: true }; el.addEventListener(type, fn, opts); return function(){ try{ el.removeEventListener(type, fn, opts); }catch(e){} }; }catch(e){ el.addEventListener(type, fn, false); return function(){ try{ el.removeEventListener(type, fn, false); }catch(x){} }; } }
S2.onPassive = onPassive;
// T045
function onOff(el, type, fn, opts){ if(!el || !el.addEventListener) return function(){}; el.addEventListener(type, fn, opts || false); return function(){ try{ el.removeEventListener(type, fn, opts || false); }catch(e){} }; }
S2.onOff = onOff;
// T046
function onceListener(el, type, fn){ if(!el || !el.addEventListener) return; function h(e){ try{ el.removeEventListener(type, h); }catch(x){} fn(e); } el.addEventListener(type, h, false); }
S2.onceListener = onceListener;
// T047
function onScrollThrottled(el, fn, ms){ var t = throttle(fn, ms || 150); return onPassive(el || W, "scroll", t); }
S2.onScrollThrottled = onScrollThrottled;
// T048
function onResizeThrottled(fn, ms){ var t = throttle(fn, ms || 200); return onPassive(W, "resize", t); }
S2.onResizeThrottled = onResizeThrottled;
// T049
var _io1 = null;
function lazyRender(items, renderFn, rootEl, margin){ if(!items || !items.length) return; if(!("IntersectionObserver" in W)){ for(var i = 0; i < items.length; i++){ try{ renderFn(items[i], i); }catch(e){} } return; } try{ if(_io1) { try{ _io1.disconnect(); }catch(e){} } var idx = 0; _io1 = new W.IntersectionObserver(function(es){ for(var j = 0; j < es.length; j++){ if(es[j].isIntersecting){ var it = items[idx++]; if(it !== undefined){ try{ renderFn(it, idx - 1); }catch(e){} } if(idx >= items.length){ try{ _io1.disconnect(); }catch(e2){} return; } } } }, { root: rootEl || null, rootMargin: margin || "200px" }); var anchor = D ? D.createElement("div") : null; if(anchor && D && D.body){ anchor.style.cssText = "width:1px;height:1px;"; D.body.appendChild(anchor); _io1.observe(anchor); S2._lazyAnchor = anchor; } else { for(var k = 0; k < items.length; k++){ try{ renderFn(items[k], k); }catch(e){} } } }catch(e){ for(var m = 0; m < items.length; m++){ try{ renderFn(items[m], m); }catch(x){} } } }
S2.lazyRender = lazyRender;
// T050
var _ioImg = null;
function lazyImages(root){ root = root || D; if(!root || !root.querySelectorAll) return 0; var imgs = root.querySelectorAll("img[data-src]"); if(!imgs.length) return 0; if(!("IntersectionObserver" in W)){ for(var i = 0; i < imgs.length; i++){ try{ imgs[i].src = imgs[i].getAttribute("data-src"); imgs[i].removeAttribute("data-src"); }catch(e){} } return imgs.length; } try{ if(_ioImg){ try{ _ioImg.disconnect(); }catch(e){} } _ioImg = new W.IntersectionObserver(function(es){ for(var j = 0; j < es.length; j++){ if(es[j].isIntersecting){ var im = es[j].target; try{ _ioImg.unobserve(im); }catch(e){} try{ im.src = im.getAttribute("data-src"); im.removeAttribute("data-src"); }catch(x){} } } }); for(var k = 0; k < imgs.length; k++) _ioImg.observe(imgs[k]); }catch(e){} return imgs.length; }
S2.lazyImages = lazyImages;
// T051
function revealSections(root){ root = root || D; if(!root || !root.querySelectorAll) return 0; var secs = root.querySelectorAll("[data-reveal]"); if(!secs.length) return 0; if(!("IntersectionObserver" in W)){ for(var i = 0; i < secs.length; i++){ try{ secs[i].removeAttribute("data-reveal"); }catch(e){} } return secs.length; } try{ var io = new W.IntersectionObserver(function(es){ for(var j = 0; j < es.length; j++){ if(es[j].isIntersecting){ var el = es[j].target; try{ io.unobserve(el); }catch(e){} classBatch(el, ["is-in"], null); } } }, { rootMargin: "100px" }); for(var k = 0; k < secs.length; k++) io.observe(secs[k]); }catch(e){} return secs.length; }
S2.revealSections = revealSections;
// T052
function applyContentVisibility(root, sel){ root = root || D; if(!root || !root.querySelectorAll) return 0; var list = root.querySelectorAll(sel || "[data-cv]"); for(var i = 0; i < list.length; i++){ try{ list[i].style.contentVisibility = "auto"; }catch(e){} } return list.length; }
S2.applyContentVisibility = applyContentVisibility;
// T053
function applyIntrinsicSize(root, sel, size){ root = root || D; if(!root || !root.querySelectorAll) return 0; var list = root.querySelectorAll(sel || "[data-cv]"); for(var i = 0; i < list.length; i++){ try{ list[i].style.containIntrinsicSize = size || "auto 240px"; }catch(e){} } return list.length; }
S2.applyIntrinsicSize = applyIntrinsicSize;
// T054
function decorateImages(root){ root = root || D; if(!root || !root.querySelectorAll) return 0; var list = root.querySelectorAll("img:not([loading])"); for(var i = 0; i < list.length; i++){ try{ list[i].setAttribute("loading", "lazy"); list[i].setAttribute("decoding", "async"); }catch(e){} } return list.length; }
S2.decorateImages = decorateImages;
// T055
var _scriptMem = {};
function lazyScript(src, id){ if(!src || !D) return Promise.resolve(false); if(_scriptMem[src]) return _scriptMem[src]; _scriptMem[src] = new Promise(function(res){ idleDefer(function(){ try{ if(id && D.getElementById(id)){ res(true); return; } var s = D.createElement("script"); s.src = src; s.async = true; s.defer = true; s.onload = function(){ res(true); }; s.onerror = function(){ res(false); }; D.head.appendChild(s); }catch(e){ res(false); } }); }); return _scriptMem[src]; }
S2.lazyScript = lazyScript;
// T056
var _pcMem = {};
function addPreconnect(host){ if(!host || !D || !D.head) return false; if(_pcMem[host]) return true; _pcMem[host] = 1; try{ var l = D.createElement("link"); l.rel = "preconnect"; l.href = host; l.crossOrigin = "anonymous"; D.head.appendChild(l); return true; }catch(e){ return false; } }
S2.addPreconnect = addPreconnect;
// T057
var _dnsMem = {};
function addDnsPrefetch(host){ if(!host || !D || !D.head) return false; if(_dnsMem[host]) return true; _dnsMem[host] = 1; try{ var l = D.createElement("link"); l.rel = "dns-prefetch"; l.href = host; D.head.appendChild(l); return true; }catch(e){ return false; } }
S2.addDnsPrefetch = addDnsPrefetch;
// T058
function warm(urls){ if(!urls) return; var list = typeof urls === "string" ? [urls] : urls; for(var i = 0; i < list.length; i++){ (function(u){ idleDefer(function(){ try{ fetch(u, { method: "GET", credentials: "same-origin" }).then(function(){}, function(){}); }catch(e){} }); })(list[i]); } }
S2.warm = warm;
// T059
function prefetchIdle(urls){ warm(urls); }
S2.prefetchIdle = prefetchIdle;
// T060
function hoverPrefetch(root, sel, worker){ if(!root || !root.addEventListener) return function(){}; var mem = {}; function h(e){ var t = e.target; var m = null; try{ m = t && t.closest ? t.closest(sel) : null; }catch(x){} if(!m) return; var k = m.getAttribute("data-prefetch") || m.textContent; if(!k || mem[k]) return; mem[k] = 1; try{ worker(k, m); }catch(x2){} } root.addEventListener("mouseover", h, { passive: true }); return function(){ try{ root.removeEventListener("mouseover", h); }catch(e){} }; }
S2.hoverPrefetch = hoverPrefetch;
// T061
var _lsReadMem = ttlCache(5000, 200);
function lsGet(key){ var hit = _lsReadMem.get(key); if(hit !== undefined) return hit; var v = null; try{ v = W.localStorage.getItem(key); }catch(e){ v = null; } _lsReadMem.set(key, v); return v; }
S2.lsGet = lsGet;
// T062
var _lsWriteQ = {};
var _lsWriteT = 0;
function lsSet(key, val){ _lsWriteQ[key] = val; _lsReadMem.set(key, val); if(_lsWriteT) return; _lsWriteT = setTimeout(function(){ _lsWriteT = 0; var q = _lsWriteQ; _lsWriteQ = {}; for(var k in q){ try{ W.localStorage.setItem(k, q[k]); }catch(e){} } }, 300); }
S2.lsSet = lsSet;
// T063
var _ssMem = lru(200);
function ssGet(key){ var hit = _ssMem.get(key); if(hit !== undefined) return hit; var v = null; try{ v = W.sessionStorage.getItem(key); }catch(e){ v = null; } _ssMem.set(key, v); return v; }
S2.ssGet = ssGet;
// T064
var _cfgMem = {};
function cfgGet(key, loader){ if(_cfgMem[key] !== undefined) return _cfgMem[key]; var v = null; try{ v = loader(); }catch(e){ v = null; } _cfgMem[key] = v; return v; }
S2.cfgGet = cfgGet;
// T065
var _qMem = lru(300);
function qsCached(sel, root){ var r = root || D; if(!r || !r.querySelector) return null; var k = sel; var hit = _qMem.get(k); if(hit && hit.root === r && D && D.contains(hit.el)) return hit.el; var el = null; try{ el = r.querySelector(sel); }catch(e){ return null; } _qMem.set(k, { root: r, el: el }); return el; }
S2.qsCached = qsCached;
// T066
function qsaFast(root, sel, capN){ if(!root || !root.querySelectorAll) return []; var list = null; try{ list = root.querySelectorAll(sel); }catch(e){ return []; } var n = capN && capN < list.length ? capN : list.length; var out = new Array(n); for(var i = 0; i < n; i++) out[i] = list[i]; return out; }
S2.qsaFast = qsaFast;
// T067
var _pool = {};
function poolGet(name, make){ var p = _pool[name] = _pool[name] || []; if(p.length) return p.pop(); try{ return make(); }catch(e){ return null; } }
function poolPut(name, el){ var p = _pool[name] = _pool[name] || []; if(p.length < 50 && el) p.push(el); }
S2.poolGet = poolGet;
S2.poolPut = poolPut;
// T068
function frag(html){ var f = null; try{ f = D.createRange().createContextualFragment(html); }catch(e){ try{ var t = D.createElement("template"); t.innerHTML = html; f = t.content; }catch(x){ f = null; } } return f; }
S2.frag = frag;
// T069
function setHtml(el, html){ if(!el) return; if(el.__s2html === html) return; el.__s2html = html; try{ el.innerHTML = html; }catch(e){} }
S2.setHtml = setHtml;
// T070
function setText(el, s){ if(!el) return; s = s == null ? "" : String(s); if(el.__s2text === s) return; el.__s2text = s; try{ el.textContent = s; }catch(e){} }
S2.setText = setText;
// T071
function windowed(arr, page, per){ if(!arr) return []; page = page > 0 ? page : 1; per = per > 0 ? per : 50; var s = (page - 1) * per; if(s >= arr.length) return []; return arr.slice(s, s + per); }
S2.windowed = windowed;
// T072
function paginate(total, per, page){ total = total || 0; per = per > 0 ? per : 50; var pages = Math.max(1, Math.ceil(total / per)); page = Math.min(Math.max(1, page || 1), pages); return { total: total, per: per, page: page, pages: pages, start: (page - 1) * per, end: Math.min(total, page * per), hasPrev: page > 1, hasNext: page < pages }; }
S2.paginate = paginate;
// T073
function chunkedRender(items, step, renderFn, done){ items = items || []; step = step > 0 ? step : 50; var i = 0; (function next(){ var end = Math.min(items.length, i + step); for(; i < end; i++){ try{ renderFn(items[i], i); }catch(e){} } if(i < items.length){ idleDefer(next); } else if(done){ try{ done(); }catch(e){} } })(); }
S2.chunkedRender = chunkedRender;
// T074
function estRows(containerH, rowH){ containerH = Number(containerH) || 0; rowH = Number(rowH) || 32; if(rowH <= 0) rowH = 32; return Math.max(1, Math.ceil(containerH / rowH) + 5); }
S2.estRows = estRows;
// T075
var _filterMem = lru(200);
function filterMemo(items, q, fn){ q = (q || "").toLowerCase(); var k = q + "|" + items.length; var hit = _filterMem.get(k); if(hit !== undefined) return hit; var out = []; var ql = q.length; for(var i = 0; i < items.length; i++){ var it = items[i]; var ok = false; try{ ok = ql === 0 || fn(it, q); }catch(e){ ok = false; } if(ok) out.push(it); } _filterMem.set(k, out); return out; }
S2.filterMemo = filterMemo;
// T076
var _sortMem = lru(100);
function sortMemo(items, key, dir){ var k = key + "|" + (dir || "a") + "|" + items.length; var hit = _sortMem.get(k); if(hit !== undefined) return hit; var cp = items.slice(); cp.sort(function(a, b){ var x = a ? a[key] : null, y = b ? b[key] : null; if(x === y) return 0; if(x == null) return 1; if(y == null) return -1; return (x < y ? -1 : 1) * ((dir === "d") ? -1 : 1); }); _sortMem.set(k, cp); return cp; }
S2.sortMemo = sortMemo;
// T077
function dedupeBy(arr, keyFn){ if(!arr) return []; var seen = {}; var out = []; for(var i = 0; i < arr.length; i++){ var k = null; try{ k = keyFn(arr[i], i); }catch(e){ k = i; } var sk = typeof k + ":" + String(k); if(seen[sk]) continue; seen[sk] = 1; out.push(arr[i]); } return out; }
S2.dedupeBy = dedupeBy;
// T078
var _groupMem = lru(100);
function groupBy(items, keyFn){ var k = items.length + "|" + String(keyFn).length; var hit = _groupMem.get(k); if(hit !== undefined) return hit; var out = {}; for(var i = 0; i < items.length; i++){ var g = ""; try{ g = String(keyFn(items[i], i)); }catch(e){ g = ""; } (out[g] = out[g] || []).push(items[i]); } _groupMem.set(k, out); return out; }
S2.groupBy = groupBy;
// T079
function sumFast(arr, fn){ var s = 0; if(!arr) return 0; if(fn){ for(var i = 0; i < arr.length; i++){ try{ s += Number(fn(arr[i], i)) || 0; }catch(e){} } } else { for(var j = 0; j < arr.length; j++) s += Number(arr[j]) || 0; } return s; }
S2.sumFast = sumFast;
// T080
function clamp(v, lo, hi){ v = Number(v) || 0; if(v < lo) return lo; if(v > hi) return hi; return v; }
function lerp(a, b, t){ return a + (b - a) * t; }
S2.clamp = clamp;
S2.lerp = lerp;
// T081
var _bytesMem = lru(300);
function fmtBytes(n){ n = Number(n) || 0; var k = Math.round(n / 1024); var hit = _bytesMem.get(k); if(hit !== undefined) return hit; var v = n; var u = "B"; if(n >= 1099511627776){ v = n / 1099511627776; u = "TB"; } else if(n >= 1073741824){ v = n / 1073741824; u = "GB"; } else if(n >= 1048576){ v = n / 1048576; u = "MB"; } else if(n >= 1024){ v = n / 1024; u = "KB"; } var s = (u === "B" ? Math.round(v) : (Math.round(v * 10) / 10)) + " " + u; _bytesMem.set(k, s); return s; }
S2.fmtBytes = fmtBytes;
// T082
var _durMem = lru(500);
function fmtDur(sec){ sec = Math.max(0, Math.round(Number(sec) || 0)); var hit = _durMem.get(sec); if(hit !== undefined) return hit; var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60; var out = h > 0 ? h + ":" + (m < 10 ? "0" + m : m) + ":" + (s < 10 ? "0" + s : s) : m + ":" + (s < 10 ? "0" + s : s); _durMem.set(sec, out); return out; }
S2.fmtDur = fmtDur;
// T083
function fmtPct(a, b){ a = Number(a) || 0; b = Number(b) || 0; if(b <= 0) return "0%"; return Math.round((a / b) * 100) + "%"; }
S2.fmtPct = fmtPct;
// T084
function plural(n, one, many){ return (Number(n) === 1 ? one : many); }
S2.plural = plural;
// T085
function guard(v, fb){ return (v === null || v === undefined || v === "") ? fb : v; }
S2.guard = guard;
// T086
function getPath(o, path, fb){ if(!o || !path) return fb; var parts = path.split("."); var cur = o; for(var i = 0; i < parts.length; i++){ if(cur == null) return fb; cur = cur[parts[i]]; } return cur === undefined ? fb : cur; }
S2.getPath = getPath;
// T087
function retryCapped(worker, tries, delayMs){ tries = tries > 0 ? tries : 2; delayMs = delayMs == null ? 500 : delayMs; return new Promise(function(res, rej){ var n = 0; (function attempt(){ singleflight("retry" + n + Date.now(), worker).then(res, function(e){ n++; if(n >= tries){ rej(e); return; } setTimeout(attempt, delayMs * n); }); })(); }); }
S2.retryCapped = retryCapped;
// T088
function withTimeout(p, ms, fb){ ms = ms == null ? 8000 : ms; return Promise.race([Promise.resolve(p), new Promise(function(res){ setTimeout(function(){ res(fb); }, ms); })]); }
S2.withTimeout = withTimeout;
// T089
function pLimit(n){ n = n > 0 ? n : 4; var active = 0, q = []; function next(){ if(active >= n || !q.length) return; active++; var item = q.shift(); Promise.resolve().then(item[0]).then(function(v){ active--; item[1](v); next(); }, function(e){ active--; item[2](e); next(); }); } return function(worker){ return new Promise(function(res, rej){ q.push([worker, res, rej]); next(); }); }; }
S2.pLimit = pLimit;
// T090
function prefetchJson(urls){ if(!urls) return; var list = typeof urls === "string" ? [urls] : urls; for(var i = 0; i < list.length; i++){ (function(u){ if(_getMem.get(u) !== undefined) return; idleDefer(function(){ getCached(u).then(function(){}, function(){}); }); })(list[i]); } }
S2.prefetchJson = prefetchJson;
// T091
function warmOnVisible(urls){ if(!D || !("IntersectionObserver" in W)){ prefetchJson(urls); return; } try{ var anchor = D.createElement("div"); anchor.style.cssText = "width:1px;height:1px;"; if(D.body) D.body.appendChild(anchor); var io = new W.IntersectionObserver(function(es){ for(var i = 0; i < es.length; i++){ if(es[i].isIntersecting){ try{ io.disconnect(); }catch(e){} prefetchJson(urls); try{ anchor.remove(); }catch(x){} return; } } }); io.observe(anchor); }catch(e){ prefetchJson(urls); } }
S2.warmOnVisible = warmOnVisible;
// T092
function pauseWhenHidden(stopFn, startFn){ if(!D || !D.addEventListener) return; D.addEventListener("visibilitychange", function(){ try{ if(D.hidden){ if(stopFn) stopFn(); } else { if(startFn) startFn(); } }catch(e){} }); }
S2.pauseWhenHidden = pauseWhenHidden;
// T093
function revalidateOnOnline(urls){ W.addEventListener("online", function(){ try{ prefetchJson(urls || []); }catch(e){} }); }
S2.revalidateOnOnline = revalidateOnOnline;
// T094
function prefetchOnFocus(urls){ var done = false; W.addEventListener("focus", function(){ if(done) return; done = true; try{ prefetchJson(urls || []); }catch(e){} }, { passive: true }); }
S2.prefetchOnFocus = prefetchOnFocus;
// T095
function bindDebouncedInput(root, sel, fn, ms){ return delegateInput(root, sel, fn, ms == null ? 200 : ms); }
S2.bindDebouncedInput = bindDebouncedInput;
// T096
function yieldToMain(){ return new Promise(function(res){ try{ if(W.requestIdleCallback){ W.requestIdleCallback(function(){ res(true); }, { timeout: 50 }); return; } }catch(e){} setTimeout(function(){ res(true); }, 0); }); }
S2.yieldToMain = yieldToMain;
// T097
function autoLazyInit(){ if(!D) return 0; var n = 0; try{ n += lazyImages(D); }catch(e){} try{ n += decorateImages(D); }catch(e2){} return n; }
S2.autoLazyInit = autoLazyInit;
// T098
function autoCvInit(){ if(!D) return 0; var n = 0; try{ n += applyContentVisibility(D, "[data-cv]"); }catch(e){} try{ n += applyIntrinsicSize(D, "[data-cv]"); }catch(e2){} return n; }
S2.autoCvInit = autoCvInit;
// T099
function autoPassiveScroll(){ try{ onScrollThrottled(W, function(){}, 200); }catch(e){} try{ onResizeThrottled(function(){}, 250); }catch(e2){} return true; }
S2.autoPassiveScroll = autoPassiveScroll;
// T100
function bootMark(name){ try{ if(W.performance && W.performance.mark) W.performance.mark(name || "s2-boot"); }catch(e){} return Date.now(); }
S2.bootMark = bootMark;
// T101
function longTaskGuard(fn, budgetMs){ budgetMs = budgetMs || 40; return function(){ var t0 = (W.performance && W.performance.now) ? W.performance.now() : Date.now(); var r = fn.apply(this, arguments); var t1 = (W.performance && W.performance.now) ? W.performance.now() : Date.now(); if(t1 - t0 > budgetMs){ idleDefer(function(){}); } return r; }; }
S2.longTaskGuard = longTaskGuard;
// T102
function htmlList(items, rowFn, sep){ if(!items || !items.length) return ""; var parts = new Array(items.length); for(var i = 0; i < items.length; i++){ try{ parts[i] = rowFn(items[i], i); }catch(e){ parts[i] = ""; } } return parts.join(sep == null ? "" : sep); }
S2.htmlList = htmlList;
// T103
var _cloneMem = {};
function cloneTpl(id){ if(!D) return null; if(_cloneMem[id] && D.contains(_cloneMem[id])){ try{ return _cloneMem[id].cloneNode(true); }catch(e){} } var el = null; try{ el = D.getElementById(id); }catch(e){ return null; } if(!el) return null; _cloneMem[id] = el; try{ return el.cloneNode(true); }catch(e2){ return null; } }
S2.cloneTpl = cloneTpl;
// T104
var _cssOnce = {};
function injectCssOnce(id, css){ if(!D || !D.head || _cssOnce[id]) return false; _cssOnce[id] = 1; try{ var s = D.createElement("style"); s.id = id; s.textContent = css; D.head.appendChild(s); return true; }catch(e){ return false; } }
S2.injectCssOnce = injectCssOnce;
// T105
var NOOP = function(){};
var EMPTY_ARR = [];
var EMPTY_OBJ = {};
S2.NOOP = NOOP;
S2.EMPTY_ARR = EMPTY_ARR;
S2.EMPTY_OBJ = EMPTY_OBJ;
function boot(){ try{ bootMark("s2-boot"); }catch(e){} try{ if(D && D.readyState === "loading"){ D.addEventListener("DOMContentLoaded", function(){ try{ autoLazyInit(); }catch(e){} try{ autoCvInit(); }catch(e2){} }); } else { try{ autoLazyInit(); }catch(e){} try{ autoCvInit(); }catch(e2){} } }catch(e){} try{ pauseWhenHidden(null, function(){ try{ autoLazyInit(); }catch(e){} }); }catch(e2){} }
try{ boot(); }catch(e){}
} catch(e) {}
})();
