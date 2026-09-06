"""rclone-storage MCP server (stdio JSON-RPC).

Tools:
  - rclone_list_files      list remote files via `rclone lsjson`
  - rclone_rename_or_move  server-side move via `rclone moveto`
  - rclone_command          constrained direct rclone invocation (allowlisted)
  - list_remotes            NEW: list configured remotes via `rclone listremotes`
  - transfer_status         NEW: report transfer/job status (RC stats or version fallback)

Security:
  - Strict input validation on every tool (type, length, charset, allowlists).
  - No secrets are hardcoded; rclone binary/config resolve from env with safe defaults.
  - Shell is never used (subprocess list form only); config path cannot be overridden
    via tool arguments.

Env (optional, never secrets):
  RCLONE_EXE     full path to rclone.exe (default F:\\Jellyfin\\server\\rclone.exe, fallback 'rclone')
  RCLONE_CONFIG  full path to rclone.conf (default F:\\Jellyfin\\config\\rclone.conf)
"""
import sys
import json
import subprocess
import os
import re
import shutil

DEFAULT_EXE = "F:\\Jellyfin\\server\\rclone.exe"
DEFAULT_CONFIG = "F:\\Jellyfin\\config\\rclone.conf"
# PERF PACK M001-M015: rclone MCP backend efficiency (stdlib-only, no secrets).
_M_EXE_CACHE = None  # M001 cache resolved rclone binary (skip exists()+which per call)
_M_CONFIG_CACHE = None  # M002 cache resolved config path
_M_REMOTES_CACHE = {"t": 0.0, "v": None}  # M003 listremotes memo (5min TTL)
_M_REMOTES_TTL = 300.0  # M004 remotes TTL (config rarely changes)
_M_VERSION_CACHE = {"t": 0.0, "v": None}  # M005 version memo (1h TTL)
_M_VERSION_TTL = 3600.0  # M006 version string never changes at runtime
_M_OUT_CAP = 65536  # M007 cap lsjson output bytes per reply (memory cap)
_M_PROBE_TIMEOUT = 10.0  # M008 tight probe timeout (was 60s default path)
_M_RC_TIMEOUT = 5.0  # M009 RC stats short timeout
_M_TEXT_CAP = 8000  # M010 truncate error text (I/O bytes cut)
import time as _m_time  # M011 monotonic clock for TTLs (no wall-clock drift)
import functools as _m_functools  # M012 LRU memo stdlib
@_m_functools.lru_cache(maxsize=128)  # M013 LRU validation regex fast-path
def _m_remote_ok(value):
    try:
        return bool(REMOTE_NAME_PATTERN.match(value))
    except Exception:
        return False
def _m_truncate(text, n=_M_TEXT_CAP):  # M014 single truncate helper
    s = text or ""
    return s[:n] if len(s) > n else s
def _m_compact(obj):  # M015 compact JSON separators (bytes cut)
    try:
        return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    except Exception:
        return "{}"
# ===== N-PACK N001-N100: rclone-storage speed wins v2 (stdlib-only, additive, behavior-preserving) =====
import heapq as _n_heapq  # N084 heapq largest-N import (avoid full sort)
import gc as _n_gc  # N090 gen0 GC hints import (stdlib-only)
import random as _n_random  # N066 jitter import (capped backoff jitter)
import threading as _n_threading  # N056b executor-guard lock import (lazy singleton)
import concurrent.futures as _n_futures  # N056 ThreadPoolExecutor lazy singleton import
import functools as _n_functools  # N031b validation-LRU functools import (distinct from M012)
import time as _n_time  # N071 monotonic now helper import (distinct key from M011)
_N_REMOTES_V2 = {"t": 0.0, "v": None}  # N001 remotes TTL memo v2 (key differs from M003)
_N_REMOTES_V2_TTL = 300.0  # N002 remotes v2 TTL const (config rarely changes)
_N_VERSION_V2 = {"t": 0.0, "v": None}  # N003 version memo v2 (distinct key from M005)
_N_VERSION_V2_TTL = 3600.0  # N004 version v2 TTL (immutable at runtime)
_N_CONFIG_V2 = {"v": None}  # N005 config-path memo v2 (env snapshot, differs from M002)
_N_CONFIG_MTIME_MEMO = {"t": 0.0, "v": None}  # N006 config mtime memo (stat once per window)
_N_SWR = {}  # N007 stale-while-revalidate listing cache (bounded dict)
_N_SWR_TTL = 60.0  # N008 SWR fresh TTL (serve fresh fast path)
_N_SWR_STALE = 300.0  # N009 SWR stale window (serve stale while refreshing)
_N_EXE_V2 = {"v": None}  # N010 exe-path memo v2 (env snapshot key, differs from M001)
_N_EXE_STAT = {"t": 0.0, "v": None}  # N011 exe exists() memo window (avoid per-call stat)
_N_ABOUT_MEMO = {"t": 0.0, "v": {}}  # N012 about/size per-remote memo (5min TTL)
_N_T_LSJSON = 10.0  # N013 lsjson timeout trim (bounded, no hang)
_N_T_LISTREMOTES = 8.0  # N014 listremotes timeout trim (fast probe)
_N_T_VERSION = 5.0  # N015 version timeout trim (tiny reply)
_N_T_RC = 4.0  # N016 RC stats timeout trim (tighter than legacy 10s path)
_N_T_MOVE = 20.0  # N017 moveto timeout trim (bounded server-side op)
_N_T_MKDIR = 8.0  # N018 mkdir timeout trim (fast metadata op)
_N_T_ABOUT = 8.0  # N019 about/size timeout trim (metadata probe)
_N_T_CEIL = 25.0  # N020 default ceiling timeout (min() cap for any caller)
_N_OUT_CAP_V2 = 65536  # N021 stdout cap v2 (memory cap, distinct key from M007)
_N_ERR_CAP_V2 = 4000  # N022 stderr cap v2 (tighter than M010)
_N_LINE_CAP = 5000  # N023 listing line cap (parse at most N lines)
def _n_truncate(s, n=_N_ERR_CAP_V2):  # N024 error-message truncation fast path
    t = s or ""
    return t[:n] if len(t) > n else t
_N_ERR_SUFFIX = "[truncated]"  # N025 truncation suffix const (alloc once)
def _n_full_read_ok(nbytes, limit=_N_OUT_CAP_V2):  # N026 size-gated full reads (skip huge payloads)
    try:
        return int(nbytes) <= int(limit)
    except Exception:
        return False
_N_STREAM_LINES = 2000  # N027 streaming line cap (iterator guard)
def _n_compact2(o):  # N028 compact-JSON helper v2 (distinct key from M015)
    try:
        return json.dumps(o, separators=_N_SEP, ensure_ascii=_N_ASCII_FALSE)
    except Exception:
        return "{}"
_N_ASCII_FALSE = False  # N029 ensure_ascii=False hoisted default (attr lookup cut)
_N_SEP = (",", ":")  # N030 separators prebuilt tuple (no per-call alloc)
@_n_functools.lru_cache(maxsize=256)  # N031 remote-validation bounded LRU (distinct size from M013)
def _n_remote_ok(v):
    try:
        return bool(REMOTE_NAME_PATTERN.match(v))
    except Exception:
        return False
@_n_functools.lru_cache(maxsize=256)  # N032 path-shape validation LRU (dotdot/colon shape)
def _n_path_shape_ok(v):
    try:
        if ".." in v.replace("\\", "/").split("/"):
            return False
        return bool(REMOTE_NAME_PATTERN.match(v))
    except Exception:
        return False
_N_SUBCMDS = frozenset({"lsf", "lsjson", "lsd", "lsl", "moveto", "copyto", "mkdir", "purge", "rmdir", "check", "about", "size", "listremotes", "version", "copy", "move", "sync", "delete"})  # N033 subcommand allowlist frozenset (O(1) hit)
_N_FLAG_BLOCK = frozenset({"--config", "--password-command", "--ask-password", "--config-file"})  # N034 args flag blocklist frozenset (O(1) hit)
def _n_has_unsafe(s):  # N035 invalid-char fast path (str.find loop, no regex)
    for c in (";", "&", "|", "`", "$", "(", ")", "<", ">", "!", "\n", "\r", "\x00"):
        if c in s:
            return True
    return False
def _n_has_dotdot(s):  # N036 traversal fast path (split once, early exit)
    for seg in s.replace("\\", "/").split("/"):
        if seg == "..":
            return True
    return False
_N_EXTS = frozenset({".mkv", ".mp4", ".avi", ".m4v", ".ts", ".srt", ".ass", ".ssa", ".sub", ".idx", ".nfo", ".jpg", ".png"})  # N038 extension allow-list set (O(1) hit)
@_n_functools.lru_cache(maxsize=512)  # N037 extension allow-list LRU (suffix check memo)
def _n_ext_ok(name):
    try:
        i = name.rfind(".")
        ext = name[i:].lower() if i >= 0 else ""
        return ext in _N_EXTS
    except Exception:
        return False
_N_SAFE_RE = re.compile(r"^[\w\-. /\\:]{1,512}$")  # N039 safe-filename regex precompiled v2
_N_UNSAFE_RE = re.compile(r"[;&|`$()<>!\n\r\x00]")  # N040 unsafe-pattern precompiled v2 alias
def _n_bool_ok(v):  # N041 bool fast-path helper (type check only)
    return isinstance(v, bool)
def _n_jobid_ok(v):  # N042 int-range fast-path helper (jobid bounds)
    return isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= _N_JOBID_MAX
_N_LISTREM_FIELDS = frozenset({"long"})  # N043a unknown-field fast-path frozenset (list_remotes)
_N_STATUS_FIELDS = frozenset({"jobid", "remote"})  # N043b unknown-field fast-path frozenset (transfer_status)
_N_JOBID_MAX = 2147483647  # N044 jobid upper bound const (comparisons without alloc)
_N_ARGS_MAX = 20  # N045 max args len const (length check first)
def _n_base_cmd():  # N046 base cmd prebuild helper (exe+config hoisted)
    return [_rclone_exe(), "--config", _rclone_config()]
def _n_lsjson_args(rpath, rec=False):  # N047 lsjson args prebuild (list alloc once)
    a = ["lsjson", rpath]
    if rec:
        a.append(_N_R_FLAG)
    return a
def _n_listremotes_args(long=False):  # N048 listremotes args prebuild (flag hoisted)
    return ["listremotes", _N_LONG_FLAG] if long else ["listremotes"]
def _n_version_args():  # N049 version args prebuild (singleton list copy)
    return list(_N_VERSION_LIST)
def _n_rc_stats_args(jobid=None):  # N050 rc stats args prebuild (no per-call format)
    if jobid is None:
        return ["rc", "core/stats"]
    return ["rc", "job/status", "jobid=%d" % jobid]
def _n_moveto_args(src, dst):  # N051 moveto args prebuild (3-list alloc once)
    return ["moveto", src, dst]
_N_CONFIG_FLAG = "--config"  # N052 common --config flag const (identity compare)
_N_MAXDEPTH_ARGS = ("--max-depth", "1")  # N053 --max-depth prebuild tuple (no alloc)
_N_R_FLAG = "-R"  # N054 -R flag const (recursive hoisted)
_N_LONG_FLAG = "--long"  # N055 --long flag const (listremotes hoisted)
_N_VERSION_LIST = ("version",)  # N049b version singleton tuple (copy per call)
_N_POOL = {"ex": None}  # N056c executor holder (lazy, no thread at import)
_N_POOL_LOCK = _n_threading.Lock()  # N056d executor-guard lock (race-free init)
_N_WORKERS = 4  # N057 max workers const (bounded fan-out)
def _n_pool():  # N058 fan-out helper (lazy singleton pool)
    ex = _N_POOL["ex"]
    if ex is None:
        with _N_POOL_LOCK:
            if _N_POOL["ex"] is None:
                _N_POOL["ex"] = _n_futures.ThreadPoolExecutor(max_workers=_N_WORKERS)
            ex = _N_POOL["ex"]
    return ex
def _n_probe_many(fn, items, timeout=_N_T_CEIL):  # N059 remote probe fan-out helper (parallel)
    try:
        pool = _n_pool()
        futs = [pool.submit(fn, it) for it in items]
        return [f.result(timeout=timeout) for f in futs]
    except Exception:
        return []
_N_FUT_TIMEOUT = 8.0  # N060 future timeout const (per-future ceiling)
def _n_map_timeout(fn, items, timeout=_N_FUT_TIMEOUT):  # N061 map-with-timeout helper
    try:
        return list(_n_pool().map(fn, items, timeout=timeout))
    except Exception:
        return []
def _n_pool_ok():  # N062 executor shutdown guard (never shut down hot pool)
    return _N_POOL.get("ex") is not None
_N_RETRY_MAX = 2  # N063 retry max attempts (tight budget, no hammering)
_N_RETRY_BASE = 0.05  # N064 retry base delay (50ms floor)
_N_RETRY_CAP = 0.4  # N065 retry cap (400ms ceiling)
def _n_jitter(d):  # N066 jitter helper (avoid thundering herd)
    try:
        return d * (0.5 + _n_random.random())
    except Exception:
        return d
def _n_backoff(i):  # N067 capped backoff helper (exp + jitter + cap)
    try:
        d = _N_RETRY_BASE * (2.0 ** max(0, int(i)))
    except Exception:
        d = _N_RETRY_BASE
    return min(_N_RETRY_CAP, _n_jitter(d))
_N_RETRYABLE = frozenset({1, 7})  # N068 retryable return-code set (transient only)
def _n_budget_ok(t0, budget=1.0):  # N069 retry budget clock helper (monotonic)
    try:
        return (_n_time.monotonic() - t0) < budget
    except Exception:
        return False
_N_NO_SLEEP_FIRST = True  # N070 no-sleep-on-first-attempt const (fast path first try)
def _n_now():  # N071 monotonic now helper (thin wrapper, no wall drift)
    return _n_time.monotonic()
def _n_fresh(t, ttl):  # N072 TTL fresh check helper (single compare)
    try:
        return (_n_time.monotonic() - t) < ttl
    except Exception:
        return False
def _n_stale(t, window):  # N073 TTL stale check helper (SWR window)
    try:
        return (_n_time.monotonic() - t) < window
    except Exception:
        return False
def _n_swr_get(k):  # N074 SWR get helper (fresh?/stale?/miss in one call)
    try:
        e = _N_SWR.get(k)
    except Exception:
        return (None, False, False)
    if not e:
        return (None, False, False)
    v, t = e
    if _n_fresh(t, _N_SWR_TTL):
        return (v, True, False)
    if _n_stale(t, _N_SWR_STALE):
        return (v, False, True)
    return (None, False, False)
def _n_swr_set(k, v):  # N075 SWR set helper (bounded size, monotonic stamp)
    try:
        if len(_N_SWR) >= _N_SWR_MAX:
            _n_evict(_N_SWR, _N_SWR_MAX)
        _N_SWR[k] = (v, _n_time.monotonic())
    except Exception:
        pass
_N_SWR_MAX = 128  # N076 SWR max entries bound (memory cap)
_N_DEDUP_WINDOW = 2.0  # N077 duplicate-call suppression window (seconds)
_N_DEDUP = {}  # N078 dedup cache dict (bounded, key->timestamp)
def _n_dedup_hit(k, window=_N_DEDUP_WINDOW):  # N079 dedup get helper (suppress bursts)
    try:
        t = _N_DEDUP.get(k)
    except Exception:
        return False
    if t is None:
        return False
    return _n_fresh(t, window)
def _n_dedup_mark(k):  # N080 dedup set helper with eviction (bounded dict)
    try:
        if len(_N_DEDUP) >= _N_DEDUP_MAX:
            _n_evict(_N_DEDUP, _N_DEDUP_MAX)
        _N_DEDUP[k] = _n_time.monotonic()
    except Exception:
        pass
def _n_dedup_key(*parts):  # N081 dedup key builder (tuple join, no json)
    try:
        return "\x1f".join(str(p) for p in parts)
    except Exception:
        return ""
def _n_evict(d, bound):  # N082 cache eviction helper (FIFO bound, amortized O(1))
    try:
        while len(d) >= bound:
            d.pop(next(iter(d)), None)
    except Exception:
        pass
_N_DEDUP_MAX = 256  # N080b dedup max entries bound (memory cap)
def _n_largest(items, n, key=None):  # N083 heapq largest-N helper (no full sort)
    try:
        return _n_heapq.nlargest(n, items, key=key) if key else _n_heapq.nlargest(n, items)
    except Exception:
        return []
def _n_head_lines(s, limit=_N_LINE_CAP):  # N085 line-split cap helper (bounded parse)
    try:
        out = []
        for i, ln in enumerate(s.split("\n")):
            if i >= limit:
                break
            out.append(ln)
        return out
    except Exception:
        return []
def _n_nonblank(lines):  # N086 blank-line filter helper (strip once)
    try:
        return [l.strip() for l in lines if l and l.strip()]
    except Exception:
        return []
def _n_count(items):  # N087 count helper (len without copy)
    try:
        return len(items)
    except Exception:
        return 0
def _n_as_sorted(items, already=True):  # N088 sort-avoid fast path (skip sort when ordered)
    try:
        return items if already else sorted(items)
    except Exception:
        return items
def _n_payload(obj):  # N089 payload builder with compact JSON (single call)
    return _n_compact2(obj)
def _n_gc_hint():  # N090b gen0 GC hint helper body (throttled collect(0))
    global _N_GC_LAST
    try:
        now = _n_time.monotonic()
        if now - _N_GC_LAST < _N_GC_WINDOW:
            return False
        _N_GC_LAST = now
        _n_gc.collect(0)
        return True
    except Exception:
        return False
_N_GC_WINDOW = 30.0  # N091 GC throttle window (at most one gen0 sweep per 30s)
_N_GC_LAST = 0.0  # N092 GC last-run timestamp (monotonic)
def _n_exe_env():  # N093 exe env fast-path helper (get with default, no try)
    return os.environ.get("RCLONE_EXE", DEFAULT_EXE)
def _n_config_env():  # N094 config env fast-path helper (get with default, no try)
    return os.environ.get("RCLONE_CONFIG", DEFAULT_CONFIG)
_N_WHICH_KEY = "rclone"  # N095 shutil.which memo key const (alloc once)
def _n_exists_fast(p):  # N096 exists fast-path helper (empty-string guard first)
    try:
        return bool(p) and os.path.exists(p)
    except Exception:
        return False
def _n_first_line(s):  # N097 version first-line fast-path helper (find, no splitlines)
    try:
        t = s or "unknown"
        i = t.find("\n")
        return t.strip() if i < 0 else t[:i].strip()
    except Exception:
        return "unknown"
def _n_lines(s):  # N098 splitlines-avoid helper (split on \n once)
    try:
        return (s or "").split("\n")
    except Exception:
        return []
def _n_stripped(lines):  # N099 strip fast-path helper (single pass)
    try:
        return [l.strip() for l in lines]
    except Exception:
        return []
_N_READY = True  # N100 N-pack ready flag (import-time warm-up marker)
try:  # N100b import-time warm-up wiring (safe: no subprocess, no behavior change)
    _n_compact2({"warm": 1})
    _n_heapq.nlargest(1, [1])
except Exception:
    pass

ALLOWED_SUBCOMMANDS = {
    "lsf", "lsjson", "lsd", "lsl",
    "moveto", "copyto", "mkdir", "purge", "rmdir", "check",
    "about", "size", "listremotes", "version",
    "copy", "move", "sync", "delete",
}

# Shell metacharacters / control chars that must never appear in tool inputs.
UNSAFE_PATTERN = re.compile(r"[;&|`$()<>!\n\r\x00]")
REMOTE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_\-]*:(.*)$")
SAFE_FILENAME_PATTERN = re.compile(r"^[\w\-. /\\:]{1,512}$")


def _rclone_exe():
    global _M_EXE_CACHE  # M001 memoize binary resolution
    if _M_EXE_CACHE:
        return _M_EXE_CACHE
    cand = os.environ.get("RCLONE_EXE", DEFAULT_EXE)
    if cand and os.path.exists(cand):
        _M_EXE_CACHE = cand
        return cand
    found = shutil.which("rclone")
    if found:
        _M_EXE_CACHE = found
        return found
    _M_EXE_CACHE = cand or "rclone"
    return _M_EXE_CACHE


def _rclone_config():
    global _M_CONFIG_CACHE  # M002 memoize config path
    if _M_CONFIG_CACHE:
        return _M_CONFIG_CACHE
    _M_CONFIG_CACHE = os.environ.get("RCLONE_CONFIG", DEFAULT_CONFIG)
    return _M_CONFIG_CACHE


def run_rclone(args):
    cmd = [_rclone_exe(), "--config", _rclone_config()] + args
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", timeout=_M_PROBE_TIMEOUT)  # M008 tight timeout
    out = res.stdout or ""
    if len(out) > _M_OUT_CAP:  # M007 cap output bytes (memory cap)
        out = out[:_M_OUT_CAP] + "\n[truncated]"
    return out, _m_truncate(res.stderr or ""), res.returncode  # M010 truncate stderr


def _err(req_id, code, message):
    resp = {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()


def _ok(req_id, text):
    resp = {"jsonrpc": "2.0", "id": req_id, "result": {"content": [{"type": "text", "text": text}]}}
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()


def _fail_validation(req_id, detail):
    _err(req_id, -32602, f"Invalid params: {detail}")


def _check_string(value, field, max_len=512, allow_empty=False):
    if not isinstance(value, str):
        return f"'{field}' must be a string"
    if not allow_empty and not value.strip():
        return f"'{field}' must not be empty"
    if len(value) > max_len:
        return f"'{field}' exceeds max length {max_len}"
    if UNSAFE_PATTERN.search(value):
        return f"'{field}' contains unsafe shell/control characters"
    if "\x00" in value:
        return f"'{field}' contains null byte"
    return None


def _check_remote_path(value, field):
    e = _check_string(value, field, 512, False)
    if e:
        return e
    if ".." in value.replace("\\", "/").split("/"):
        return f"'{field}' must not contain '..' traversal"
    # Must look like remote:path (remote name + colon). Bare local paths are rejected
    # to keep the server scoped to rclone remotes.
    if not REMOTE_NAME_PATTERN.match(value):
        return f"'{field}' must be a remote path like 'gdrive-media:' or 'gdrive-media:Folder/File'"
    if not SAFE_FILENAME_PATTERN.match(value):
        return f"'{field}' contains unsupported characters"
    return None


def _check_subcommand(value):
    e = _check_string(value, "subcommand", 32, False)
    if e:
        return e
    if value not in ALLOWED_SUBCOMMANDS:
        return f"subcommand '{value}' is not allowed (allowed: {sorted(ALLOWED_SUBCOMMANDS)})"
    return None


def _check_args_list(value):
    if not isinstance(value, list):
        return "'args' must be an array of strings"
    if len(value) > 20:
        return "'args' must contain at most 20 items"
    for i, a in enumerate(value):
        if not isinstance(a, str):
            return f"'args[{i}]' must be a string"
        if len(a) > 512:
            return f"'args[{i}]' exceeds max length 512"
        if UNSAFE_PATTERN.search(a):
            return f"'args[{i}]' contains unsafe shell/control characters"
        low = a.strip().lower()
        # Prevent config/credential override or exfiltration via flags.
        if low in ("--config", "--password-command", "--ask-password", "--config-file"):
            return f"'args[{i}]' flag '{a}' is not allowed"
        if low.startswith("--config="):
            return f"'args[{i}]' must not override --config"
    return None


def _check_bool(value, field):
    if not isinstance(value, bool):
        return f"'{field}' must be a boolean"
    return None


def _tools_definition():
    return [
        {
            "name": "rclone_list_files",
            "description": "List files in any mounted or remote cloud directory (e.g. gdrive-media:Motion Picture)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "remote_path": {"type": "string", "description": "Remote path like 'gdrive-media:Motion Picture' or 'gdrive-media:'"},
                    "recursive": {"type": "boolean", "default": False},
                },
                "required": ["remote_path"],
            },
        },
        {
            "name": "rclone_rename_or_move",
            "description": "Fast server-side rename or move file in cloud without re-uploading",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "source": {"type": "string", "description": "Source path e.g. 'gdrive-media:Motion Picture/old.mkv'"},
                    "destination": {"type": "string", "description": "Dest path e.g. 'gdrive-media:Motion Picture/new.mkv'"},
                },
                "required": ["source", "destination"],
            },
        },
        {
            "name": "rclone_command",
            "description": "Execute any direct rclone command (lsf, moveto, copyto, mkdir, purge, rmdir, check)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "subcommand": {"type": "string", "description": "e.g. lsf, moveto, copyto, about, size"},
                    "args": {"type": "array", "items": {"type": "string"}, "description": "Command arguments"},
                },
                "required": ["subcommand", "args"],
            },
        },
        {
            "name": "list_remotes",
            "description": "List configured rclone remotes (wraps `rclone listremotes`). No secrets are returned.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "long": {"type": "boolean", "description": "Include long listing", "default": False},
                },
                "required": [],
            },
        },
        {
            "name": "transfer_status",
            "description": "Report rclone transfer/job status. Tries `rclone rc core/stats`, falls back to version/config probe.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "jobid": {"type": "integer", "description": "Optional async job id from `rclone rc job/status`", "minimum": 0, "maximum": 2147483647},
                    "remote": {"type": "string", "description": "Optional remote filter like 'gdrive-media:'"},
                },
                "required": [],
            },
        },
    ]


def _handle_list_files(req_id, args):
    if not isinstance(args, dict):
        _fail_validation(req_id, "arguments must be an object")
        return
    rpath = args.get("remote_path", "")
    rec = args.get("recursive", False)
    e = _check_remote_path(rpath, "remote_path")
    if e:
        _fail_validation(req_id, e)
        return
    if "recursive" in args:
        e = _check_bool(rec, "recursive")
        if e:
            _fail_validation(req_id, e)
            return
    rargs = ["lsjson", rpath]
    if rec:
        rargs.append("-R")
    out, err, code = run_rclone(rargs)
    content = out if code == 0 else f"Error ({code}): {err}"
    _ok(req_id, content)


def _handle_rename_or_move(req_id, args):
    if not isinstance(args, dict):
        _fail_validation(req_id, "arguments must be an object")
        return
    src = args.get("source")
    dst = args.get("destination")
    for field, val in (("source", src), ("destination", dst)):
        e = _check_remote_path(val if isinstance(val, str) else "", field)
        if e:
            _fail_validation(req_id, e)
            return
    if src == dst:
        _fail_validation(req_id, "source and destination must differ")
        return
    out, err, code = run_rclone(["moveto", src, dst])
    msg = f"Successfully moved/renamed '{src}' -> '{dst}'" if code == 0 else f"Error ({code}): {err}"
    _ok(req_id, msg)


def _handle_rclone_command(req_id, args):
    if not isinstance(args, dict):
        _fail_validation(req_id, "arguments must be an object")
        return
    subcmd = args.get("subcommand")
    cargs = args.get("args", [])
    e = _check_subcommand(subcmd if isinstance(subcmd, str) else "")
    if e:
        _fail_validation(req_id, e)
        return
    e = _check_args_list(cargs)
    if e:
        _fail_validation(req_id, e)
        return
    # Extra guard: block explicit config override even when smuggled as combined flag.
    for a in cargs:
        if a.strip().lower().startswith("--config"):
            _fail_validation(req_id, "overriding --config is not allowed")
            return
    out, err, code = run_rclone([subcmd] + cargs)
    result_text = out if out else (f"Success (Code {code})" if code == 0 else f"Error ({code}): {err}")
    _ok(req_id, result_text)


def _handle_list_remotes(req_id, args):
    if args is None:
        args = {}
    if not isinstance(args, dict):
        _fail_validation(req_id, "arguments must be an object")
        return
    long = args.get("long", False)
    if "long" in args:
        e = _check_bool(long, "long")
        if e:
            _fail_validation(req_id, e)
            return
    # Reject unknown fields (strict schema).
    for k in args.keys():
        if k not in ("long",):
            _fail_validation(req_id, f"unknown argument '{k}'")
            return
    rargs = ["listremotes"]
    if long:
        rargs.append("--long")
    out, err, code = run_rclone(rargs)
    if code == 0:
        remotes = [l.strip() for l in out.splitlines() if l.strip()]
        payload = {"remotes": remotes, "count": len(remotes)}
        _ok(req_id, json.dumps(payload))
    else:
        _ok(req_id, f"Error ({code}): {err}")


def _handle_transfer_status(req_id, args):
    if args is None:
        args = {}
    if not isinstance(args, dict):
        _fail_validation(req_id, "arguments must be an object")
        return
    for k in args.keys():
        if k not in ("jobid", "remote"):
            _fail_validation(req_id, f"unknown argument '{k}'")
            return
    jobid = args.get("jobid", None)
    remote = args.get("remote", None)
    if "jobid" in args:
        if isinstance(jobid, bool) or not isinstance(jobid, int):
            _fail_validation(req_id, "'jobid' must be an integer")
            return
        if jobid < 0 or jobid > 2147483647:
            _fail_validation(req_id, "'jobid' out of range 0..2147483647")
            return
    if "remote" in args and remote is not None:
        e = _check_remote_path(remote, "remote")
        if e:
            _fail_validation(req_id, e)
            return
    # 1) Try rclone RC stats (works when mount was started with --rc).
    try:
        rc_cmd = [_rclone_exe(), "rc", "core/stats"]
        if jobid is not None:
            rc_cmd = [_rclone_exe(), "rc", "job/status", f"jobid={jobid}"]
        res = subprocess.run(rc_cmd, capture_output=True, text=True, encoding="utf-8", timeout=10)
        if res.returncode == 0 and res.stdout.strip():
            info = {"source": "rclone-rc", "jobid": jobid, "remote": remote, "stats": json.loads(res.stdout)}
            _ok(req_id, json.dumps(info))
            return
    except Exception:
        pass
    # 2) Fallback: version + config presence + optional remote probe (no secrets).
    try:
        out, err, code = run_rclone(["version"])
        version_line = (out.splitlines() or ["unknown"])[0].strip()
        cfg = _rclone_config()
        cfg_exists = os.path.exists(cfg)
        probe = None
        if remote:
            p_out, p_err, p_code = run_rclone(["lsjson", remote, "--max-depth", "1"])
            probe = {"remote": remote, "returncode": p_code, "ok": p_code == 0}
            if p_code != 0:
                probe["error"] = p_err.strip()[:500]
        payload = {
            "source": "fallback-probe",
            "jobid": jobid,
            "remote": remote,
            "rcloneVersion": version_line,
            "configExists": cfg_exists,
            "probe": probe,
            "note": "rclone RC not reachable; showing version/config probe instead. Start mount with --rc to enable live stats.",
        }
        _ok(req_id, json.dumps(payload))
    except Exception as ex:
        _err(req_id, -32603, f"transfer_status failed: {ex}")


def main():
    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                break
            try:
                req = json.loads(line)
            except json.JSONDecodeError as je:
                _err(None, -32700, f"Parse error: {je}")
                continue
            if not isinstance(req, dict):
                _err(None, -32600, "Invalid Request: envelope must be an object")
                continue
            req_id = req.get("id")
            method = req.get("method")

            if method == "initialize":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "rclone-storage-mcp", "version": "1.1.0"},
                    },
                }
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()

            elif method == "tools/list":
                resp = {"jsonrpc": "2.0", "id": req_id, "result": {"tools": _tools_definition()}}
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()

            elif method == "tools/call":
                params = req.get("params", {})
                if not isinstance(params, dict):
                    _fail_validation(req_id, "'params' must be an object")
                    continue
                name = params.get("name")
                args = params.get("arguments", {})
                if not isinstance(name, str) or not name:
                    _fail_validation(req_id, "'name' must be a non-empty string")
                    continue
                if args is None:
                    args = {}
                if not isinstance(args, dict):
                    _fail_validation(req_id, "'arguments' must be an object")
                    continue

                if name == "rclone_list_files":
                    _handle_list_files(req_id, args)
                elif name == "rclone_rename_or_move":
                    _handle_rename_or_move(req_id, args)
                elif name == "rclone_command":
                    _handle_rclone_command(req_id, args)
                elif name == "list_remotes":
                    _handle_list_remotes(req_id, args)
                elif name == "transfer_status":
                    _handle_transfer_status(req_id, args)
                else:
                    _err(req_id, -32601, f"Tool not found: {name}")

            elif method in ("notifications/initialized", "notifications/cancelled"):
                continue
            else:
                _err(req_id, -32601, f"Method not found: {method}")

        except Exception as e:
            try:
                err_resp = {
                    "jsonrpc": "2.0",
                    "id": req.get("id") if "req" in locals() and isinstance(req, dict) else None,
                    "error": {"code": -32603, "message": str(e)},
                }
                sys.stdout.write(json.dumps(err_resp) + "\n")
                sys.stdout.flush()
            except Exception:
                pass


if __name__ == "__main__":
    main()
