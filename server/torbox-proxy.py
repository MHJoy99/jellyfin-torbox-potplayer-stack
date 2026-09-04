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
import http.server, urllib.parse, urllib.request, json, os, threading, time, sys, random, socket
from pathlib import Path
import requests
from requests.adapters import HTTPAdapter
from requests.exceptions import Timeout

# NOTE: HTTP/1.0 must stay (protocol_version = "HTTP/1.0" below).
# HTTP/1.1 hangs on missing Content-Length with PotPlayer; do not upgrade.
# NOTE: TorBox API requires ?token= query auth (header-only gives HTTP 422).
# NOTE: API key comes ONLY from $env:TORBOX_API_KEY (never hardcode secrets).

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

# --- 10x tunables (all via env, safe defaults) ---
def _parse_env_int(name, default, lo, hi):
    try:
        raw = os.environ.get(name, "")
        if raw is None or str(raw).strip() == "":
            return int(default)
        v = int(float(str(raw).strip()))
        return max(int(lo), min(int(hi), v))
    except Exception:
        return int(default)

def _parse_env_float(name, default, lo, hi):
    try:
        raw = os.environ.get(name, "")
        if raw is None or str(raw).strip() == "":
            return float(default)
        v = float(str(raw).strip())
        return max(float(lo), min(float(hi), v))
    except Exception:
        return float(default)

# 3) Configurable stream chunk size via PROXY_CHUNK_KB env (default 64).
PROXY_CHUNK_KB = _parse_env_int("PROXY_CHUNK_KB", 64, 4, 4096)
# 4) Slow-client write timeout (seconds) with quiet close.
PROXY_WRITE_TIMEOUT_S = _parse_env_float("PROXY_WRITE_TIMEOUT_S", 20.0, 1.0, 300.0)
# 5) Per-IP concurrent-stream cap (streams only, not health/metrics).
PROXY_MAX_CONCURRENT_PER_IP = _parse_env_int("PROXY_MAX_CONCURRENT_PER_IP", 8, 1, 128)
PROXY_CONCURRENT_RETRY_AFTER_S = _parse_env_int("PROXY_RETRY_AFTER_S", 5, 1, 120)
# 7) Structured JSON access log sampling: 1.0 = log all, 0.1 = 10%, 0.0 = off.
PROXY_LOG_SAMPLE = _parse_env_float("PROXY_LOG_SAMPLE", 1.0, 0.0, 1.0)
# 6) Graceful drain: file whose content "1" means drain (plus $env:DRAIN=="1").
DRAIN_FILE = (os.environ.get("DRAIN_FILE") or "").strip() or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "DRAIN")

def _get_chunk_bytes():
    """Resolve stream chunk bytes from PROXY_CHUNK_KB env (default 64KB)."""
    try:
        kb = _parse_env_int("PROXY_CHUNK_KB", PROXY_CHUNK_KB, 4, 4096)
        return int(kb) * 1024
    except Exception:
        return 64 * 1024

def _get_write_timeout():
    """Resolve slow-client write timeout seconds."""
    try:
        return float(_parse_env_float("PROXY_WRITE_TIMEOUT_S", PROXY_WRITE_TIMEOUT_S, 1.0, 300.0))
    except Exception:
        return 20.0

def _get_max_per_ip():
    try:
        return int(_parse_env_int("PROXY_MAX_CONCURRENT_PER_IP", PROXY_MAX_CONCURRENT_PER_IP, 1, 128))
    except Exception:
        return 8

def _get_log_sample():
    try:
        return float(_parse_env_float("PROXY_LOG_SAMPLE", PROXY_LOG_SAMPLE, 0.0, 1.0))
    except Exception:
        return 1.0

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
    "concurrency": {"rejected": 0, "drained": 0},
    "active_streams": 0,
    "last_requestdl_ok": 0.0,
}

# --- 2) Per-endpoint latency histogram (for GET /metrics) ---
_LATENCY_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
_LATENCY = {}
_LATENCY_LOCK = threading.Lock()

# --- 5) Per-IP concurrent-stream slots ---
_STREAM_SLOTS = {}
_STREAM_SLOTS_LOCK = threading.Lock()

# --- 8) Adjacent-Range-request coalescing state ---
_RANGE_COALESCE_WINDOW_S = 5.0
_RANGE_LAST = {}
_RANGE_LAST_LOCK = threading.Lock()
_RANGE_COALESCED = 0
_RANGE_COALESCED_LOCK = threading.Lock()

# --- 10) Per-key cache hit counters for GET /cache top keys ---
_LINK_CACHE_HITS = {}
_LINK_CACHE_HITS_LOCK = threading.Lock()

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

# ================= 10x helpers =================
def _latency_endpoint_for_path(path):
    try:
        p = str(path or "/").split("?")[0]
        if p in ("/", "/health"):
            return "health"
        if p == "/ready" or p.startswith("/ready"):
            return "ready"
        if p == "/metrics" or p.startswith("/metrics"):
            return "metrics"
        if p == "/logs" or p.startswith("/logs"):
            return "logs"
        if p == "/mylist" or p.startswith("/mylist"):
            return "mylist"
        if p == "/cache" or p.startswith("/cache"):
            return "cache"
        if p.startswith("/torbox/"):
            return "torbox"
        if p.startswith("/gdrive/"):
            return "gdrive"
        return "other"
    except Exception:
        return "other"

def _observe_latency(endpoint, elapsed_s):
    """2) Record per-endpoint latency into histogram buckets (thread-safe)."""
    try:
        ep = str(endpoint or "other")
        el = float(elapsed_s or 0.0)
        if el < 0:
            el = 0.0
        with _LATENCY_LOCK:
            ent = _LATENCY.get(ep)
            if ent is None:
                ent = {"count": 0, "sum": 0.0, "buckets": {str(b): 0 for b in _LATENCY_BUCKETS}, "inf": 0}
                _LATENCY[ep] = ent
            ent["count"] += 1
            ent["sum"] += el
            placed = False
            for b in _LATENCY_BUCKETS:
                if el <= b:
                    ent["buckets"][str(b)] += 1
                    placed = True
                    break
            if not placed:
                ent["inf"] += 1
    except Exception:
        pass

def _latency_snapshot():
    """Return per-endpoint {count, sum_s, avg_s, buckets, inf} for /metrics."""
    try:
        with _LATENCY_LOCK:
            out = {}
            for ep, ent in _LATENCY.items():
                try:
                    cnt = int(ent.get("count", 0))
                    s = float(ent.get("sum", 0.0))
                    avg = round(s / cnt, 6) if cnt > 0 else 0.0
                    out[str(ep)] = {
                        "count": cnt,
                        "sum_s": round(s, 6),
                        "avg_s": avg,
                        "buckets": dict(ent.get("buckets", {})),
                        "inf": int(ent.get("inf", 0)),
                        "bucket_edges_s": list(_LATENCY_BUCKETS),
                    }
                except Exception:
                    continue
            return out
    except Exception:
        return {}

def _is_draining():
    """6) Graceful drain: True if $env:DRAIN==1 or DRAIN_FILE content is '1'."""
    try:
        if str(os.environ.get("DRAIN", "")).strip() == "1":
            return True
    except Exception:
        pass
    candidates = []
    try:
        candidates.append(DRAIN_FILE)
    except Exception:
        pass
    try:
        candidates.append(os.path.join(os.getcwd(), "DRAIN"))
    except Exception:
        pass
    for cand in candidates:
        try:
            if cand and os.path.isfile(cand):
                with open(cand, "r", encoding="utf-8", errors="ignore") as f:
                    if f.read().strip() == "1":
                        return True
        except Exception:
            continue
    return False

def _try_acquire_stream_slot(ip):
    """5) Per-IP concurrent-stream cap. Returns True if slot granted."""
    try:
        cap = _get_max_per_ip()
        key = str(ip or "unknown")
        with _STREAM_SLOTS_LOCK:
            cur = int(_STREAM_SLOTS.get(key, 0))
            if cur >= cap:
                return False
            _STREAM_SLOTS[key] = cur + 1
            return True
    except Exception:
        return True

def _release_stream_slot(ip):
    try:
        key = str(ip or "unknown")
        with _STREAM_SLOTS_LOCK:
            cur = int(_STREAM_SLOTS.get(key, 0))
            if cur <= 1:
                _STREAM_SLOTS.pop(key, None)
            else:
                _STREAM_SLOTS[key] = cur - 1
    except Exception:
        pass

def _stream_slots_snapshot():
    try:
        with _STREAM_SLOTS_LOCK:
            return dict(_STREAM_SLOTS)
    except Exception:
        return {}

def _parse_range_header(value):
    """8) Parse 'bytes=START-END' / 'bytes=START-' -> (start, end_or_None). None if invalid/suffix."""
    try:
        if not value:
            return None
        v = str(value).strip()
        if "=" in v:
            unit, _, spec = v.partition("=")
            if unit.strip().lower() != "bytes":
                return None
            v = spec.strip()
        # Only single-range supported for coalescing; multi-range -> None.
        if "," in v:
            return None
        if v.startswith("-"):
            return None
        start_s, sep, end_s = v.partition("-")
        if not sep:
            return None
        start_s = start_s.strip()
        end_s = end_s.strip()
        if not start_s.isdigit():
            return None
        start = int(start_s)
        if end_s == "":
            return None if start < 0 else (start, None)
        if not end_s.isdigit():
            return None
        end = int(end_s)
        if end < start:
            return None
        return (start, end)
    except Exception:
        return None

def _note_range_and_check_coalesced(tid, fid, range_header):
    """8) Adjacent-Range-request coalescing tracker.

    If this Range start == previous end+1 (or previous open-ended start<=new start
    within window), count as coalesced (upstream requestdl cache reused, no fresh
    API call). Returns True when coalesced.
    """
    try:
        parsed = _parse_range_header(range_header)
        if parsed is None:
            return False
        new_start, new_end = parsed
        key = (str(tid), str(fid))
        now_m = time.monotonic()
        coalesced = False
        with _RANGE_LAST_LOCK:
            prev = _RANGE_LAST.get(key)
            if prev is not None:
                prev_start, prev_end, prev_ts = prev
                age = now_m - float(prev_ts or 0.0)
                if age <= _RANGE_COALESCE_WINDOW_S:
                    try:
                        if prev_end is None:
                            # Previous was open-ended; any forward-adjacent counts.
                            if int(new_start) >= int(prev_start):
                                coalesced = True
                        else:
                            if int(new_start) == int(prev_end) + 1:
                                coalesced = True
                    except Exception:
                        pass
            _RANGE_LAST[key] = (new_start, new_end, now_m)
        if coalesced:
            try:
                with _RANGE_COALESCED_LOCK:
                    global _RANGE_COALESCED
                    _RANGE_COALESCED += 1
            except Exception:
                pass
        return coalesced
    except Exception:
        return False

def _range_coalescing_snapshot():
    try:
        with _RANGE_COALESCED_LOCK:
            c = int(_RANGE_COALESCED)
    except Exception:
        c = 0
    try:
        with _RANGE_LAST_LOCK:
            tracked = len(_RANGE_LAST)
    except Exception:
        tracked = 0
    return {"coalesced": c, "tracked_keys": tracked, "window_s": float(_RANGE_COALESCE_WINDOW_S)}

def _link_cache_record_hit(cache_key):
    try:
        k = f"{cache_key[0]}/{cache_key[1]}" if isinstance(cache_key, tuple) and len(cache_key) == 2 else str(cache_key)
        with _LINK_CACHE_HITS_LOCK:
            _LINK_CACHE_HITS[k] = int(_LINK_CACHE_HITS.get(k, 0)) + 1
    except Exception:
        pass

def _link_cache_hit_ratio():
    try:
        with _METRICS_LOCK:
            rd = dict(_METRICS.get("requestdl", {}))
        hits = int(rd.get("cached", 0))
        total = int(rd.get("cached", 0)) + int(rd.get("ok", 0)) + int(rd.get("failed", 0)) + int(rd.get("ratelimited", 0))
        if total <= 0:
            return 0.0
        return round(hits / total, 4)
    except Exception:
        return 0.0

def _cache_top_keys(limit=10):
    try:
        with _LINK_CACHE_HITS_LOCK:
            items = list(_LINK_CACHE_HITS.items())
    except Exception:
        items = []
    try:
        items.sort(key=lambda kv: int(kv[1]), reverse=True)
    except Exception:
        pass
    out = []
    now = time.time()
    for k, hits in items[: int(limit)]:
        try:
            tid_s, _, fid_s = str(k).partition("/")
            age_s = None
            ttl = None
            redacted = "-"
            try:
                with _link_cache_lock:
                    ent = _link_cache.get((tid_s, fid_s))
                if ent is not None:
                    age_s = round(now - float(ent.get("ts", now)), 1)
                    ttl = int(ent.get("ttl", CDN_CACHE_TTL))
                    try:
                        redacted = redact_url(ent.get("url", ""))
                        # Keep only host to avoid any token residue.
                        redacted = urllib.parse.urlparse(str(ent.get("url", ""))).hostname or redacted
                    except Exception:
                        redacted = "<cdn>"
            except Exception:
                pass
            out.append({"key": str(k), "hits": int(hits), "age_s": age_s, "ttl_s": ttl, "cdn_host": redacted})
        except Exception:
            continue
    return out

def _cache_purge(purge_val):
    """10) Purge one key ('tid/fid', 'tid:fid', 'tid-fid') or all ('all'/'*'). Returns purged list."""
    purged = []
    try:
        v = str(purge_val or "").strip()
        if not v:
            return purged
        if v.lower() in ("all", "*", "1"):
            with _link_cache_lock:
                keys = list(_link_cache.keys())
                _link_cache.clear()
            for kk in keys:
                try:
                    if isinstance(kk, tuple) and len(kk) == 2:
                        purged.append(f"{kk[0]}/{kk[1]}")
                    else:
                        purged.append(str(kk))
                except Exception:
                    continue
            return purged
        norm = v.replace(":", "/").replace("-", "/").replace(",", "/").replace(" ", "")
        # Allow "tid/fid" possibly with extra slashes; take first two numeric parts.
        parts = [p for p in norm.split("/") if p != ""]
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            key = (parts[0], parts[1])
            with _link_cache_lock:
                if key in _link_cache:
                    _link_cache.pop(key, None)
                    purged.append(f"{key[0]}/{key[1]}")
            # Also drop its hit counter so top_keys reflects purge.
            try:
                with _LINK_CACHE_HITS_LOCK:
                    _LINK_CACHE_HITS.pop(f"{key[0]}/{key[1]}", None)
            except Exception:
                pass
            # Drop coalescing tracker for that key too.
            try:
                with _RANGE_LAST_LOCK:
                    _RANGE_LAST.pop(key, None)
            except Exception:
                pass
        return purged
    except Exception:
        return purged

def _access_log(record):
    """7) Structured JSON access log with PROXY_LOG_SAMPLE sampling."""
    try:
        sample = _get_log_sample()
        if sample <= 0.0:
            return
        if sample < 1.0:
            try:
                if random.random() >= sample:
                    return
            except Exception:
                pass
        try:
            line = json.dumps(record, separators=(",", ":"), ensure_ascii=False)
        except Exception:
            return
        # Reuse text log (stdout + file) so no new sink needed.
        log(f"access {line}")
    except Exception:
        pass

def _check_port_bound(host="127.0.0.1", port=8888, timeout=1.0):
    """Return True if TCP connect to host:port succeeds (port bound)."""
    s = None
    try:
        s = socket.create_connection((host, int(port)), timeout=float(timeout))
        return True
    except Exception:
        return False
    finally:
        try:
            if s is not None:
                s.close()
        except Exception:
            pass

def _check_torbox_reachable(timeout=5.0):
    """Deep-check TorBox reachability using ?token= query auth (header-only gives 422).

    Any HTTP response (even 4xx/5xx) counts as reachable; only exception/timeout = unreachable.
    Returns (reachable_bool, detail_str).
    """
    try:
        key = (os.environ.get("TORBOX_API_KEY") or "").strip()
        if not key:
            return False, "no-key"
        # Lightweight endpoint; token in query per TorBox requirement.
        url = f"{TORBOX_API}/mylist?token={key}&bypass_cache=false"
        try:
            r = _SESSION.get(url, headers={"Authorization": f"Bearer {key}"}, timeout=float(timeout))
            return True, f"http-{int(r.status_code)}"
        except Timeout as e:
            return False, f"timeout:{e}"
        except Exception as e:
            return False, f"error:{type(e).__name__}"
    except Exception as e:
        return False, f"error:{e}"

def _startup_self_check():
    """9) Startup self-check (bind, env key, fail fast with clear message)."""
    # Key check (mirrors import-time guard but with actionable message).
    key = (os.environ.get("TORBOX_API_KEY") or "").strip()
    if not key:
        print("FATAL: TORBOX_API_KEY env var is empty; refusing to start (set $env:TORBOX_API_KEY)", file=sys.stderr)
        print("HINT: $env:TORBOX_API_KEY = '<your-torbox-api-key>'  (PowerShell, same session that runs the proxy)", file=sys.stderr)
        sys.exit(2)
    # Tunables sanity (fail fast on garbage, not silent clamp surprise).
    try:
        _ = _get_chunk_bytes()
        _ = _get_write_timeout()
        _ = _get_max_per_ip()
        _ = _get_log_sample()
    except Exception as e:
        print(f"FATAL: invalid proxy tuning env: {e}", file=sys.stderr)
        sys.exit(2)
    # Bind check: fail fast if :8888 already taken (no SO_REUSEADDR: must detect conflict).
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        # NOTE: do NOT set SO_REUSEADDR here; it would mask an in-use port on Windows.
        s.bind(("127.0.0.1", int(PORT)))
    except OSError as e:
        print(f"FATAL: cannot bind 127.0.0.1:{PORT} (already in use?): {e}", file=sys.stderr)
        print(f"HINT: Get-NetTCPConnection -LocalPort {PORT} | Select-Object OwningProcess; then Stop-Process -Id <pid> or change PORT.", file=sys.stderr)
        sys.exit(3)
    except Exception as e:
        print(f"FATAL: bind self-check failed for 127.0.0.1:{PORT}: {e}", file=sys.stderr)
        sys.exit(3)
    finally:
        try:
            if s is not None:
                s.close()
        except Exception:
            pass
    # DRAIN file sanity (warn only, never fail).
    try:
        if _is_draining():
            print(f"WARN: drain active at startup (DRAIN=1 file {DRAIN_FILE}); new streams will get 503 until cleared.", file=sys.stderr)
    except Exception:
        pass
    return True

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
        concurrency = dict(_METRICS.get("concurrency", {}))
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
    for k in ("rejected", "drained"):
        concurrency.setdefault(k, 0)
    requestdl["last_age_s"] = last_age
    try:
        requestdl["bucket"] = _bucket_snapshot()
    except Exception:
        requestdl["bucket"] = {"tokens": 0.0, "cooldown_until": 0.0}
    try:
        cache = _link_cache_stats()
    except Exception:
        cache = {"size": 0, "cap": int(_LINK_CACHE_CAP), "evictions": 0}
    # 10) Cache introspection extras (also served by GET /cache).
    try:
        cache["hit_ratio"] = _link_cache_hit_ratio()
        cache["hits"] = int(requestdl.get("cached", 0))
        cache["misses"] = int(requestdl.get("ok", 0)) + int(requestdl.get("failed", 0))
        cache["entries"] = int(cache.get("size", 0))
        cache["top_keys"] = _cache_top_keys(limit=10)
    except Exception:
        pass
    # 2) Per-endpoint latency histogram.
    try:
        latency_histogram = _latency_snapshot()
    except Exception:
        latency_histogram = {}
    # 8) Adjacent-Range coalescing stats.
    try:
        range_coalescing = _range_coalescing_snapshot()
    except Exception:
        range_coalescing = {"coalesced": 0}
    try:
        draining = bool(_is_draining())
    except Exception:
        draining = False
    try:
        chunk_kb = int(_parse_env_int("PROXY_CHUNK_KB", PROXY_CHUNK_KB, 4, 4096))
    except Exception:
        chunk_kb = 64
    return {
        "started_iso": _START_ISO,
        "uptime_s": round(now - _START_TIME, 1),
        "torbox": {"2xx": torbox["2xx"], "200": torbox["200"], "206": torbox["206"], "416": torbox["416"], "429": torbox["429"], "502": torbox["502"]},
        "gdrive": gdrive,
        "cdn_retry": cdn_retry,
        "requestdl": requestdl,
        "mylist": mylist,
        "concurrency": concurrency,
        "concurrent_per_ip": _stream_slots_snapshot(),
        "max_concurrent_per_ip": _get_max_per_ip(),
        "cache": cache,
        "latency": latency_histogram,
        "latency_histogram": latency_histogram,
        "range_coalescing": range_coalescing,
        "draining": draining,
        "chunk_kb": chunk_kb,
        "chunk_bytes": int(chunk_kb) * 1024,
        "write_timeout_s": _get_write_timeout(),
        "log_sample": _get_log_sample(),
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
        _link_cache_record_hit(cache_key)
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
            _link_cache_record_hit(cache_key)
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
                _link_cache_record_hit(cache_key)
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
                _link_cache_record_hit(cache_key)
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

    def send_response(self, code, message=None):
        try:
            self._resp_status = int(code)
        except Exception:
            self._resp_status = code
        return super().send_response(code, message)

    @staticmethod
    def _is_quiet_disconnect(exc):
        """True for slow-client / PotPlayer disconnects that must close quietly."""
        try:
            if isinstance(exc, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)):
                return True
            if isinstance(exc, socket.timeout):
                return True
            if isinstance(exc, Timeout):
                return True
            msg = str(exc or "")
            low = msg.lower()
            for token in ("10053", "10054", "forcibly closed", "aborted", "broken pipe",
                          "connection reset", "timed out", "timeout"):
                if token in low:
                    return True
        except Exception:
            pass
        return False

    def _write_chunk_quiet(self, data):
        """4) Slow-client write with timeout + quiet close. Returns True if OK, False if client gone."""
        try:
            try:
                self.connection.settimeout(_get_write_timeout())
            except Exception:
                pass
            self.wfile.write(data)
            try:
                self.wfile.flush()
            except Exception:
                pass
            return True
        except Exception as exc:
            # Quiet close: no traceback, no 502, just signal caller to stop.
            return False

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
        # 8) Adjacent-Range-request coalescing: adjacent probes reuse cached CDN link.
        try:
            if range_header:
                _note_range_and_check_coalesced(torrent_id, file_id, range_header)
        except Exception:
            pass
        # 4) Slow-client write timeout: bound each socket write, quiet close on stall.
        try:
            self.connection.settimeout(_get_write_timeout())
        except Exception:
            pass
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
                        # 3) Configurable stream chunk size via PROXY_CHUNK_KB env (default 64).
                        _chunk_size = _get_chunk_bytes()
                        for chunk in response.iter_content(chunk_size=_chunk_size):
                            if not chunk:
                                continue
                            try:
                                # 4) Slow-client write timeout with quiet close.
                                try:
                                    self.connection.settimeout(_get_write_timeout())
                                except Exception:
                                    pass
                                self.wfile.write(chunk)
                                self.wfile.flush()
                            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError, socket.timeout) as exc:
                                # Client (PotPlayer) disconnect / slow-client stall: quiet, no retry/502.
                                try:
                                    response.close()
                                except Exception:
                                    pass
                                return True
                            except Exception as exc:
                                if self._is_quiet_disconnect(exc):
                                    try:
                                        response.close()
                                    except Exception:
                                        pass
                                    return True
                                raise
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
        """Wrapper: per-endpoint latency histogram + structured JSON access log."""
        _t0 = time.monotonic()
        try:
            self._resp_status = 0
        except Exception:
            pass
        try:
            return self._handle_proxy_inner(head_only=head_only)
        finally:
            try:
                elapsed = time.monotonic() - _t0
                try:
                    req_path = str(getattr(self, "path", "/") or "/").split("?")[0]
                except Exception:
                    req_path = "/"
                endpoint = _latency_endpoint_for_path(req_path)
                _observe_latency(endpoint, elapsed)
                try:
                    status = int(getattr(self, "_resp_status", 0) or 0)
                except Exception:
                    status = 0
                try:
                    client_ip = self.client_address[0] if getattr(self, "client_address", None) else "-"
                except Exception:
                    client_ip = "-"
                try:
                    method = str(getattr(self, "command", "GET"))
                except Exception:
                    method = "GET"
                _access_log({
                    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "ip": str(client_ip),
                    "method": method,
                    "path": _sanitize_log(req_path, 300),
                    "endpoint": endpoint,
                    "status": status,
                    "latency_ms": round(float(elapsed) * 1000.0, 3),
                    "range": _sanitize_log(self.headers.get("Range") if hasattr(self, "headers") and self.headers else "-", 120),
                    "head": bool(head_only),
                })
            except Exception:
                pass

    def _handle_proxy_inner(self, head_only=False):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        path = parsed.path

        # Health (lightweight, distinct from deep /ready check)
        if path in ("/", "/health"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            try:
                self.wfile.write(b"Torbox Proxy Ready 127.0.0.1:8888")
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                pass
            return

        # 1) GET /ready endpoint (deep check: port bound + TORBOX_API_KEY present + TorBox reachable) distinct from /health.
        if path == "/ready" or path.startswith("/ready"):
            try:
                key_present = bool((os.environ.get("TORBOX_API_KEY") or "").strip())
                port_bound = _check_port_bound("127.0.0.1", int(PORT), timeout=1.0)
                reachable, detail = _check_torbox_reachable(timeout=5.0)
                ready = bool(port_bound and key_present and reachable)
                body = json.dumps({
                    "ready": ready,
                    "checks": {
                        "port_bound": bool(port_bound),
                        "port": int(PORT),
                        "key_present": bool(key_present),
                        "torbox_reachable": bool(reachable),
                        "torbox_detail": str(detail),
                    },
                }).encode("utf-8")
                self.send_response(200 if ready else 503)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if not head_only:
                    try:
                        self.wfile.write(body)
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                        pass
            except Exception as e:
                log(f"ready fail: {e}")
                try:
                    self.send_error(500, "ready check failed")
                except Exception:
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

        # 10) GET /cache introspection (entries, hit ratio, top keys, ?purge=key).
        if path == "/cache" or path.startswith("/cache"):
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                self.send_error(403, "cache restricted to localhost")
                return
            origin = self.headers.get("Origin") or self.headers.get("Referer") or ""
            if origin:
                try:
                    ohost = urllib.parse.urlparse(origin).hostname or ""
                except Exception:
                    ohost = origin
                if ohost not in ("127.0.0.1", "localhost", "::1", ""):
                    self.send_error(403, "cache restricted to same-origin")
                    return
            try:
                purge_vals = qs.get("purge", [])
                purged = None
                if purge_vals:
                    purged = _cache_purge(str(purge_vals[0]))
                try:
                    stats = _link_cache_stats()
                except Exception:
                    stats = {"size": 0, "cap": int(_LINK_CACHE_CAP), "evictions": 0}
                with _METRICS_LOCK:
                    _rd = dict(_METRICS.get("requestdl", {}))
                body = json.dumps({
                    "entries": int(stats.get("size", 0)),
                    "size": int(stats.get("size", 0)),
                    "cap": int(stats.get("cap", int(_LINK_CACHE_CAP))),
                    "evictions": int(stats.get("evictions", 0)),
                    "hits": int(_rd.get("cached", 0)),
                    "misses": int(_rd.get("ok", 0)) + int(_rd.get("failed", 0)),
                    "hit_ratio": _link_cache_hit_ratio(),
                    "hit-ratio": _link_cache_hit_ratio(),
                    "top_keys": _cache_top_keys(limit=10),
                    "top-keys": _cache_top_keys(limit=10),
                    "purged": purged,
                }).encode("utf-8")
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
                log(f"cache fail: {e}")
                try:
                    self.send_error(500, "cache failed")
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
                # 6) Graceful drain: DRAIN=1 file stops accepting new streams, finishes in-flight.
                try:
                    if _is_draining():
                        _m_inc("concurrency", "drained")
                        self.send_response(503, "Draining")
                        self.send_header("Content-Type", "text/plain")
                        self.send_header("Retry-After", "10")
                        self.send_header("X-Drain", "1")
                        self.end_headers()
                        try:
                            self.wfile.write(b"draining: proxy stopping, retry shortly")
                        except Exception:
                            pass
                        return
                except Exception:
                    pass
                # 5) Per-IP concurrent-stream cap returning 429 + Retry-After.
                _slot_ip = self.client_address[0] if getattr(self, "client_address", None) else "unknown"
                _slot_ok = False
                try:
                    _slot_ok = _try_acquire_stream_slot(_slot_ip)
                except Exception:
                    _slot_ok = True
                if not _slot_ok:
                    try:
                        _m_inc("concurrency", "rejected")
                        retry_after = str(int(_parse_env_int("PROXY_RETRY_AFTER_S", PROXY_CONCURRENT_RETRY_AFTER_S, 1, 120)))
                        self.send_response(429, "Too Many Streams")
                        self.send_header("Content-Type", "text/plain")
                        self.send_header("Retry-After", retry_after)
                        self.send_header("X-RateLimit-Reason", "per-ip-concurrent-stream-cap")
                        self.end_headers()
                        try:
                            self.wfile.write(b"too many concurrent streams for your IP, retry shortly")
                        except Exception:
                            pass
                    except Exception:
                        pass
                    return
                try:
                    log(f"Proxy torbox {tid}/{fid} {_sanitize_log(nice)} Range:{_sanitize_log(self.headers.get('Range'))} Head:{head_only}")
                    self.proxy_torbox_stream(tid, fid, head_only=head_only)
                finally:
                    try:
                        _release_stream_slot(_slot_ip)
                    except Exception:
                        pass
                return
            self.send_error(404, "torbox path need /torbox/<tid>/<fid>/name")
            return

        # GDrive: /gdrive/<path> -> serves F:\Media\... or G:\... via HTTP Range (so PotPlayer shows bar for GDrive too, not just Torbox)
        if path.startswith("/gdrive/"):
            # 6) Graceful drain: DRAIN=1 file stops accepting new streams, finishes in-flight.
            try:
                if _is_draining():
                    _m_inc("concurrency", "drained")
                    self.send_response(503, "Draining")
                    self.send_header("Content-Type", "text/plain")
                    self.send_header("Retry-After", "10")
                    self.send_header("X-Drain", "1")
                    self.end_headers()
                    try:
                        self.wfile.write(b"draining: proxy stopping, retry shortly")
                    except Exception:
                        pass
                    return
            except Exception:
                pass
            # 5) Per-IP concurrent-stream cap returning 429 + Retry-After.
            _g_ip = self.client_address[0] if getattr(self, "client_address", None) else "unknown"
            try:
                if not _try_acquire_stream_slot(_g_ip):
                    _m_inc("concurrency", "rejected")
                    retry_after = str(int(_parse_env_int("PROXY_RETRY_AFTER_S", PROXY_CONCURRENT_RETRY_AFTER_S, 1, 120)))
                    self.send_response(429, "Too Many Streams")
                    self.send_header("Content-Type", "text/plain")
                    self.send_header("Retry-After", retry_after)
                    self.send_header("X-RateLimit-Reason", "per-ip-concurrent-stream-cap")
                    self.end_headers()
                    try:
                        self.wfile.write(b"too many concurrent streams for your IP, retry shortly")
                    except Exception:
                        pass
                    return
            except Exception:
                pass
            try:
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
                        # Stream file (3/4: configurable chunk + slow-client timeout, quiet close)
                        try:
                            self.connection.settimeout(_get_write_timeout())
                        except Exception:
                            pass
                        with open(fpath, "rb") as fh:
                            fh.seek(start)
                            remaining = length
                            chunk = _get_chunk_bytes()
                            while remaining > 0:
                                read_len = min(chunk, remaining)
                                data = fh.read(read_len)
                                if not data: break
                                try:
                                    try:
                                        self.connection.settimeout(_get_write_timeout())
                                    except Exception:
                                        pass
                                    self.wfile.write(data)
                                    try:
                                        self.wfile.flush()
                                    except Exception:
                                        pass
                                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError, socket.timeout):
                                    break
                                except Exception as exc:
                                    if self._is_quiet_disconnect(exc):
                                        break
                                    raise
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
            finally:
                try:
                    _release_stream_slot(_g_ip)
                except Exception:
                    pass

        # Fallback: try to serve via rclone WebDAV for F:\Media / T:\ when Torbox not used (GDrive)
        self.send_error(404, "unknown path, use /torbox/<tid>/<fid>/name, /gdrive/<path> or /health")

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

def run():
    # 9) Startup self-check (bind, env key, fail fast with clear message).
    _startup_self_check()
    server_address = ("127.0.0.1", PORT)
    try:
        httpd = http.server.ThreadingHTTPServer(server_address, Handler)
    except OSError as e:
        print(f"FATAL: cannot bind 127.0.0.1:{PORT} (already in use?): {e}", file=sys.stderr)
        print(f"HINT: Get-NetTCPConnection -LocalPort {PORT} | Select-Object OwningProcess", file=sys.stderr)
        sys.exit(3)
    log(f"Torbox Proxy listening on http://127.0.0.1:{PORT} (torbox + gdrive, local Range streaming, CDN retry/backoff)")
    log(f"Health: http://127.0.0.1:{PORT}/health Ready: http://127.0.0.1:{PORT}/ready Metrics: http://127.0.0.1:{PORT}/metrics Cache: http://127.0.0.1:{PORT}/cache Logs: http://127.0.0.1:{PORT}/logs")
    log(f"Tuning: chunk={_get_chunk_bytes()}B ({_parse_env_int('PROXY_CHUNK_KB', PROXY_CHUNK_KB, 4, 4096)}KB) write_timeout={_get_write_timeout()}s max_per_ip={_get_max_per_ip()} log_sample={_get_log_sample()} draining={_is_draining()}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    # ensure log dir
    Path(LOG_FILE).parent.mkdir(parents=True, exist_ok=True)
    run()
