#!/usr/bin/env python3
"""
Torbox Local HTTP Proxy — stable Range streams for PotPlayer
Solves 9-1-1 2026-08-24 expiry: https://nexus.erth.tb-cdn.earth/dld/...?token=... expires after click,
so PotPlayer shows "Unable to connect to the requested server" on next play.

This proxy runs on 127.0.0.1:8888 and translates:
  http://127.0.0.1:8888/torbox/<torrent_id>/<file_id>/<nice_name>
    -> fresh https://api.torbox.app/v1/api/torrents/requestdl?torrent_id=...&file_id=...
    -> local streamed bytes with Range support and CDN retry/backoff

Playlist uses http://127.0.0.1:8888 URLs that do not contain expiring CDN tokens. The proxy caches
the short-lived resolver result, streams the CDN response locally, and hides transient CDN 429s
from PotPlayer while retrying after the provider's cooldown.
Supports Range, Content-Length, Accept-Ranges for PotPlayer bar to fill to full.

Also proxies GDrive via rclone WebDAV for F:\Media when mount is down.
"""
import http.server, urllib.parse, urllib.request, json, os, threading, time, sys, random
from pathlib import Path
import requests
from requests.adapters import HTTPAdapter
from requests.exceptions import Timeout

TORBOX_API_KEY = (os.environ.get("TORBOX_API_KEY") or "").strip()
if not TORBOX_API_KEY:
    print("FATAL: TORBOX_API_KEY env var is empty; refusing to start (set $env:TORBOX_API_KEY)", file=sys.stderr)
    sys.exit(2)
TORBOX_API = "https://api.torbox.app/v1/api/torrents"
RCLONE_CONF = r"F:\Jellyfin\config\rclone.conf"
RCLONE_EXE = r"F:\Jellyfin\server\rclone.exe"
LOG_FILE = r"F:\Jellyfin\logs\torbox-proxy.log"
PORT = 8888
CDN_CACHE_TTL = 300
CDN_STALE_FALLBACK_TTL = 900
REQUESTDL_MIN_INTERVAL = 1.5
MEDIA_EXTS = {".mkv", ".mp4", ".avi", ".ts", ".m4v", ".mov", ".webm", ".m2ts"}

# Pooled session: reuse keep-alive connections to TorBox API + CDN.
_SESSION = requests.Session()
_POOL_ADAPTER = HTTPAdapter(pool_connections=20, pool_maxsize=50, max_retries=0)
_SESSION.mount("https://", _POOL_ADAPTER)
_SESSION.mount("http://", _POOL_ADAPTER)

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except: pass

_link_cache = {}
_link_cache_lock = threading.Lock()
# Bound: one entry per (torrent,file); evict oldest ts when at cap (O(n) scan, insert-only-when-over-cap).
_LINK_CACHE_CAP = 512
_LINK_CACHE_EVICTIONS = 0
_requestdl_lock = threading.Lock()
_last_requestdl_at = 0.0
# --- requestdl token bucket (Essential: 300/min/key/endpoint, requestdl 429s observed) ---
# In-process throttle so a 10-probe PotPlayer storm + sync/launcher mylist traffic
# on the same TorBox key cannot trip API 429s. Monotonic clock, lock-protected.
_REQUESTDL_BUCKET_CAPACITY = 10.0
_REQUESTDL_BUCKET_REFILL_S = 12.0
_REQUESTDL_BUCKET_WAIT_S = 15.0
_REQUESTDL_BACKGROUND_MIN_TOKENS = 2.0
_requestdl_bucket_tokens = 10.0
_requestdl_bucket_updated_mono = time.monotonic()
_requestdl_cooldown_until_mono = 0.0
_requestdl_cooldown_until_wall = 0.0
_requestdl_bucket_lock = threading.Lock()
# Singleflight: per-(tid,fid) in-flight Event so N concurrent probes = 1 API call.
_inflight = {}
_inflight_lock = threading.Lock()

# --- Shared mylist cache (single TorBox fetcher, 600s TTL) ---
# Proxy + launcher (60s) + sync (30m) previously each polled mylist?bypass_cache=true
# separately (~2900/day on shared 300/min quota). Now all HTTP consumers use
# GET /mylist; TorBox is hit with bypass_cache=true at most once per 600s.
_MYLIST_TTL_S = 600.0
_MYLIST_FETCH_TIMEOUT = 12
_MYLIST_SINGLEFLIGHT_WAIT_S = 15.0
_mylist_cache = {"payload": None, "ts": 0.0, "fetched_iso": ""}
_mylist_cache_lock = threading.Lock()
_mylist_inflight = None
_mylist_inflight_lock = threading.Lock()

# --- Lightweight in-process metrics (replaces 5000-line log scans) ---
_START_TIME = time.time()
_START_ISO = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(_START_TIME))
_METRICS_LOCK = threading.Lock()
_METRICS = {
    "torbox": {"200": 0, "2xx": 0, "206": 0, "416": 0, "429": 0, "502": 0},
    "gdrive": {"200": 0, "2xx": 0, "206": 0, "400": 0, "403": 0, "404": 0, "416": 0, "500": 0},
    "cdn_retry": {"429": 0, "503": 0, "403": 0, "404": 0, "410": 0},
    "requestdl": {"ok": 0, "cached": 0, "ratelimited": 0, "failed": 0},
    "mylist": {"fetches": 0, "served": 0},
    "active_streams": 0,
    "last_requestdl_ok": 0.0,
}

def _m_inc(group, key):
    """Thread-safe counter increment (creates sparse keys on demand)."""
    try:
        k = str(key)
        with _METRICS_LOCK:
            bucket = _METRICS.get(group)
            if bucket is None:
                return
            bucket[k] = bucket.get(k, 0) + 1
            # Keep 2xx rollup in sync for torbox/gdrive success buckets.
            if group in ("torbox", "gdrive") and k != "2xx" and len(k) == 3 and k.startswith("2"):
                bucket["2xx"] = bucket.get("2xx", 0) + 1
    except Exception:
        pass

def _m_active(delta):
    try:
        with _METRICS_LOCK:
            _METRICS["active_streams"] = int(_METRICS.get("active_streams", 0)) + int(delta)
            if _METRICS["active_streams"] < 0:
                _METRICS["active_streams"] = 0
    except Exception:
        pass

def _m_requestdl_ok():
    try:
        with _METRICS_LOCK:
            _METRICS["requestdl"]["ok"] = _METRICS["requestdl"].get("ok", 0) + 1
            _METRICS["last_requestdl_ok"] = time.time()
    except Exception:
        pass

def _bucket_refill_locked(now_mono):
    """Advance token count. Caller must hold _requestdl_bucket_lock. Pauses during cooldown."""
    global _requestdl_bucket_tokens, _requestdl_bucket_updated_mono
    if now_mono < _requestdl_cooldown_until_mono:
        _requestdl_bucket_updated_mono = now_mono
        return
    elapsed = now_mono - _requestdl_bucket_updated_mono
    if elapsed > 0:
        _requestdl_bucket_tokens = min(
            _REQUESTDL_BUCKET_CAPACITY,
            _requestdl_bucket_tokens + elapsed / _REQUESTDL_BUCKET_REFILL_S,
        )
        _requestdl_bucket_updated_mono = now_mono


def _bucket_parse_cooldown_hint(headers):
    """Extract Retry-After / x-ratelimit-after seconds as float, else None."""
    try:
        if not headers:
            return None
        # requests headers are case-insensitive; be defensive for dicts too.
        raw = None
        try:
            raw = headers.get("Retry-After", "") or headers.get("x-ratelimit-after", "")
        except Exception:
            raw = ""
        if not raw:
            try:
                for k, v in dict(headers).items():
                    if str(k).lower() in ("retry-after", "x-ratelimit-after"):
                        raw = v
                        break
            except Exception:
                pass
        hint = float(str(raw).strip())
        if hint > 0:
            return min(300.0, hint)
    except (TypeError, ValueError):
        pass
    return None


def _bucket_enter_cooldown(hint_s=None):
    """Pause refills: cooldown_until = now + hint (default 60s+jitter)."""
    global _requestdl_cooldown_until_mono, _requestdl_cooldown_until_wall, _requestdl_bucket_updated_mono
    now_mono = time.monotonic()
    now_wall = time.time()
    base = float(hint_s) if hint_s and hint_s > 0 else 60.0
    wait = base + random.uniform(0, 5.0)
    with _requestdl_bucket_lock:
        _requestdl_cooldown_until_mono = now_mono + wait
        _requestdl_cooldown_until_wall = now_wall + wait
        # Freeze refill clock so no tokens accrue during cooldown.
        _requestdl_bucket_updated_mono = now_mono
    return wait


def _bucket_in_cooldown():
    """Return remaining cooldown seconds (0 if none). Lock-protected, monotonic."""
    with _requestdl_bucket_lock:
        rem = _requestdl_cooldown_until_mono - time.monotonic()
        return rem if rem > 0 else 0.0


def _bucket_snapshot():
    """Current {tokens, cooldown_until} estimate for /metrics. Lock-protected."""
    now_mono = time.monotonic()
    with _requestdl_bucket_lock:
        _bucket_refill_locked(now_mono)
        tokens = float(_requestdl_bucket_tokens)
        mono_left = _requestdl_cooldown_until_mono - now_mono
        wall = float(_requestdl_cooldown_until_wall) if mono_left > 0 else 0.0
        remaining = round(mono_left, 1) if mono_left > 0 else 0.0
    return {"tokens": round(tokens, 2), "cooldown_until": wall, "cooldown_remaining_s": remaining,
            "capacity": int(_REQUESTDL_BUCKET_CAPACITY), "refill_s": float(_REQUESTDL_BUCKET_REFILL_S)}


def _bucket_try_acquire_background():
    """Fail-fast for background lane: needs tokens>=2, else False (stale-cache-or-None)."""
    global _requestdl_bucket_tokens
    now_mono = time.monotonic()
    with _requestdl_bucket_lock:
        if now_mono < _requestdl_cooldown_until_mono:
            return False
        _bucket_refill_locked(now_mono)
        if _requestdl_bucket_tokens < _REQUESTDL_BACKGROUND_MIN_TOKENS:
            return False
        _requestdl_bucket_tokens -= 1.0
        return True


def _bucket_acquire_interactive(timeout=_REQUESTDL_BUCKET_WAIT_S):
    """Interactive lane: wait up to 15s for 1 token. False on timeout/cooldown."""
    global _requestdl_bucket_tokens
    deadline = time.monotonic() + float(timeout)
    while True:
        now_mono = time.monotonic()
        with _requestdl_bucket_lock:
            if now_mono < _requestdl_cooldown_until_mono:
                return False
            _bucket_refill_locked(now_mono)
            if _requestdl_bucket_tokens >= 1.0:
                _requestdl_bucket_tokens -= 1.0
                return True
            needed = (1.0 - _requestdl_bucket_tokens) * _REQUESTDL_BUCKET_REFILL_S
        remaining = deadline - now_mono
        if remaining <= 0:
            return False
        # Short sleeps so a concurrent 429 cooldown is honoured promptly.
        time.sleep(min(max(needed, 0.05), remaining, 1.0))


def _bucket_get_stale(cache_key):
    """Return stale URL if age < CDN_STALE_FALLBACK_TTL, else None (no lock held on return)."""
    try:
        with _link_cache_lock:
            cached = _link_cache.get(cache_key)
        if cached and time.time() - cached["ts"] < CDN_STALE_FALLBACK_TTL:
            return cached["url"]
    except Exception:
        pass
    return None


def _link_cache_put(cache_key, entry, only_if_absent=False):
    """Bounded insert for _link_cache (per-entry {url,ts,ttl} unchanged).

    - Update in place when key exists (unless only_if_absent).
    - Else evict oldest-ts entry when at cap, then insert (O(n) scan only when over cap).
    - Caller must NOT hold _link_cache_lock (acquired here).
    """
    global _LINK_CACHE_EVICTIONS
    with _link_cache_lock:
        if cache_key in _link_cache:
            if only_if_absent:
                return False
            _link_cache[cache_key] = entry
            return True
        if len(_link_cache) >= _LINK_CACHE_CAP:
            try:
                oldest_key = min(_link_cache, key=lambda k: _link_cache[k].get("ts", 0))
                _link_cache.pop(oldest_key, None)
                _LINK_CACHE_EVICTIONS += 1
            except Exception:
                pass
        _link_cache[cache_key] = entry
        return True


def _link_cache_stats():
    """Snapshot {size,cap,evictions} for /metrics. Lock-protected."""
    with _link_cache_lock:
        return {"size": len(_link_cache), "cap": int(_LINK_CACHE_CAP), "evictions": int(_LINK_CACHE_EVICTIONS)}


def _metrics_snapshot():
    with _METRICS_LOCK:
        torbox = dict(_METRICS.get("torbox", {}))
        gdrive = dict(_METRICS.get("gdrive", {}))
        cdn_retry = dict(_METRICS.get("cdn_retry", {}))
        requestdl = dict(_METRICS.get("requestdl", {}))
        mylist = dict(_METRICS.get("mylist", {}))
        active = int(_METRICS.get("active_streams", 0))
        last_ok = float(_METRICS.get("last_requestdl_ok", 0.0) or 0.0)
    now = time.time()
    last_age = round(now - last_ok, 1) if last_ok > 0 else None
    for k in ("200", "2xx", "206", "416", "429", "502"):
        torbox.setdefault(k, 0)
    for k in ("200", "2xx", "206", "400", "403", "404", "416", "500"):
        gdrive.setdefault(k, 0)
    for k in ("429", "503", "403", "404", "410"):
        cdn_retry.setdefault(k, 0)
    for k in ("ok", "cached", "ratelimited", "failed"):
        requestdl.setdefault(k, 0)
    for k in ("fetches", "served"):
        mylist.setdefault(k, 0)
    requestdl["last_age_s"] = last_age
    try:
        requestdl["bucket"] = _bucket_snapshot()
    except Exception:
        requestdl["bucket"] = {"tokens": 0.0, "cooldown_until": 0.0}
    try:
        cache = _link_cache_stats()
    except Exception:
        cache = {"size": 0, "cap": int(_LINK_CACHE_CAP), "evictions": 0}
    return {
        "started_iso": _START_ISO,
        "uptime_s": round(now - _START_TIME, 1),
        "torbox": {"2xx": torbox["2xx"], "200": torbox["200"], "206": torbox["206"], "416": torbox["416"], "429": torbox["429"], "502": torbox["502"]},
        "gdrive": gdrive,
        "cdn_retry": cdn_retry,
        "requestdl": requestdl,
        "mylist": mylist,
        "cache": cache,
        "active_streams": active,
    }

def _sanitize_log(v, limit=200):
    """Strip CR/LF and truncate so Range/nice values cannot inject log lines."""
    try:
        s = str(v if v is not None else "")
    except Exception:
        return "-"
    s = s.replace("\r", " ").replace("\n", " ")
    if len(s) > limit:
        s = s[:limit] + "..."
    return s

def _effective_ttl(cdn_url, default=300):
    """Expires-aware TTL (trivial): cap cache TTL from ?expires=/exp= unix ts if present."""
    try:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(str(cdn_url)).query)
        for key in ("expires", "expire", "exp", "expiry"):
            vals = q.get(key)
            if vals and vals[0]:
                exp = int(float(vals[0]))
                ttl = exp - int(time.time()) - 10
                if ttl < 30:
                    return 30
                return min(default, ttl)
    except Exception:
        pass
    return default

def redact_url(url):
    """Keep expiring CDN tokens out of the local diagnostic log."""
    try:
        parsed = urllib.parse.urlparse(str(url))
        return parsed._replace(query="<redacted>" if parsed.query else "").geturl()
    except Exception:
        return "<cdn-url>"

def _mylist_get(allow_fetch=True):
    """Shared mylist read: TorBox hit with bypass_cache=true at most once per 600s.

    Returns (payload_dict_or_None, fetched_iso_str, age_s_or_None).
    - Fresh cache (age < 600s) serves immediately.
    - allow_fetch=False (?fresh=0): serve cache regardless of age, never fetch.
    - allow_fetch=True: stale/empty triggers singleflight fetch (15s wait for followers).
    - Fetch failure serves stale if available, else None. Never logs API key.
    """
    global _mylist_inflight
    with _mylist_cache_lock:
        payload = _mylist_cache.get("payload")
        ts = float(_mylist_cache.get("ts") or 0.0)
        iso = _mylist_cache.get("fetched_iso") or ""
    now = time.time()
    if payload is not None and ts > 0:
        age = now - ts
        if age < _MYLIST_TTL_S:
            return payload, iso, age
        if not allow_fetch:
            return payload, iso, age
    elif not allow_fetch:
        return None, "", None
    # Need fetch (or no cache + lightweight -> None already returned above).
    with _mylist_inflight_lock:
        if _mylist_inflight is not None:
            ev = _mylist_inflight
            is_leader = False
        else:
            ev = threading.Event()
            _mylist_inflight = ev
            is_leader = True
    if not is_leader:
        ev.wait(timeout=_MYLIST_SINGLEFLIGHT_WAIT_S)
        with _mylist_cache_lock:
            payload2 = _mylist_cache.get("payload")
            ts2 = float(_mylist_cache.get("ts") or 0.0)
            iso2 = _mylist_cache.get("fetched_iso") or ""
        if payload2 is not None and ts2 > 0:
            return payload2, iso2, time.time() - ts2
        if payload is not None and ts > 0:
            return payload, iso, time.time() - ts
        return None, "", None
    # Leader: re-check freshness (another fetch could have completed just before election).
    try:
        with _mylist_cache_lock:
            payload_c = _mylist_cache.get("payload")
            ts_c = float(_mylist_cache.get("ts") or 0.0)
            iso_c = _mylist_cache.get("fetched_iso") or ""
        if payload_c is not None and ts_c > 0 and (time.time() - ts_c) < _MYLIST_TTL_S:
            return payload_c, iso_c, time.time() - ts_c
        _m_inc("mylist", "fetches")
        try:
            headers = {"Authorization": f"Bearer {TORBOX_API_KEY}"}
            r = _SESSION.get(f"{TORBOX_API}/mylist?bypass_cache=true", headers=headers, timeout=_MYLIST_FETCH_TIMEOUT)
            j = r.json()
            if isinstance(j, dict):
                fetched_ts = time.time()
                fetched_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(fetched_ts))
                with _mylist_cache_lock:
                    _mylist_cache["payload"] = j
                    _mylist_cache["ts"] = fetched_ts
                    _mylist_cache["fetched_iso"] = fetched_iso
                return j, fetched_iso, 0.0
            log("mylist fetch: unexpected non-dict response")
        except Exception as e:
            # Never log URL/key; exception text only.
            log(f"mylist fail: {e}")
        with _mylist_cache_lock:
            payload_s = _mylist_cache.get("payload")
            ts_s = float(_mylist_cache.get("ts") or 0.0)
            iso_s = _mylist_cache.get("fetched_iso") or ""
        if payload_s is not None and ts_s > 0:
            return payload_s, iso_s, time.time() - ts_s
        return None, "", None
    finally:
        with _mylist_inflight_lock:
            _mylist_inflight = None
        ev.set()

def request_dl(torrent_id, file_id, force_refresh=False, lane="interactive"):
    """Resolve requestdl with token-bucket throttle + cooldown. Cache hits bypass bucket."""
    global _last_requestdl_at
    cache_key = (str(torrent_id), str(file_id))
    now = time.time()
    with _link_cache_lock:
        cached = _link_cache.get(cache_key)
    if not force_refresh and cached and now - cached["ts"] < cached.get("ttl", CDN_CACHE_TTL):
        _m_inc("requestdl", "cached")
        return cached["url"]
    # Keep pre-pop stale so force_refresh + bucket/cooldown can still serve stale-cache-or-None.
    stale_before = cached
    if force_refresh:
        with _link_cache_lock:
            _link_cache.pop(cache_key, None)

    # Singleflight election: first fetches, others wait on Event (15s) then read cache.
    with _inflight_lock:
        if cache_key in _inflight:
            ev = _inflight[cache_key]
            is_leader = False
        else:
            ev = threading.Event()
            _inflight[cache_key] = ev
            is_leader = True
    if not is_leader:
        ev.wait(timeout=15.0)
        with _link_cache_lock:
            cached = _link_cache.get(cache_key)
        if not cached:
            _m_inc("requestdl", "failed")
            return None
        # Read cache (fresh preferred, stale fallback acceptable so probes share 1 API call).
        age = time.time() - cached["ts"]
        ttl = cached.get("ttl", CDN_CACHE_TTL)
        if age < ttl or age < CDN_STALE_FALLBACK_TTL:
            _m_inc("requestdl", "cached")
            return cached["url"]
        _m_inc("requestdl", "failed")
        return None

    try:
        headers = {"Authorization": f"Bearer {TORBOX_API_KEY}"}
        # TorBox requires the API key as ?token= query param (header alone -> HTTP 422).
        url = f"{TORBOX_API}/requestdl?token={TORBOX_API_KEY}&torrent_id={torrent_id}&file_id={file_id}&zip=false"
        # PotPlayer may issue several requests while opening one file. Serialize
        # refreshes and enforce a small gap so a playlist cannot trip TorBox's
        # requestdl rate limit during startup.
        with _requestdl_lock:
            now = time.time()
            with _link_cache_lock:
                cached = _link_cache.get(cache_key)
            if not force_refresh and cached and now - cached["ts"] < cached.get("ttl", CDN_CACHE_TTL):
                _m_inc("requestdl", "cached")
                return cached["url"]
            saw_ratelimit = False
            bucket_blocked = False
            is_background = str(lane or "interactive").lower() == "background"
            for attempt in range(3):
                try:
                    # Token bucket: acquire before EVERY requestdl HTTP call (never for cache hits).
                    if is_background:
                        if not _bucket_try_acquire_background():
                            bucket_blocked = True
                            if _bucket_in_cooldown() > 0:
                                log(f"requestdl bucket cooldown, background fail-fast to stale {torrent_id}/{file_id}")
                            else:
                                log(f"requestdl bucket low (tokens<2), background fail-fast to stale {torrent_id}/{file_id}")
                            break
                    else:
                        if not _bucket_acquire_interactive(timeout=_REQUESTDL_BUCKET_WAIT_S):
                            bucket_blocked = True
                            if _bucket_in_cooldown() > 0:
                                log(f"requestdl bucket cooldown, interactive serves stale only {torrent_id}/{file_id}")
                            else:
                                log(f"requestdl bucket wait 15s timeout, serves stale only {torrent_id}/{file_id}")
                            break
                    gap = REQUESTDL_MIN_INTERVAL - (time.time() - _last_requestdl_at)
                    if gap > 0:
                        time.sleep(gap)
                    r = _SESSION.get(url, headers=headers, timeout=10)
                    _last_requestdl_at = time.time()
                    if r.status_code == 429:
                        saw_ratelimit = True
                        hint = _bucket_parse_cooldown_hint(r.headers)
                        wait = _bucket_enter_cooldown(hint)
                        log(f"requestdl rate-limited {torrent_id}/{file_id}, cooldown {wait:.1f}s (hint={hint})")
                        # During cooldown only stale-cache serves, never new API calls: no retry.
                        break
                    if r.status_code >= 400:
                        log(f"requestdl HTTP {r.status_code} {torrent_id}/{file_id}")
                        break
                    j = r.json()
                    if j.get("success") and j.get("data"):
                        value = str(j["data"])
                        ttl = _effective_ttl(value, CDN_CACHE_TTL)
                        _link_cache_put(cache_key, {"url": value, "ts": time.time(), "ttl": ttl})
                        _m_requestdl_ok()
                        return value
                    log(f"requestdl fail {torrent_id}/{file_id}: {j}")
                    break
                except Exception as e:
                    log(f"requestdl exception {torrent_id}/{file_id}: {e}")
                    if attempt < 2:
                        time.sleep(0.5)

            # A recently used CDN URL is better than turning a transient API 429
            # into a dead PotPlayer item. The next request after this window will
            # force a fresh API resolution.
            with _link_cache_lock:
                cached = _link_cache.get(cache_key)
            fallback_url = None
            if cached and time.time() - cached["ts"] < CDN_STALE_FALLBACK_TTL:
                fallback_url = cached["url"]
                fallback_age = int(time.time() - cached["ts"])
            elif stale_before and time.time() - stale_before.get("ts", 0) < CDN_STALE_FALLBACK_TTL:
                # force_refresh had popped the only stale copy; restore it for followers.
                fallback_url = stale_before["url"]
                fallback_age = int(time.time() - stale_before.get("ts", 0))
                try:
                    _link_cache_put(cache_key, stale_before, only_if_absent=True)
                except Exception:
                    pass
            if fallback_url:
                log(f"requestdl fallback to cached CDN {torrent_id}/{file_id} age={fallback_age}s")
                _m_inc("requestdl", "cached")
                return fallback_url
            if saw_ratelimit or (bucket_blocked and _bucket_in_cooldown() > 0):
                _m_inc("requestdl", "ratelimited")
            else:
                _m_inc("requestdl", "failed")
        return None
    finally:
        with _inflight_lock:
            _inflight.pop(cache_key, None)
        ev.set()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, format, *args):
        log("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), format%args))

    @staticmethod
    def _retry_delay(response, default=1.0):
        raw = response.headers.get("x-ratelimit-after") or response.headers.get("Retry-After") or ""
        try:
            # Cloudflare's hint is sometimes optimistic while several PotPlayer
            # range requests are draining. Leave a little breathing room.
            return min(20.0, max(5.0, float(raw)))
        except (TypeError, ValueError):
            return default

    @staticmethod
    def _jittered(delay, jitter=1.0):
        return delay + random.uniform(0, jitter)

    def proxy_torbox_stream(self, torrent_id, file_id, head_only=False):
        """Gauge wrapper: increment on entry, decrement in finally."""
        _m_active(1)
        try:
            return self._proxy_torbox_stream_impl(torrent_id, file_id, head_only=head_only)
        finally:
            _m_active(-1)

    def _proxy_torbox_stream_impl(self, torrent_id, file_id, head_only=False):
        """Resolve and stream TorBox bytes locally so CDN 429s never reach PotPlayer."""
        range_header = self.headers.get("Range")
        upstream_headers = {"User-Agent": "PotPlayer-Torbox-Proxy/1.0"}
        if range_header:
            upstream_headers["Range"] = range_header
        if self.headers.get("If-Range"):
            upstream_headers["If-Range"] = self.headers.get("If-Range")

        deadline = time.monotonic() + 12.0  # cap per-GET ~12s
        refreshed_for_auth = False
        force_next = False

        for attempt in range(5):
            if time.monotonic() >= deadline:
                break
            # CDN 429/503 is CDN-side throttle — retry the same link first.
            # Only force a fresh requestdl after 2 failures to avoid burning
            # TorBox API quota (Essential plan rate-limits aggressively).
            # 403/410 get a single forced refresh (force_next); 404 fail-fast.
            need_refresh = force_next or (attempt >= 2)
            force_next = False
            cdn = request_dl(torrent_id, file_id, force_refresh=need_refresh, lane="interactive")
            if not cdn:
                break
            response = None
            try:
                if head_only:
                    response = _SESSION.head(cdn, headers=upstream_headers, timeout=(10, 20), allow_redirects=True)
                else:
                    response = _SESSION.get(cdn, headers=upstream_headers, timeout=(10, 20), stream=True, allow_redirects=True)
            except Timeout as exc:
                log(f"Torbox CDN timeout {torrent_id}/{file_id} attempt={attempt + 1}: {exc}")
                if attempt < 4 and time.monotonic() < deadline:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    time.sleep(min(self._jittered(1.0 + attempt, 1.0), remaining))
                    continue
                break
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError) as exc:
                msg = str(exc)
                if "10053" in msg or "10054" in msg or "forcibly closed" in msg or "aborted" in msg.lower():
                    return True
                log(f"Torbox stream error {torrent_id}/{file_id} attempt={attempt + 1}: {exc}")
                break
            except Exception as exc:
                msg = str(exc)
                if isinstance(exc, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)) or "10053" in msg or "10054" in msg or "forcibly closed" in msg or "aborted" in msg.lower():
                    return True
                log(f"Torbox stream error {torrent_id}/{file_id} attempt={attempt + 1}: {exc}")
                break

            try:
                # Forward upstream 416 (Range Not Satisfiable) with Content-Range, not 502.
                if response.status_code == 416:
                    _m_inc("torbox", 416)
                    try:
                        self.send_response(416)
                        cr = response.headers.get("Content-Range")
                        if cr:
                            self.send_header("Content-Range", cr)
                        ar = response.headers.get("Accept-Ranges")
                        if ar:
                            self.send_header("Accept-Ranges", ar)
                        self.send_header("X-Torbox-Proxy", "stream")
                        self.end_headers()
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                        return True
                    finally:
                        try:
                            response.close()
                        except Exception:
                            pass
                    return True
                if response.status_code in (429, 503):
                    _m_inc("cdn_retry", response.status_code)
                if response.status_code in (429, 503) and attempt < 4:
                    delay = self._jittered(self._retry_delay(response, default=5.0 if response.status_code == 429 else 1.0), 1.0)
                    log(f"Torbox CDN status={response.status_code} {torrent_id}/{file_id}; retry {attempt + 1}/5 in {delay:g}s")
                    try:
                        response.close()
                    except Exception:
                        pass
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    time.sleep(min(delay, remaining))
                    continue
                if response.status_code in (403, 410):
                    _m_inc("cdn_retry", response.status_code)
                    try:
                        response.close()
                    except Exception:
                        pass
                    # Single refresh only: one fresh requestdl then one retry.
                    if not refreshed_for_auth and attempt < 4 and time.monotonic() < deadline:
                        refreshed_for_auth = True
                        force_next = True
                        log(f"Torbox CDN status={response.status_code} {torrent_id}/{file_id}; single refresh retry")
                        continue
                    log(f"Torbox CDN status={response.status_code} {torrent_id}/{file_id} (no further refresh)")
                    break
                if response.status_code == 404:
                    _m_inc("cdn_retry", 404)
                    log(f"Torbox CDN status=404 {torrent_id}/{file_id} fail-fast")
                    try:
                        response.close()
                    except Exception:
                        pass
                    break
                if response.status_code >= 400:
                    log(f"Torbox CDN status={response.status_code} {torrent_id}/{file_id}")
                    try:
                        response.close()
                    except Exception:
                        pass
                    break

                try:
                    self.send_response(response.status_code)
                    _m_inc("torbox", response.status_code)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                    try:
                        response.close()
                    except Exception:
                        pass
                    return True
                forwarded = {
                    "content-length", "content-type", "content-range", "accept-ranges",
                    "last-modified", "etag", "cache-control", "content-disposition"
                }
                for key, value in response.headers.items():
                    if key.lower() in forwarded:
                        self.send_header(key, value)
                self.send_header("X-Torbox-Proxy", "stream")
                self.send_header("Cache-Control", "no-cache")
                try:
                    self.end_headers()
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                    try:
                        response.close()
                    except Exception:
                        pass
                    return True

                if not head_only:
                    try:
                        for chunk in response.iter_content(chunk_size=64 * 1024):
                            if not chunk:
                                continue
                            try:
                                self.wfile.write(chunk)
                                self.wfile.flush()
                            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                                # Client (PotPlayer) disconnect during body: quiet, no retry/502.
                                try:
                                    response.close()
                                except Exception:
                                    pass
                                return True
                    except Timeout as exc:
                        try:
                            response.close()
                        except Exception:
                            pass
                        log(f"Torbox stream error {torrent_id}/{file_id} attempt={attempt + 1}: {exc}")
                        if attempt < 4 and time.monotonic() < deadline:
                            remaining = deadline - time.monotonic()
                            if remaining <= 0:
                                break
                            time.sleep(min(self._jittered(1.0, 1.0), remaining))
                            continue
                        break
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError) as exc:
                        msg = str(exc)
                        if "10053" in msg or "10054" in msg or "forcibly closed" in msg or "aborted" in msg.lower():
                            try:
                                response.close()
                            except Exception:
                                pass
                            return True
                        try:
                            response.close()
                        except Exception:
                            pass
                        log(f"Torbox stream error {torrent_id}/{file_id} attempt={attempt + 1}: {exc}")
                        break
                    except Exception as exc:
                        msg = str(exc)
                        if "10053" in msg or "10054" in msg or "forcibly closed" in msg or "aborted" in msg.lower():
                            try:
                                response.close()
                            except Exception:
                                pass
                            return True
                        try:
                            response.close()
                        except Exception:
                            pass
                        # Retry+jitter ONLY on timeout; other upstream body errors fail to 502.
                        if isinstance(exc, Timeout) or "timeout" in msg.lower() or "timed out" in msg.lower():
                            log(f"Torbox stream error {torrent_id}/{file_id} attempt={attempt + 1}: {exc}")
                            if attempt < 4 and time.monotonic() < deadline:
                                remaining = deadline - time.monotonic()
                                if remaining <= 0:
                                    break
                                time.sleep(min(self._jittered(1.0, 1.0), remaining))
                                continue
                        log(f"Torbox stream error {torrent_id}/{file_id} attempt={attempt + 1}: {exc}")
                        break
                    try:
                        response.close()
                    except Exception:
                        pass
                    return True
                try:
                    response.close()
                except Exception:
                    pass
                return True
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError) as exc:
                msg = str(exc)
                if "10053" in msg or "10054" in msg or "forcibly closed" in msg or "aborted" in msg.lower():
                    try:
                        if response is not None:
                            response.close()
                    except Exception:
                        pass
                    return True
                log(f"Torbox stream error {torrent_id}/{file_id} attempt={attempt + 1}: {exc}")
                break
            except Exception as exc:
                if response is not None:
                    try:
                        response.close()
                    except Exception:
                        pass
                msg = str(exc)
                if isinstance(exc, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)) or "10053" in msg or "10054" in msg or "forcibly closed" in msg or "aborted" in msg.lower():
                    return True
                log(f"Torbox stream error {torrent_id}/{file_id} attempt={attempt + 1}: {exc}")
                break

        try:
            _m_inc("torbox", 502)
            self.send_error(502, "Torbox CDN unavailable after retries")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            pass
        return False

    def do_HEAD(self):
        self.handle_proxy(head_only=True)

    def do_GET(self):
        self.handle_proxy(head_only=False)

    def handle_proxy(self, head_only=False):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        path = parsed.path

        # Health
        if path in ("/", "/health"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            try:
                self.wfile.write(b"Torbox Proxy Ready 127.0.0.1:8888")
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                pass
            return

        # Logs endpoint for UX (real-time what happening) — localhost only, no CORS.
        if path == "/logs":
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                self.send_error(403, "logs restricted to localhost")
                return
            # Require no cross-origin: reject browser cross-site fetches.
            origin = self.headers.get("Origin") or self.headers.get("Referer") or ""
            if origin:
                try:
                    ohost = urllib.parse.urlparse(origin).hostname or ""
                except Exception:
                    ohost = origin
                if ohost not in ("127.0.0.1", "localhost", "::1", ""):
                    self.send_error(403, "logs restricted to same-origin")
                    return
            try:
                with open(LOG_FILE, "r", encoding="utf-8") as f:
                    data = f.read()[-20000:]
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                try:
                    self.wfile.write(data.encode("utf-8"))
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                    pass
            except:
                self.send_response(200)
                self.end_headers()
                try:
                    self.wfile.write(b"no logs")
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                    pass
            return

        # Metrics endpoint for panel (replaces 5000-line log scans) — localhost only, no CORS.
        if path == "/metrics":
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                self.send_error(403, "metrics restricted to localhost")
                return
            origin = self.headers.get("Origin") or self.headers.get("Referer") or ""
            if origin:
                try:
                    ohost = urllib.parse.urlparse(origin).hostname or ""
                except Exception:
                    ohost = origin
                if ohost not in ("127.0.0.1", "localhost", "::1", ""):
                    self.send_error(403, "metrics restricted to same-origin")
                    return
            try:
                payload = json.dumps(_metrics_snapshot()).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                if not head_only:
                    try:
                        self.wfile.write(payload)
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                        pass
            except Exception as e:
                log(f"metrics fail: {e}")
                try:
                    self.send_error(500, "metrics failed")
                except Exception:
                    pass
            return

        # Shared mylist endpoint — localhost only, same-origin check like /logs, no CORS.
        # GET /mylist            -> serve fresh cache; if age >= 600s, singleflight fetch
        #                         TorBox mylist?bypass_cache=true (at most once per 600s),
        #                         then serve {fetched_iso, age_s, payload}.
        # GET /mylist?fresh=0    -> lightweight: serve cache regardless of age (even stale),
        #                         never triggers a TorBox fetch (503 if cache empty).
        if path == "/mylist":
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                self.send_error(403, "mylist restricted to localhost")
                return
            origin = self.headers.get("Origin") or self.headers.get("Referer") or ""
            if origin:
                try:
                    ohost = urllib.parse.urlparse(origin).hostname or ""
                except Exception:
                    ohost = origin
                if ohost not in ("127.0.0.1", "localhost", "::1", ""):
                    self.send_error(403, "mylist restricted to same-origin")
                    return
            try:
                fresh_vals = qs.get("fresh", [])
                lightweight = bool(fresh_vals) and str(fresh_vals[0]).strip() == "0"
                payload, fetched_iso, age = _mylist_get(allow_fetch=not lightweight)
                if payload is None:
                    try:
                        err = json.dumps({"error": "mylist cache empty, retry shortly"}).encode("utf-8")
                        self.send_response(503)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(err)))
                        self.end_headers()
                        if not head_only:
                            try:
                                self.wfile.write(err)
                            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                                pass
                    except Exception:
                        pass
                    return
                # Top-level "data" alias: consumers (launcher/sync) look for
                # data|torrents at top level and cannot see inside "payload".
                data_alias = payload.get("data") if isinstance(payload, dict) else None
                body = json.dumps({
                    "fetched_iso": fetched_iso,
                    "age_s": round(float(age or 0.0), 1),
                    "data": data_alias,
                    "payload": payload,
                }).encode("utf-8")
                _m_inc("mylist", "served")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if not head_only:
                    try:
                        self.wfile.write(body)
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                        pass
            except Exception as e:
                log(f"mylist serve fail: {e}")
                try:
                    self.send_error(500, "mylist failed")
                except Exception:
                    pass
            return

        # Torbox: /torbox/<tid>/<fid>/<nice>
        if path.startswith("/torbox/"):
            parts = path.strip("/").split("/")
            if len(parts) >= 3:
                _, tid, fid = parts[0], parts[1], parts[2]
                nice = "/".join(parts[3:]) if len(parts) > 3 else f"{fid}.mkv"
                if not tid.isdigit() or not fid.isdigit():
                    log(f"Rejected malformed torbox URL {tid}/{fid}; numeric torrent/file ids required")
                    self.send_error(400, "Torbox path requires numeric torrent_id/file_id")
                    return
                log(f"Proxy torbox {tid}/{fid} {_sanitize_log(nice)} Range:{_sanitize_log(self.headers.get('Range'))} Head:{head_only}")
                self.proxy_torbox_stream(tid, fid, head_only=head_only)
                return
            self.send_error(404, "torbox path need /torbox/<tid>/<fid>/name")
            return

        # GDrive: /gdrive/<path> -> serves F:\Media\... or G:\... via HTTP Range (so PotPlayer shows bar for GDrive too, not just Torbox)
        if path.startswith("/gdrive/"):
            gpath = urllib.parse.unquote(path[len("/gdrive/"):]).replace("/", "\\")
            # Containment + media-extension gate.
            ext = os.path.splitext(gpath)[1].lower()
            if ext not in MEDIA_EXTS:
                _m_inc("gdrive", 403)
                self.send_error(403, "gdrive media type not allowed")
                return
            allowed_bases = [os.path.abspath(r"G:\\"), os.path.abspath(r"F:\Media")]
            candidate = None
            candidate_base = None
            for base in allowed_bases:
                fpath = os.path.normpath(os.path.join(base, gpath))
                try:
                    fpath_abs = os.path.abspath(fpath)
                except Exception:
                    continue
                try:
                    if os.path.commonpath([base, fpath_abs]) != base:
                        continue
                except Exception:
                    continue
                candidate = fpath_abs
                candidate_base = base
                # Only serve from the first base whose contained path exists; else keep checking.
                if os.path.exists(candidate) and os.path.isfile(candidate):
                    break
            if candidate is None:
                _m_inc("gdrive", 403)
                self.send_error(403, "gdrive path not allowed")
                return
            fpath = candidate
            if os.path.exists(fpath) and os.path.isfile(fpath):
                try:
                    # Re-verify containment on the resolved absolute path.
                    try:
                        if os.path.commonpath([candidate_base, os.path.abspath(fpath)]) != candidate_base:
                            _m_inc("gdrive", 403)
                            self.send_error(403, "gdrive path not allowed")
                            return
                    except Exception:
                        _m_inc("gdrive", 403)
                        self.send_error(403, "gdrive path not allowed")
                        return
                    fsize = os.path.getsize(fpath)
                    range_hdr = self.headers.get('Range')
                    start, end = 0, fsize - 1
                    status = 200
                    if range_hdr:
                        # Range: bytes=0-1023 or bytes=1024-
                        try:
                            r = range_hdr.strip().split("=")[1].split("-")
                            start = int(r[0]) if r[0] else 0
                            if r[1]: end = int(r[1])
                            else: end = fsize - 1
                            if start >= fsize:
                                _m_inc("gdrive", 416)
                                self.send_error(416, "Range Not Satisfiable")
                                return
                            status = 206
                        except: pass
                    length = end - start + 1
                    log(f"Proxy gdrive {_sanitize_log(gpath)} {start}-{end}/{fsize} Head:{head_only}")
                    self.send_response(status)
                    _m_inc("gdrive", status)
                    self.send_header("Content-Type", "video/x-matroska" if fpath.lower().endswith(".mkv") else "video/mp4" if fpath.lower().endswith(".mp4") else "application/octet-stream")
                    self.send_header("Content-Length", str(length if not head_only else fsize))
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("X-GDrive-Proxy", "direct")
                    if status == 206:
                        self.send_header("Content-Range", f"bytes {start}-{end}/{fsize}")
                    self.end_headers()
                    if head_only:
                        return
                    # Stream file
                    with open(fpath, "rb") as fh:
                        fh.seek(start)
                        remaining = length
                        chunk = 1024*256
                        while remaining > 0:
                            read_len = min(chunk, remaining)
                            data = fh.read(read_len)
                            if not data: break
                            try:
                                self.wfile.write(data)
                            except BrokenPipeError:
                                break
                            remaining -= len(data)
                    log(f"Served gdrive {_sanitize_log(gpath)} {length} bytes")
                    return
                except Exception as e:
                    log(f"gdrive serve fail {_sanitize_log(fpath)}: {e}")
                    _m_inc("gdrive", 500)
                    self.send_error(500, str(e))
                    return
            _m_inc("gdrive", 404)
            self.send_error(404, f"gdrive file not found: {_sanitize_log(gpath)} (tried G:\\ and F:\\Media\\)")
            return

        # Fallback: try to serve via rclone WebDAV for F:\Media / T:\ when Torbox not used (GDrive)
        self.send_error(404, "unknown path, use /torbox/<tid>/<fid>/name, /gdrive/<path> or /health")

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

def run():
    server_address = ("127.0.0.1", PORT)
    httpd = http.server.ThreadingHTTPServer(server_address, Handler)
    log(f"Torbox Proxy listening on http://127.0.0.1:{PORT} (torbox + gdrive, local Range streaming, CDN retry/backoff)")
    log(f"Health: http://127.0.0.1:{PORT}/health Logs: http://127.0.0.1:{PORT}/logs")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    # ensure log dir
    Path(LOG_FILE).parent.mkdir(parents=True, exist_ok=True)
    run()
