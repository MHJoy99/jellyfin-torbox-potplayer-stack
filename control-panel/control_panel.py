#!/usr/bin/env python3
"""Local-only Jellyfin stack control panel.

The panel is deliberately stdlib-only so it can run from a quiet pythonw.exe
process at logon. It binds to 127.0.0.1 and never exposes service command
lines, credentials, or filesystem contents through its API.
"""

from __future__ import annotations

import gzip
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit


BASE_DIR = Path(__file__).resolve().parents[1]
CONTROL_DIR = Path(__file__).resolve().parent
LOG_DIR = BASE_DIR / "logs"
LOG_FILE = LOG_DIR / "control-panel.log"
SYNC_LOG_FILE = LOG_DIR / "torbox-smart-sync.log"
PLAYLIST_LOG_FILE = LOG_DIR / "potplayer-launcher.log"
PROXY_LOG_FILE = LOG_DIR / "torbox-proxy.log"
BRIDGE_LOG_FILE = LOG_DIR / "potplayer-bridge.log"
RCLONE_LOG_FILE = LOG_DIR / "rclone-gdrive.log"
GDRIVE_SYNC_LOG_FILE = LOG_DIR / "gdrive-library-sync.log"
PANEL_PORT = 18080

# Tail-bytes budget for log reads; files larger than this are never read fully.
_TAIL_BYTES = 64 * 1024
# Cache TTLs (seconds).
_PROCESS_TTL_SECONDS = 10.0
# Feature (2): /api/metrics proxies torbox-proxy /metrics with a short 5s cache
# so the panel stays responsive without hammering :8888 on every poll.
_METRICS_TTL_SECONDS = 5.0
# Feature (3/4): timeline pagination + errors-only filter defaults.
_TIMELINE_PAGE_DEFAULT = 1
_TIMELINE_PER_PAGE_DEFAULT = 20
_TIMELINE_PER_PAGE_MAX = 100
# Feature (5): per-service restart allowlist (hardcoded; never accept arbitrary names).
RESTART_ALLOWLIST = frozenset({"jellyfin", "proxy", "bridge", "gdrive", "torboxmount"})
# Feature (9): rate limit for admin/restart endpoints (sliding window per client IP).
_ADMIN_RATE_LIMIT_MAX = 30
_ADMIN_RATE_LIMIT_WINDOW_SECONDS = 60.0
_ADMIN_RATE_BUCKETS: dict[str, list[float]] = {}
_ADMIN_RATE_LOCK = threading.Lock()
# Feature (7): read-only config surface (no secrets, ever).
PANEL_VERSION = "1.0.0"
# Activity quotas: panel[-50] + sync[-30], merged, sorted, sliced.
_ACTIVITY_PANEL_QUOTA = 50
_ACTIVITY_SYNC_QUOTA = 30
# Timeline quotas per source.
_TIMELINE_PROXY_QUOTA = 30
_TIMELINE_BRIDGE_QUOTA = 20
_TIMELINE_SYNC_QUOTA = 30
_TIMELINE_GDRIVE_QUOTA = 10
_TIMELINE_LIMIT_DEFAULT = 80
# Gdrive sync-error alert: warn when >= N [ERROR] lines in last 24h.
_GDRIVE_ERROR_WARN_THRESHOLD = 3
_GDRIVE_SYNC_WINDOW_LINES = 500

_PROCESS_CACHE_LOCK = threading.Lock()
_PROCESS_CACHE_DATA: dict[str, list[dict[str, Any]]] | None = None
_PROCESS_CACHE_TIME = 0.0

_METRICS_CACHE_LOCK = threading.Lock()
_METRICS_CACHE_DATA: dict[str, Any] | None = None
_METRICS_CACHE_TIME = 0.0

# Live proxy metrics (primary source; log scan is fallback only).
PROXY_METRICS_URL = "http://127.0.0.1:8888/metrics"
_PROXY_METRICS_TIMEOUT = 3.0
_STORM_ACTIVE_STREAMS = 6
_PREV_TORBOX_502: int | None = None
_PREV_REQUESTDL_RATELIMITED: int | None = None

# TorBox rclone RC for VFS/disk-cache stats (T:\ mount, no auth, POST-only).
TORBOX_VFS_RC_URL = "http://127.0.0.1:5572/vfs/stats"
_TORBOX_VFS_TIMEOUT = 3.0

SERVER_DIR = BASE_DIR / "server"
JELLYFIN_EXE = SERVER_DIR / "jellyfin.exe"
FFMPEG_EXE = SERVER_DIR / "ffmpeg.exe"
WEB_DIR = SERVER_DIR / "jellyfin-web"
DATA_DIR = BASE_DIR / "data"
CONFIG_DIR = BASE_DIR / "config"
CACHE_DIR = BASE_DIR / "cache"
TRANScode_DIR = BASE_DIR / "transcodes"
TORBOX_PROXY_SCRIPT = SERVER_DIR / "torbox-proxy.py"
BRIDGE_SCRIPT = Path(r"E:\MediaServer\tools\potplayer_http_bridge.py")
TORBOX_SYNC_TASK = "MediaServer_TorboxSmartSync"

SERVICES = {
    "jellyfin": {
        "name": "Jellyfin",
        "port": 8096,
        "health": "http://127.0.0.1:8096/System/Info/Public",
        "process_regex": "jellyfin\\.exe",
        "task": None,
    },
    "proxy": {
        "name": "TorBox Proxy",
        "port": 8888,
        "health": "http://127.0.0.1:8888/health",
        "process_regex": "torbox-proxy\\.py",
        "task": "TorboxProxy",
    },
    "bridge": {
        "name": "PotPlayer Bridge",
        "port": 18099,
        "health": "http://127.0.0.1:18099/health",
        "process_regex": "potplayer_http_bridge\\.py",
        "task": "MediaServer_PotPlayerBridge",
    },
    "gdrive": {
        "name": "Google Drive Mount",
        "port": None,
        "kind": "mount",
        "mount_path": r"F:\Media",
        "alias_path": "R:\\",
        "process_regex": "mount gdrive-media",
        "nssm_service": "RcloneGdriveMount",
    },
    "torboxmount": {
        "name": "TorBox Mount",
        "port": None,
        "kind": "mount",
        "mount_path": "T:\\",
        "process_regex": "mount torbox",
        "start_script": r"E:\MediaServer\mount-torbox.ps1",
    },
}

_ACTION_LOCK_TIMEOUT = 60.0
_ACTION_LOCKS: dict[str, threading.Lock] = {
    "proxy": threading.Lock(),
    "bridge": threading.Lock(),
    "panel": threading.Lock(),
    "mount": threading.Lock(),
    "sync": threading.Lock(),
}


class ActionBusyError(Exception):
    """Raised when a per-service action lock is held past the timeout."""

    def __init__(self, service: str, action: str, message: str | None = None) -> None:
        self.service = service
        self.action = action
        super().__init__(message or f"Service '{service}' is busy (action '{action}' already running)")


def _action_buckets_for(service: str) -> list[str]:
    """Map an /api/action service to its per-service lock bucket(s)."""
    if service == "proxy":
        return ["proxy"]
    if service == "bridge":
        return ["bridge"]
    if service in ("gdrive", "torboxmount"):
        return ["mount"]
    if service == "torbox-sync":
        return ["sync"]
    if service in ("jellyfin", "panel"):
        return ["panel"]
    if service == "all":
        # Stack-wide action touches every bucket; acquire all in sorted order.
        return ["bridge", "mount", "panel", "proxy", "sync"]
    # Unknown service: serialize on panel so validation stays single-flight.
    return ["panel"]


def _acquire_action_locks(service: str, action: str) -> list[str]:
    """Acquire per-service lock(s) with 60s total timeout; log waits."""
    buckets = _action_buckets_for(service)
    acquired: list[str] = []
    deadline = time.monotonic() + _ACTION_LOCK_TIMEOUT
    try:
        for bucket in buckets:
            lock = _ACTION_LOCKS[bucket]
            if lock.locked():
                append_log(f"Action {action} for {service} waiting on '{bucket}' lock")
            start = time.monotonic()
            remaining = max(0.0, deadline - time.monotonic())
            if not lock.acquire(timeout=remaining):
                raise ActionBusyError(service, action)
            waited = time.monotonic() - start
            if waited > 0.1:
                append_log(f"Action {action} for {service} waited {waited:.1f}s for '{bucket}' lock")
            acquired.append(bucket)
    except BaseException:
        for bucket in reversed(acquired):
            try:
                _ACTION_LOCKS[bucket].release()
            except RuntimeError:
                pass
        raise
    return acquired


def _release_action_locks(buckets: list[str]) -> None:
    for bucket in reversed(buckets):
        try:
            _ACTION_LOCKS[bucket].release()
        except RuntimeError:
            pass
PLAYLIST_RESULT_RE = re.compile(
    r"^\[(?P<timestamp>[^]]+)\]\s+PLAYLIST:\s+local=(?P<local>\d+),\s+"
    r"rclone=(?P<rclone>\d+),\s+jellyfin=(?P<jellyfin>\d+),\s+"
    r"final=(?P<final>\d+),\s+selected=(?P<selected>\d+),\s+file=(?P<file>.+)$"
)
PLAYLIST_LAUNCH_RE = re.compile(
    r"^\[(?P<timestamp>[^]]+)\]\s+PLAYLIST:\s+launching reliable season playlist\s+(?P<file>.+)$"
)


def now_text() -> str:
    return datetime.now().strftime("%H:%M:%S")


def append_log(message: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    try:
        with LOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError:
        pass


def hidden_creation_kwargs() -> dict[str, Any]:
    kwargs: dict[str, Any] = {}
    if os.name == "nt":
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        startupinfo = subprocess.STARTUPINFO()
        startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startupinfo.wShowWindow = 0
        kwargs["startupinfo"] = startupinfo
    return kwargs


def run_hidden(command: list[str], timeout: float = 10) -> tuple[int, str, str]:
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            **hidden_creation_kwargs(),
        )
        return result.returncode, result.stdout or "", result.stderr or ""
    except Exception as exc:
        return 1, "", str(exc)


def spawn_hidden(command: list[str], cwd: Path | None = None) -> bool:
    try:
        kwargs = hidden_creation_kwargs()
        kwargs.update({
            "stdin": subprocess.DEVNULL,
            "stdout": subprocess.DEVNULL,
            "stderr": subprocess.DEVNULL,
        })
        if cwd:
            kwargs["cwd"] = str(cwd)
        subprocess.Popen(command, **kwargs)
        return True
    except Exception as exc:
        append_log(f"Background launch failed: {type(exc).__name__}")
        return False


def _empty_processes() -> dict[str, list[dict[str, Any]]]:
    return {key: [] for key in SERVICES}


def _scan_processes() -> dict[str, list[dict[str, Any]]]:
    """Uncached PowerShell process scan; returns only safe fields."""
    result: dict[str, list[dict[str, Any]]] = _empty_processes()
    powershell = r"""
$listeners = @(netstat -ano -p tcp 2>$null |
  Select-String '^\s*TCP\s+127\.0\.0\.1:(8096|8888|18099)\s+0\.0\.0\.0:0\s+LISTENING\s+\d+\s*$' |
  ForEach-Object {
    $parts = ($_.Line.Trim() -split '\s+')
    [PSCustomObject]@{ LocalPort=[int](($parts[1] -split ':')[-1]); OwningProcess=[int]$parts[4] }
  })
 $items = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    ($_.Name -match '^(jellyfin|python|pythonw|rclone)\.exe$') -and
    ($_.CommandLine -match 'jellyfin\.exe|torbox-proxy\.py|potplayer_http_bridge\.py|mount gdrive-media|mount torbox')
  } |
  ForEach-Object {
    $proc = $_
    $service = if ($proc.CommandLine -match 'mount gdrive-media') { 'gdrive' } elseif ($proc.CommandLine -match 'mount torbox') { 'torboxmount' } elseif ($proc.CommandLine -match 'torbox-proxy\.py') { 'proxy' } elseif ($proc.CommandLine -match 'potplayer_http_bridge\.py') { 'bridge' } else { 'jellyfin' }
    $port = if ($service -eq 'proxy') { 8888 } elseif ($service -eq 'bridge') { 18099 } elseif ($service -eq 'jellyfin') { 8096 } else { 0 }
    $isListening = [bool](@($listeners | Where-Object { $_.LocalPort -eq $port -and $_.OwningProcess -eq $proc.ProcessId }).Count)
    [PSCustomObject]@{ ProcessId=$proc.ProcessId; Name=$proc.Name; CreationDate=$proc.CreationDate; Service=$service; Listening=$isListening }
  })
$items | ConvertTo-Json -Compress
"""
    code, stdout, _ = run_hidden(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", powershell])
    if code != 0 or not stdout.strip():
        return result
    try:
        parsed = json.loads(stdout)
        rows = parsed if isinstance(parsed, list) else [parsed]
    except (json.JSONDecodeError, TypeError):
        return result

    for row in rows:
        if not isinstance(row, dict):
            continue
        service = str(row.get("Service") or "").lower()
        item = {
            "pid": int(row.get("ProcessId") or 0),
            "name": str(row.get("Name") or ""),
            "created": str(row.get("CreationDate") or ""),
            "listening": bool(row.get("Listening")),
        }
        if service in result:
            result[service].append(item)
    for key, rows in result.items():
        listening = [row for row in rows if row.get("listening")]
        if listening:
            result[key] = listening
    return result


def _copy_processes(data: dict[str, list[dict[str, Any]]]) -> dict[str, list[dict[str, Any]]]:
    return {key: [dict(row) for row in rows] for key, rows in data.items()}


def query_processes() -> dict[str, list[dict[str, Any]]]:
    """Cached process scan (10s TTL). Returns only safe process fields."""
    global _PROCESS_CACHE_DATA, _PROCESS_CACHE_TIME
    now = time.monotonic()
    with _PROCESS_CACHE_LOCK:
        if _PROCESS_CACHE_DATA is not None and (now - _PROCESS_CACHE_TIME) < _PROCESS_TTL_SECONDS:
            return _copy_processes(_PROCESS_CACHE_DATA)
    fresh = _scan_processes()
    with _PROCESS_CACHE_LOCK:
        _PROCESS_CACHE_DATA = _copy_processes(fresh)
        _PROCESS_CACHE_TIME = time.monotonic()
    return fresh


def peek_processes() -> dict[str, list[dict[str, Any]]]:
    """Return cached processes without scanning (for ?light=1 fast path)."""
    with _PROCESS_CACHE_LOCK:
        if _PROCESS_CACHE_DATA is not None:
            return _copy_processes(_PROCESS_CACHE_DATA)
    return _empty_processes()


def http_probe(url: str, timeout: float = 2.5) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": "Jellyfin-Control-Panel/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(4096).decode("utf-8", errors="replace")
            return {"ok": 200 <= response.status < 400, "code": response.status, "body": body}
    except urllib.error.HTTPError as exc:
        return {"ok": False, "code": exc.code, "body": ""}
    except Exception:
        return {"ok": False, "code": 0, "body": ""}


def bridge_player_status() -> dict[str, Any]:
    probe = http_probe("http://127.0.0.1:18099/status")
    if not probe["ok"]:
        return {"running": False, "process": None}
    try:
        data = json.loads(probe["body"])
        return {"running": bool(data.get("player_running")), "process": data.get("player_process")}
    except (json.JSONDecodeError, AttributeError):
        return {"running": False, "process": None}


def service_status(processes: dict[str, list[dict[str, Any]]], light: bool = False) -> dict[str, dict[str, Any]]:
    payload: dict[str, dict[str, Any]] = {}
    gdrive_info: dict[str, Any] | None = None
    if not light:
        try:
            gdrive_info = _gdrive_sync_errors_24h()
        except Exception:
            gdrive_info = None
    gdrive_count = 0
    gdrive_last: str | None = None
    if isinstance(gdrive_info, dict):
        try:
            gdrive_count = int(gdrive_info.get("count") or 0)
        except (TypeError, ValueError):
            gdrive_count = 0
        raw_last = gdrive_info.get("last")
        gdrive_last = str(raw_last)[:200] if isinstance(raw_last, str) and raw_last else None
    for key, config in SERVICES.items():
        matched = processes.get(key, [])
        is_mount = config.get("kind") == "mount"
        probe = {"ok": False, "code": 0, "body": ""}
        if is_mount:
            path_ok = os.path.isdir(config["mount_path"])
            alias_ok = bool(config.get("alias_path")) and os.path.isdir(config["alias_path"])
            if path_ok and matched:
                state = "healthy"
                state_label = "Healthy"
                suffix = f" + {config['alias_path']} alias" if alias_ok else ""
                detail = f"Serving {config['mount_path']}{suffix}"
                if key == "gdrive" and not light and gdrive_count >= _GDRIVE_ERROR_WARN_THRESHOLD:
                    state = "warning"
                    state_label = "Sync errors"
                    last_shown = (gdrive_last or "unknown error")[:200]
                    detail = f"{gdrive_count} gdrive sync errors in last 24h; last: {last_shown}"
            elif matched and not path_ok:
                state = "starting"
                state_label = "Starting"
                detail = "rclone process present; waiting for the mount path"
            elif path_ok and not matched:
                state = "warning"
                state_label = "No process"
                detail = f"{config['mount_path']} visible but no rclone mount process found"
            else:
                state = "stopped"
                state_label = "Stopped"
                detail = f"{config['mount_path']} is not mounted"
        else:
            probe = http_probe(config["health"])
            healthy = bool(probe["ok"])
            duplicate = key == "proxy" and len(matched) > 1
            if healthy and duplicate:
                state = "warning"
                state_label = "Duplicate process"
                detail = f"Responding, but {len(matched)} proxy processes are active"
            elif healthy:
                state = "healthy"
                state_label = "Healthy"
                detail = f"Responding on 127.0.0.1:{config['port']}"
            elif matched:
                state = "starting"
                state_label = "Starting"
                detail = "Process is present; waiting for the service port"
            else:
                state = "stopped"
                state_label = "Stopped"
                detail = f"Nothing listening on 127.0.0.1:{config['port']}"

        item: dict[str, Any] = {
            "id": key,
            "name": config["name"],
            "port": config["port"],
            "mount_path": config.get("mount_path"),
            "state": state,
            "state_label": state_label,
            "detail": detail,
            "process_count": len(matched),
            "pids": [row["pid"] for row in matched if row.get("pid")],
            "last_code": probe["code"],
        }
        if key == "bridge":
            item["player"] = bridge_player_status() if healthy else {"running": False, "process": None}
        if key == "jellyfin" and healthy:
            try:
                info = json.loads(probe["body"])
                item["version"] = info.get("Version")
                item["server_name"] = info.get("ServerName")
            except (json.JSONDecodeError, AttributeError):
                pass
        payload[key] = item
    return payload


SYNC_LINE_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(?:\[[^\]]+\]\s*)?(?:torbox_smart_sync:\s*)?([\s\S]*)$"
)


def _format_sync_line(line: str) -> str | None:
    match = SYNC_LINE_RE.match(line.strip())
    if not match:
        return None
    timestamp, message = match.group(1), match.group(2).strip()
    if not message:
        return None
    return f"[{timestamp}] Sync: {message}"


def read_log_lines(log_file: Path, limit: int) -> list[str]:
    """Tail-bytes reader: seek last 64KB instead of full read for large logs."""
    if limit <= 0:
        return []
    try:
        size = log_file.stat().st_size
    except OSError:
        return []
    if size <= 0:
        return []
    try:
        if size <= _TAIL_BYTES:
            lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines()
            return lines[-limit:]
        # Large file: read trailing window, expanding only if too few lines.
        window = _TAIL_BYTES
        while True:
            with log_file.open("rb") as handle:
                handle.seek(max(0, size - window))
                raw = handle.read()
            text = raw.decode("utf-8", errors="replace")
            lines = text.splitlines()
            # Drop a possibly-truncated first line when we started mid-file.
            if window < size and lines:
                lines = lines[1:]
            if len(lines) >= limit or window >= size:
                return lines[-limit:]
            window = min(size, window * 2)
            if window > 2 * 1024 * 1024:
                return lines[-limit:]
    except OSError:
        return []


def read_activity(limit: int = 80) -> list[str]:
    panel_lines = read_log_lines(LOG_FILE, _ACTIVITY_PANEL_QUOTA)
    sync_lines: list[str] = []
    for raw in read_log_lines(SYNC_LOG_FILE, _ACTIVITY_SYNC_QUOTA):
        formatted = _format_sync_line(raw)
        if formatted:
            sync_lines.append(formatted)
    combined = panel_lines + sync_lines

    def _sort_key(line: str) -> str:
        match = re.match(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]", line)
        return match.group(1) if match else ""

    combined.sort(key=_sort_key)
    return combined[-limit:]


def parse_log_timestamp(value: str) -> tuple[str | None, int | None]:
    try:
        parsed = datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None, None
    age_seconds = max(0, int((datetime.now() - parsed).total_seconds()))
    return parsed.isoformat(timespec="seconds"), age_seconds


_BRACKET_TS_RE = re.compile(r"^\[(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s*(?P<msg>[\s\S]*)$")
_VFS_RE = re.compile(r"objects\s+(?P<objects>\d+).*total size\s+(?P<size>[^\s,\)]+)", re.IGNORECASE)


def _timeline_level(message: str) -> str:
    lowered = message.lower()
    if "errors: 0" in lowered:
        # "Errors: 0" is a healthy sync summary, not an error.
        return "info"
    if " 502" in f" {lowered}" or "code 502" in lowered or "cdn unavailable" in lowered or "stream error" in lowered or "failed" in lowered or "traceback" in lowered:
        return "error"
    if "429" in lowered or "rate-limit" in lowered or "retry" in lowered or "warning" in lowered or " warn" in f" {lowered}":
        return "warning"
    return "info"


def _timeline_entry(raw_ts: str | None, source: str, message: str) -> dict[str, Any] | None:
    text = (message or "").strip()
    if not text:
        return None
    iso: str | None = None
    sort_key = ""
    if raw_ts:
        iso_val, _ = parse_log_timestamp(raw_ts)
        iso = iso_val or raw_ts.replace(" ", "T")
        sort_key = raw_ts
    else:
        iso = None
    return {"ts": iso, "source": source, "level": _timeline_level(text), "msg": text, "_sort": sort_key}


def _parse_proxy_timeline_line(line: str) -> dict[str, Any] | None:
    stripped = line.strip()
    if not stripped:
        return None
    match = _BRACKET_TS_RE.match(stripped)
    if not match:
        return None
    raw_ts, message = match.group("ts"), match.group("msg").strip()
    if not message:
        return None
    lowered = message.lower()
    # Keep timeline signal-dense: CDN status / 502 / rate-limit / stream errors only.
    if not (
        "cdn status" in lowered
        or " 502" in f" {lowered}"
        or "code 502" in lowered
        or "requestdl" in lowered
        or "rate-limited" in lowered
        or "stream error" in lowered
    ):
        return None
    return _timeline_entry(raw_ts, "proxy", message)


def _parse_bridge_timeline_line(line: str) -> dict[str, Any] | None:
    stripped = line.strip()
    if not stripped:
        return None
    match = _BRACKET_TS_RE.match(stripped)
    if not match:
        return None
    raw_ts, message = match.group("ts"), match.group("msg").strip()
    if not message:
        return None
    lowered = message.lower()
    if "handling play request" not in lowered and "play request" not in lowered:
        return None
    return _timeline_entry(raw_ts, "bridge", message)


def _parse_sync_timeline_line(line: str) -> dict[str, Any] | None:
    formatted = _format_sync_line(line)
    if not formatted:
        return None
    match = _BRACKET_TS_RE.match(formatted)
    if not match:
        return None
    return _timeline_entry(match.group("ts"), "sync", match.group("msg"))


def read_timeline(limit: int = _TIMELINE_LIMIT_DEFAULT, include_gdrive: bool = True) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    # Proxy log is high-volume (Range/206 noise); scan a wider window so the
    # CDN status / 502 / rate-limit filter can still fill its quota.
    for raw in read_log_lines(PROXY_LOG_FILE, 600):
        item = _parse_proxy_timeline_line(raw)
        if item:
            entries.append(item)
    # Enforce per-source quotas before merge (keep newest per source).
    by_source: dict[str, list[dict[str, Any]]] = {"proxy": [], "bridge": [], "sync": [], "gdrive": []}
    for entry in entries:
        by_source.setdefault(str(entry.get("source") or "proxy"), []).append(entry)
    # Bridge play lines.
    bridge_items: list[dict[str, Any]] = []
    for raw in read_log_lines(BRIDGE_LOG_FILE, _TIMELINE_BRIDGE_QUOTA * 4):
        item = _parse_bridge_timeline_line(raw)
        if item:
            bridge_items.append(item)
    by_source["bridge"] = bridge_items
    # Sync lines.
    sync_items: list[dict[str, Any]] = []
    for raw in read_log_lines(SYNC_LOG_FILE, _TIMELINE_SYNC_QUOTA * 2):
        item = _parse_sync_timeline_line(raw)
        if item:
            sync_items.append(item)
    by_source["sync"] = sync_items
    # Gdrive library-sync errors in last 24h (skipped on ?light=1 fast path).
    gdrive_items: list[dict[str, Any]] = []
    if include_gdrive:
        try:
            gdrive_info = _gdrive_sync_errors_24h()
            raw_items = gdrive_info.get("entries") if isinstance(gdrive_info, dict) else []
            if isinstance(raw_items, list):
                gdrive_items = [e for e in raw_items if isinstance(e, dict)]
        except Exception:
            gdrive_items = []
    by_source["gdrive"] = gdrive_items
    by_source["proxy"] = sorted(by_source.get("proxy", []), key=lambda e: str(e.get("_sort") or ""))[-_TIMELINE_PROXY_QUOTA:]
    by_source["bridge"] = sorted(by_source.get("bridge", []), key=lambda e: str(e.get("_sort") or ""))[-_TIMELINE_BRIDGE_QUOTA:]
    by_source["sync"] = sorted(by_source.get("sync", []), key=lambda e: str(e.get("_sort") or ""))[-_TIMELINE_SYNC_QUOTA:]
    by_source["gdrive"] = sorted(by_source.get("gdrive", []), key=lambda e: str(e.get("_sort") or ""))[-_TIMELINE_GDRIVE_QUOTA:]
    merged = [item for items in by_source.values() for item in items]
    merged.sort(key=lambda e: str(e.get("_sort") or ""))
    trimmed = merged[-limit:] if limit > 0 else []
    for item in trimmed:
        item.pop("_sort", None)
    return trimmed


def _scan_proxy_counters(window_lines: int = 5000) -> dict[str, Any]:
    total_502 = 0
    recent_502_10m = 0
    total_429 = 0
    ratelimited = 0
    now = datetime.now()
    for raw in read_log_lines(PROXY_LOG_FILE, window_lines):
        match = _BRACKET_TS_RE.match(raw.strip())
        if not match:
            continue
        raw_ts, message = match.group("ts"), match.group("msg")
        lowered = message.lower()
        try:
            parsed = datetime.strptime(raw_ts, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            parsed = None
        is_502 = ("code 502" in lowered) or ('"get ' in lowered and " 502 " in f" {lowered} ") or lowered.strip().endswith(" 502 -") or (" 502 -" in lowered)
        # Fallback: any standalone 502 token in a proxy status line.
        if not is_502 and re.search(r"\b502\b", message):
            is_502 = True
        if is_502:
            total_502 += 1
            if parsed is not None and (now - parsed).total_seconds() <= 600 and (now - parsed).total_seconds() >= 0:
                recent_502_10m += 1
        if "cdn status=429" in lowered or re.search(r"\b429\b", message):
            total_429 += 1
        if "requestdl" in lowered and "rate-limited" in lowered:
            ratelimited += 1
    return {
        "total_502": total_502,
        "recent_502_10m": recent_502_10m,
        "total_429": total_429,
        "requestdl_ratelimited": ratelimited,
    }


def _sync_last_info() -> dict[str, Any]:
    last_ts: str | None = None
    last_iso: str | None = None
    last_age: int | None = None
    for raw in read_log_lines(SYNC_LOG_FILE, 60):
        match = SYNC_LINE_RE.match(raw.strip())
        if not match:
            continue
        candidate = match.group(1)
        iso_val, age_val = parse_log_timestamp(candidate)
        if iso_val is not None:
            last_ts, last_iso, last_age = candidate, iso_val, age_val
    return {"last_run": last_iso, "age_seconds": last_age}


def _vfs_info() -> dict[str, Any]:
    objects: int | None = None
    size: str | None = None
    raw_line: str | None = None
    for raw in read_log_lines(RCLONE_LOG_FILE, 60):
        match = _VFS_RE.search(raw)
        if match:
            try:
                objects = int(match.group("objects"))
            except ValueError:
                objects = None
            size = match.group("size").strip()
            raw_line = raw.strip()[-240:]
    return {"vfs_objects": objects, "vfs_size": size, "raw": raw_line}


def _torbox_vfs_nulls() -> dict[str, Any]:
    return {"bytes_used": None, "files": None, "dirs": None, "age_s": None}


def _safe_int_or_none(value: Any) -> int | None:
    try:
        if value is None:
            return None
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            if value != value or value in (float("inf"), float("-inf")):
                return None
            return int(value)
        if isinstance(value, str):
            text = value.strip()
            if not text:
                return None
            return int(float(text))
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError, OverflowError):
        return None


def _vfs_section(data: dict[str, Any], *names: str) -> dict[str, Any]:
    """Case-insensitive section lookup; returns {} when missing/not-a-dict."""
    if not isinstance(data, dict):
        return {}
    lowered = {str(k).lower(): v for k, v in data.items()}
    for name in names:
        candidate = lowered.get(name.lower())
        if isinstance(candidate, dict):
            return candidate
    return {}


def _vfs_first_int(*candidates: Any) -> int | None:
    for candidate in candidates:
        parsed = _safe_int_or_none(candidate)
        if parsed is not None:
            return parsed
    return None


def _fetch_torbox_vfs(timeout: float = _TORBOX_VFS_TIMEOUT) -> dict[str, Any]:
    """POST-only rclone RC /vfs/stats query for the TorBox T:\\ mount.

    No auth, empty JSON body, 3s timeout. Parses defensively across rclone
    versions: bytes from diskCache.bytesUsed variants, files from
    diskCache.files (fallback to metadataCache.files, pairs with bytes_used),
    dirs from metadataCache. Returns nulls on any failure so get_metrics()
    stays backward compatible.
    """
    nulls = _torbox_vfs_nulls()
    try:
        body = json.dumps({}).encode("utf-8")
        request = urllib.request.Request(
            TORBOX_VFS_RC_URL,
            data=body,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "Jellyfin-Control-Panel/1.0",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(65536).decode("utf-8", errors="replace")
        data = json.loads(raw)
    except Exception:
        return nulls
    if not isinstance(data, dict):
        return nulls
    try:
        disk = _vfs_section(data, "diskCache")
        meta = _vfs_section(data, "metadataCache", "metadata", "dirCache")
        bytes_used = _vfs_first_int(
            disk.get("bytesUsed"),
            disk.get("bytes_used"),
            disk.get("bytesused"),
            disk.get("BytesUsed"),
            data.get("bytesUsed"),
            data.get("bytes_used"),
        )
        files = _vfs_first_int(
            disk.get("files"),
            disk.get("Files"),
            meta.get("files"),
            meta.get("Files"),
            data.get("files"),
        )
        dirs = _vfs_first_int(
            meta.get("dirs"),
            meta.get("Dirs"),
            meta.get("directories"),
            data.get("dirs"),
        )
        if bytes_used is None and files is None and dirs is None:
            return nulls
        return {"bytes_used": bytes_used, "files": files, "dirs": dirs, "age_s": 0}
    except Exception:
        return nulls


def _format_cache_bytes(value: Any) -> str | None:
    """Human-readable binary formatting for the torboxmount detail line."""
    parsed = _safe_int_or_none(value)
    if parsed is None or parsed < 0:
        return None
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    size = float(parsed)
    index = 0
    while size >= 1024.0 and index < len(units) - 1:
        size /= 1024.0
        index += 1
    if index == 0:
        return f"{parsed} B"
    return f"{size:.1f} {units[index]}"


def _sanitize_gdrive_error(message: str) -> str:
    """Collapse whitespace and truncate to 200 chars for safe API exposure."""
    text = re.sub(r"\s+", " ", (message or "").strip())
    return text[:200]


def _gdrive_sync_errors_24h(window_lines: int = _GDRIVE_SYNC_WINDOW_LINES) -> dict[str, Any]:
    """Parse gdrive-library-sync.log tail for [ERROR] lines in the last 24h.

    Reuses the tail-bytes reader (read_log_lines) so large logs are never
    read fully. Returns {"count": int, "last": str|None, "entries": [...]},
    where entries are timeline-ready dicts (with _sort) sorted ascending.
    """
    now = datetime.now()
    entries: list[dict[str, Any]] = []
    try:
        lines = read_log_lines(GDRIVE_SYNC_LOG_FILE, window_lines)
    except Exception:
        lines = []
    for raw in lines:
        stripped = (raw or "").strip()
        if not stripped:
            continue
        match = _BRACKET_TS_RE.match(stripped)
        if not match:
            continue
        raw_ts, message = match.group("ts"), (match.group("msg") or "").strip()
        if "[ERROR]" not in message:
            continue
        try:
            parsed = datetime.strptime(raw_ts, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue
        age_seconds = (now - parsed).total_seconds()
        if age_seconds < 0 or age_seconds > 86400:
            continue
        sanitized = _sanitize_gdrive_error(message)
        if not sanitized:
            continue
        item = _timeline_entry(raw_ts, "gdrive", sanitized)
        if item:
            entries.append(item)
    entries.sort(key=lambda e: str(e.get("_sort") or ""))
    count = len(entries)
    last: str | None = str(entries[-1].get("msg") or "")[:200] if entries else None
    return {"count": count, "last": last, "entries": entries}


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _fetch_proxy_live_metrics(timeout: float = _PROXY_METRICS_TIMEOUT) -> dict[str, Any] | None:
    """Fetch proxy /metrics as the primary source (localhost, no CORS).

    Returns the decoded JSON dict on success, else None so callers can
    fall back to the 5000-line log scan.
    """
    try:
        request = urllib.request.Request(
            PROXY_METRICS_URL, headers={"User-Agent": "Jellyfin-Control-Panel/1.0"}
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(65536).decode("utf-8", errors="replace")
        data = json.loads(raw)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _proxy_counters_from_live(live: dict[str, Any]) -> dict[str, Any]:
    """Map live /metrics snapshot onto legacy logscan keys + live extras."""
    torbox = live.get("torbox") if isinstance(live.get("torbox"), dict) else {}
    gdrive = live.get("gdrive") if isinstance(live.get("gdrive"), dict) else {}
    cdn_retry = live.get("cdn_retry") if isinstance(live.get("cdn_retry"), dict) else {}
    requestdl = live.get("requestdl") if isinstance(live.get("requestdl"), dict) else {}
    try:
        active_streams = int(live.get("active_streams") or 0)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        active_streams = 0
    uptime_s = live.get("uptime_s")
    try:
        uptime_s = float(uptime_s) if uptime_s is not None else None  # type: ignore[arg-type]
    except (TypeError, ValueError):
        uptime_s = None
    started_iso = live.get("started_iso")
    if not isinstance(started_iso, str):
        started_iso = None
    return {
        # Legacy keys (backward compatible): totals come from live counters.
        "total_502": _safe_int(torbox.get("502")),
        # recent_502_10m is filled by get_metrics() as delta-since-last-sample.
        "total_429": _safe_int(torbox.get("429")),
        "requestdl_ratelimited": _safe_int(requestdl.get("ratelimited")),
        # Live extras (additive; None-safe for consumers).
        "active_streams": active_streams,
        "uptime_s": uptime_s,
        "started_iso": started_iso,
        "torbox": {str(k): _safe_int(v) for k, v in torbox.items()},
        "gdrive": {str(k): _safe_int(v) for k, v in gdrive.items()},
        "cdn_retry": {str(k): _safe_int(v) for k, v in cdn_retry.items()},
        "requestdl": {
            str(k): (_safe_int(v) if k != "last_age_s" else v) for k, v in requestdl.items()
        },
    }


def get_metrics(include_gdrive: bool = True) -> dict[str, Any]:
    global _METRICS_CACHE_DATA, _METRICS_CACHE_TIME
    global _PREV_TORBOX_502, _PREV_REQUESTDL_RATELIMITED
    now = time.monotonic()
    with _METRICS_CACHE_LOCK:
        if _METRICS_CACHE_DATA is not None and (now - _METRICS_CACHE_TIME) < _METRICS_TTL_SECONDS:
            # Light fast path reuses the cached payload without extra log I/O.
            return dict(_METRICS_CACHE_DATA)
    live = _fetch_proxy_live_metrics(timeout=_PROXY_METRICS_TIMEOUT)
    sync = _sync_last_info()
    mount = _vfs_info()
    if include_gdrive:
        try:
            torbox_vfs = _fetch_torbox_vfs(timeout=_TORBOX_VFS_TIMEOUT)
        except Exception:
            torbox_vfs = _torbox_vfs_nulls()
        if not isinstance(torbox_vfs, dict):
            torbox_vfs = _torbox_vfs_nulls()
    else:
        # Light fast path (?light=1): skip RC entirely, no extra call per poll.
        torbox_vfs = _torbox_vfs_nulls()
    if include_gdrive:
        try:
            _ginfo = _gdrive_sync_errors_24h()
        except Exception:
            _ginfo = {"count": 0, "last": None}
        try:
            gdrive_count = int((_ginfo.get("count") if isinstance(_ginfo, dict) else 0) or 0)
        except (TypeError, ValueError):
            gdrive_count = 0
        _raw_last = _ginfo.get("last") if isinstance(_ginfo, dict) else None
        gdrive_last: str | None = str(_raw_last)[:200] if isinstance(_raw_last, str) and _raw_last else None
    else:
        gdrive_count = 0
        gdrive_last = None
    if live is not None:
        source = "live"
        proxy = _proxy_counters_from_live(live)
        cur_502 = int(proxy.get("total_502") or 0)
        cur_ratelimited = int(proxy.get("requestdl_ratelimited") or 0)
        try:
            active = int(proxy.get("active_streams") or 0)
        except (TypeError, ValueError):
            active = 0
        if _PREV_TORBOX_502 is None:
            delta_502 = 0
        else:
            delta_502 = max(0, cur_502 - int(_PREV_TORBOX_502))
        if _PREV_REQUESTDL_RATELIMITED is None:
            delta_ratelimited = 0
        else:
            delta_ratelimited = max(0, cur_ratelimited - int(_PREV_REQUESTDL_RATELIMITED))
        _PREV_TORBOX_502 = cur_502
        _PREV_REQUESTDL_RATELIMITED = cur_ratelimited
        # Backward-compatible "recent" slot carries the since-last-sample delta.
        proxy["recent_502_10m"] = delta_502
        proxy["requestdl_ratelimited_delta"] = delta_ratelimited
        if delta_502 > 0 or delta_ratelimited > 0 or active > _STORM_ACTIVE_STREAMS:
            proxy_state = "warning"
        else:
            proxy_state = "healthy"
        proxy["state"] = proxy_state
    else:
        source = "logscan"
        proxy = _scan_proxy_counters()
        # Keep live-only keys present (as None) so /api/status enrichment is stable.
        proxy.setdefault("active_streams", None)
        proxy.setdefault("uptime_s", None)
        proxy.setdefault("started_iso", None)
        proxy_state = "warning" if int(proxy.get("recent_502_10m") or 0) > 0 else "healthy"
        if int(proxy.get("requestdl_ratelimited") or 0) > 0 and proxy_state == "healthy":
            # Rate-limit pressure alone stays healthy; 502s drive the warning.
            proxy_state = "healthy"
        proxy["state"] = proxy_state
    sync_age = sync.get("age_seconds")
    if sync_age is None:
        sync_state = "warning"
    elif int(sync_age) > 86400:
        sync_state = "warning"
    else:
        sync_state = "healthy"
    mount_state = "healthy" if mount.get("vfs_objects") is not None else "warning"
    if include_gdrive and gdrive_count >= _GDRIVE_ERROR_WARN_THRESHOLD:
        mount_state = "warning"
    gdrive_state = "warning" if (include_gdrive and gdrive_count >= _GDRIVE_ERROR_WARN_THRESHOLD) else "healthy"
    overall = "healthy" if all(s == "healthy" for s in (proxy_state, sync_state, mount_state, gdrive_state)) else "warning"
    payload: dict[str, Any] = {
        "proxy": {**proxy, "state": proxy_state},
        "sync": {**sync, "state": sync_state},
        "mount": {**mount, "state": mount_state, "gdrive_error_24h": gdrive_count, "gdrive_last_error": gdrive_last},
        "gdrive": {"error_24h": gdrive_count, "last_error": gdrive_last, "state": gdrive_state},
        "gdrive_error_24h": gdrive_count,
        "gdrive_last_error": gdrive_last,
        "gdrive_last": gdrive_last,
        "torbox_vfs": dict(torbox_vfs),
        "overall": overall,
        "alerts": {
            "proxy": proxy_state,
            "sync": sync_state,
            "mount": mount_state,
            "gdrive": gdrive_state,
        },
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "source": source,
    }
    if include_gdrive:
        with _METRICS_CACHE_LOCK:
            _METRICS_CACHE_DATA = dict(payload)
            _METRICS_CACHE_TIME = time.monotonic()
    return payload


_RELEASE_STOP_TOKENS = frozenset({
    "1080p", "720p", "2160p", "480p", "4k", "uhd", "hd",
    "amzn", "nf", "netflix", "web", "web-dl", "webdl", "webrip", "dl",
    "bluray", "brrip", "bdrip", "hdtv", "pdtv", "dvdrip", "remux",
    "proper", "repack", "rerip", "extended", "complete", "limited",
    "ddp", "dd", "dts", "aac", "ac3", "atmos", "truehd", "eac3",
    "flac", "mp3", "opus", "h264", "h265", "x264", "x265",
    "hevc", "avc", "vp9", "av1", "hdr", "dv", "dolby", "vision",
    "ddp5", "dd5", "ddp51",
})
_SE_EP_RE = re.compile(r"[Ss]0*(\d{1,2})[Ee]\d{1,2}")
_SEASON_ONLY_RE = re.compile(r"(?:^|[\.\s_\-])[Ss]0*(\d{1,2})(?=$|[\.\s_\-])")
_SEASON_WORD_RE = re.compile(r"season\s*0*(\d+)", re.IGNORECASE)
_DRIVE_RE = re.compile(r"^[A-Za-z]:$")
_VIDEO_EXT_RE = re.compile(r"\.(mkv|mp4|avi|strm|ts|m2ts|mov|wmv|flv|m4v)$", re.IGNORECASE)


def _clean_release_show(raw_name: str, is_file: bool = False) -> str | None:
    """Clean a release folder/file name to a show name (no new deps).

    Reuses _sanitize_gdrive_error for whitespace collapse/truncate.
    Dots/underscores -> spaces, stop at first season/release token
    (Sxx, SxxEyy, 1080p, AMZN, WEB-DL, x264, ...), strip trailing
    -Group. Returns None when nothing usable remains.
    """
    try:
        text = _sanitize_gdrive_error(raw_name or "")
    except Exception:
        text = re.sub(r"\s+", " ", (raw_name or "").strip())
    if not text:
        return None
    text = text.strip()
    if is_file:
        text = _VIDEO_EXT_RE.sub("", text)
    # Strip trailing -Group only when release markers are present so
    # hyphenated shows like "Spider-Man" are not mangled.
    if re.search(
        r"(?i)(s\d{1,2}e\d{1,2}|\bs\d{1,2}\b|\d{3,4}p|\b4k\b|web-?dl|webrip|bluray|hdtv|x26[45]|h\.?26[45]|ddp?|amzn|\bseason\b)",
        text,
    ):
        text = re.sub(r"-[A-Za-z0-9]{2,}$", "", text.strip())
    text = text.replace(".", " ").replace("_", " ")
    tokens = [tok for tok in text.split() if tok]
    show_tokens: list[str] = []
    for tok in tokens:
        low = tok.strip("[](){}").lower()
        if not low:
            continue
        if re.fullmatch(r"s\d{1,2}(e\d{1,2})?", low):
            break
        if re.fullmatch(r"\d{3,4}p", low):
            break
        if low in _RELEASE_STOP_TOKENS:
            break
        show_tokens.append(tok.strip("[](){}"))
    show = re.sub(r"\s+", " ", " ".join(show_tokens)).strip(" -")
    if not show:
        return None
    return show[:120] or None


def _season_from_release_texts(*texts: str) -> int | None:
    """Season from SxxEyy first, then standalone Sxx, then 'Season N'."""
    for text in texts:
        if not text:
            continue
        match = _SE_EP_RE.search(text)
        if match:
            try:
                return int(match.group(1))
            except (TypeError, ValueError):
                continue
    for text in texts:
        if not text:
            continue
        match = _SEASON_ONLY_RE.search(text)
        if match:
            try:
                return int(match.group(1))
            except (TypeError, ValueError):
                continue
    for text in texts:
        if not text:
            continue
        match = _SEASON_WORD_RE.search(text)
        if match:
            try:
                return int(match.group(1))
            except (TypeError, ValueError):
                continue
    return None


def playlist_context(media_path: str) -> tuple[str | None, int | None]:
    decoded = unquote(media_path or "")
    if "://" in decoded:
        decoded = urlsplit(decoded).path
    parts = [part for part in decoded.replace("\\", "/").split("/") if part]
    for index, part in enumerate(parts):
        if part.casefold() == "series" and index + 1 < len(parts):
            show = parts[index + 1].strip()
            season_match = (
                re.match(r"season\s*0*(\d+)", parts[index + 2].strip(), re.IGNORECASE)
                if index + 2 < len(parts)
                else None
            )
            return (show or None), int(season_match.group(1)) if season_match else None
    # Proxy URL layout: /torbox/<tid>/<fid>/<Name> — parse Name segment.
    if len(parts) >= 2 and parts[0].casefold() == "torbox":
        name = parts[-1].strip()
        if not name:
            return None, None
        show = _clean_release_show(name, is_file=True)
        season = _season_from_release_texts(name)
        if show is None and season is None:
            return None, None
        return show, season
    # Mount-root layout: T:\<Show.S01...>\<file> — folder gives show,
    # SxxEyy (file first, then folder) gives season.
    if len(parts) >= 2 and _DRIVE_RE.fullmatch(parts[0] or "") and parts[0].casefold() == "t:":
        if len(parts) == 2:
            lone = parts[1].strip()
            return _clean_release_show(lone, is_file=True), _season_from_release_texts(lone)
        folder = parts[1].strip()
        fname = parts[-1].strip()
        show = _clean_release_show(folder, is_file=False)
        if not show:
            show = _clean_release_show(fname, is_file=True)
        season = _season_from_release_texts(fname, folder, "/".join(parts[1:]))
        if show is None and season is None:
            return None, None
        return show, season
    return None, None


_BRIDGE_PLAY_RE = re.compile(
    r"^\[(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s*"
    r"Handling play request:\s*target=(?P<target>.*),\s*item_id=(?P<item_id>[0-9a-fA-F]{8,64})\s*$"
)
# Playback freshness window: a last_play newer than this + PotPlayer running
# means the detail line names WHAT is playing.
_LAST_PLAY_FRESH_SECONDS = 4 * 3600


def _sanitize_bridge_basename(raw_target: str) -> str:
    """Strip CR/LF, keep only the basename (split on / and \\), truncate 120."""
    text = (raw_target or "").replace("\r", "").replace("\n", "").strip()
    parts = [part for part in re.split(r"[\\/]+", text) if part]
    base = parts[-1].strip() if parts else ""
    return base[:120]


def _format_play_age(age_s: int | None) -> str:
    if age_s is None:
        return "unknown ago"
    try:
        age = max(0, int(age_s))
    except (TypeError, ValueError):
        return "unknown ago"
    if age < 60:
        return f"{age}s ago"
    if age < 3600:
        return f"{age // 60}m ago"
    hours, remainder = divmod(age, 3600)
    minutes = remainder // 60
    return f"{hours}h{minutes}m ago" if minutes else f"{hours}h ago"


def read_last_bridge_play() -> dict[str, Any] | None:
    """Parse newest bridge `Handling play request` line via the tail reader.

    Returns only safe fields (basename, no full path):
    {"target_basename", "item_id" (full), "item_id_short" (8-char),
     "started_iso", "age_s", "age_seconds"} or None when no line found.
    """
    newest: dict[str, Any] | None = None
    try:
        lines = read_log_lines(BRIDGE_LOG_FILE, 120)
    except Exception:
        return None
    for raw in lines:
        stripped = (raw or "").strip()
        if not stripped:
            continue
        match = _BRIDGE_PLAY_RE.match(stripped)
        if not match:
            continue
        raw_target = match.group("target") or ""
        raw_item = (match.group("item_id") or "").strip()
        basename = _sanitize_bridge_basename(raw_target)
        if not basename or not raw_item:
            continue
        started_iso, age_s = parse_log_timestamp(match.group("ts"))
        if started_iso is None:
            continue
        newest = {
            "target_basename": basename,
            "item_id": raw_item,
            "item_id_short": raw_item[:8],
            "started_iso": started_iso,
            "age_s": age_s,
            "age_seconds": age_s,
        }
    return newest


def read_playlist_entries(playlist_path: Path) -> tuple[dict[str, Any], ...]:
    try:
        raw = playlist_path.read_text(encoding="utf-16")
    except (OSError, UnicodeError):
        try:
            raw = playlist_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return ()

    entries: dict[int, dict[str, Any]] = {}
    for line in raw.splitlines():
        if "*file*" in line:
            index_text, _, media_path = line.partition("*file*")
            try:
                index = int(index_text)
            except ValueError:
                continue
            entries.setdefault(index, {})["file"] = media_path.strip()
        elif "*title*" in line:
            index_text, _, title = line.partition("*title*")
            try:
                index = int(index_text)
            except ValueError:
                continue
            entries.setdefault(index, {})["title"] = title.strip()
    return tuple(entries[index] for index in sorted(entries) if entries[index].get("file"))


def read_playlist_status(bridge: dict[str, Any], include_last_play: bool = True) -> dict[str, Any]:
    latest_result: re.Match[str] | None = None
    latest_launch: re.Match[str] | None = None
    for line in read_log_lines(PLAYLIST_LOG_FILE, limit=240):
        result_match = PLAYLIST_RESULT_RE.match(line)
        if result_match:
            latest_result = result_match
        launch_match = PLAYLIST_LAUNCH_RE.match(line)
        if launch_match:
            latest_launch = launch_match

    last_play: dict[str, Any] | None = None
    if include_last_play:
        try:
            last_play = read_last_bridge_play()
        except Exception:
            last_play = None

    def _playing_detail(base_detail: str, player: dict[str, Any]) -> str:
        if (
            last_play
            and isinstance(player, dict)
            and player.get("running")
            and isinstance(last_play.get("age_s"), int)
            and 0 <= int(last_play["age_s"]) < _LAST_PLAY_FRESH_SECONDS
            and last_play.get("target_basename")
        ):
            return f"{last_play['target_basename']} ({_format_play_age(int(last_play['age_s']))})"
        return base_detail

    empty: dict[str, Any] = {
        "state": "stopped",
        "state_label": "No run recorded",
        "detail": "No reliable playlist run has been recorded yet",
        "show": None,
        "season": None,
        "entries": 0,
        "selected": None,
        "local_candidates": 0,
        "rclone_candidates": 0,
        "jellyfin_candidates": 0,
        "source_label": "No playlist data",
        "playlist_name": None,
        "last_run": None,
        "age_seconds": None,
        "player": bridge.get("player") or {"running": False, "process": None},
    }
    if latest_result is None:
        if include_last_play:
            empty["last_play"] = last_play
            empty["detail"] = _playing_detail(str(empty["detail"]), empty["player"])  # type: ignore[arg-type]
        return empty

    groups = latest_result.groupdict()
    playlist_path = Path(groups["file"].strip())
    timestamp, age_seconds = parse_log_timestamp(groups["timestamp"])
    expected_entries = int(groups["final"])
    selected = int(groups["selected"])
    playlist_entries = read_playlist_entries(playlist_path) if playlist_path.is_file() else ()
    actual_entries = len(playlist_entries)
    selected_entry = playlist_entries[selected - 1] if 0 < selected <= actual_entries else {}
    show, season = playlist_context(str(selected_entry.get("file") or ""))
    local_candidates = int(groups["local"])
    rclone_candidates = int(groups["rclone"])
    jellyfin_candidates = int(groups["jellyfin"])
    source_names = []
    if local_candidates:
        source_names.append("local")
    if rclone_candidates:
        source_names.append("rclone")
    if jellyfin_candidates:
        source_names.append("Jellyfin")
    source_label = " + ".join(source_names) if source_names else "No source candidates"
    player = bridge.get("player") or {"running": False, "process": None}
    valid = playlist_path.is_file() and expected_entries > 0 and actual_entries == expected_entries and bool(selected_entry)
    stale = age_seconds is not None and age_seconds > 86400
    if valid and not stale:
        state = "healthy"
        state_label = "Playing" if player.get("running") else "Ready"
        detail = f"{actual_entries} validated entries; episode {selected} selected"
    elif valid:
        state = "warning"
        state_label = "Needs refresh"
        detail = "The last validated playlist is more than a day old"
    elif not playlist_path.is_file():
        state = "warning"
        state_label = "Playlist missing"
        detail = "The last playlist file is no longer on disk"
    else:
        state = "warning"
        state_label = "Incomplete"
        detail = f"Expected {expected_entries} entries, found {actual_entries}"

    launched_file = latest_launch.group("file").strip() if latest_launch else ""
    detail = _playing_detail(detail, player)
    payload: dict[str, Any] = {
        "state": state,
        "state_label": state_label,
        "detail": detail,
        "show": show,
        "season": season,
        "entries": actual_entries,
        "expected_entries": expected_entries,
        "selected": selected if selected_entry else None,
        "local_candidates": local_candidates,
        "rclone_candidates": rclone_candidates,
        "jellyfin_candidates": jellyfin_candidates,
        "source_label": source_label,
        "playlist_name": playlist_path.name,
        "last_run": timestamp,
        "age_seconds": age_seconds,
        "launched": bool(launched_file and Path(launched_file).name == playlist_path.name),
        "player": player,
    }
    if include_last_play:
        payload["last_play"] = last_play
    return payload


def status_payload(light: bool = False) -> dict[str, Any]:
    processes = peek_processes() if light else query_processes()
    services = service_status(processes, light=light)
    # Surface live proxy uptime/active_streams on services.proxy (cached 30s TTL
    # via get_metrics(); falls back to logscan values when /metrics is down).
    # Light fast path skips the gdrive sync-log parse (uses cache or zeroed).
    try:
        metrics = get_metrics(include_gdrive=not light)
    except Exception:
        metrics = None
    except Exception:
        metrics = None
    if isinstance(metrics, dict):
        proxy_m = metrics.get("proxy")
        svc = services.get("proxy")
        if isinstance(proxy_m, dict) and isinstance(svc, dict):
            if proxy_m.get("active_streams") is not None:
                svc["active_streams"] = proxy_m.get("active_streams")
            if proxy_m.get("uptime_s") is not None:
                svc["uptime_s"] = proxy_m.get("uptime_s")
            if proxy_m.get("started_iso") is not None:
                svc["started_iso"] = proxy_m.get("started_iso")
            try:
                parts: list[str] = []
                if svc.get("uptime_s") is not None:
                    parts.append(f"up {svc['uptime_s']}s")
                if svc.get("active_streams") is not None:
                    parts.append(f"{svc['active_streams']} active")
                if parts:
                    svc["detail"] = f"{svc.get('detail', '')} ({', '.join(parts)})".strip()
            except Exception:
                pass
        # TorBox VFS disk-cache size on torboxmount detail (full polls only;
        # skipped entirely on ?light=1 to keep the fast path I/O-free).
        if not light:
            try:
                torbox_vfs_m = metrics.get("torbox_vfs")
                svc_t = services.get("torboxmount")
                if isinstance(torbox_vfs_m, dict) and isinstance(svc_t, dict):
                    size_str = _format_cache_bytes(torbox_vfs_m.get("bytes_used"))
                    if size_str is not None:
                        extra_parts: list[str] = [f"cache {size_str}"]
                        files_n = _safe_int_or_none(torbox_vfs_m.get("files"))
                        dirs_n = _safe_int_or_none(torbox_vfs_m.get("dirs"))
                        if files_n is not None:
                            extra_parts.append(f"{files_n} files")
                        if dirs_n is not None:
                            extra_parts.append(f"{dirs_n} dirs")
                        svc_t["detail"] = f"{svc_t.get('detail', '')} ({', '.join(extra_parts)})".strip()
            except Exception:
                pass
    return {
        "panel": {"state": "healthy", "port": PANEL_PORT, "time": now_text()},
        "services": services,
        "playback": read_playlist_status(services.get("bridge", {}), include_last_play=not light),
        "activity": read_activity(),
        "timeline": read_timeline(include_gdrive=not light),
    }


def wait_for_service(key: str, timeout: float = 25) -> bool:
    config = SERVICES[key]
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if config.get("kind") == "mount":
            if os.path.isdir(config["mount_path"]):
                return True
        elif http_probe(config["health"], timeout=1.5)["ok"]:
            return True
        time.sleep(0.5)
    return False


def stop_pids(rows: list[dict[str, Any]]) -> None:
    for row in rows:
        pid = int(row.get("pid") or 0)
        if pid > 0:
            run_hidden(["taskkill.exe", "/PID", str(pid), "/T", "/F"], timeout=8)


def dedupe_proxy() -> str | None:
    rows = query_processes()["proxy"]
    if len(rows) <= 1:
        return None
    ordered = sorted(rows, key=lambda row: (row.get("created") or "", row.get("pid") or 0))
    keep = ordered[0]
    extras = ordered[1:]
    stop_pids(extras)
    extra_ids = ", ".join(str(row["pid"]) for row in extras)
    append_log(f"Removed duplicate TorBox proxy process(es): {extra_ids}; kept PID {keep['pid']}")
    return f"Removed duplicate proxy process(es); kept PID {keep['pid']}"


def start_one(key: str) -> str:
    if key == "proxy":
        duplicate_message = dedupe_proxy()
    else:
        duplicate_message = None

    current = status_payload()["services"][key]
    if current["state"] == "healthy":
        message = f"{SERVICES[key]['name']} is already running"
        if duplicate_message:
            message += f". {duplicate_message}"
        append_log(message)
        return message

    if SERVICES[key].get("kind") == "mount":
        config = SERVICES[key]
        if key == "gdrive":
            nssm = SERVER_DIR / "nssm.exe"
            if not nssm.exists():
                raise RuntimeError("nssm.exe is missing")
            code, _, error = run_hidden([str(nssm), "start", config["nssm_service"]], timeout=30)
            if code != 0:
                raise RuntimeError(f"could not start {config['name']}: {error.strip()[:160]}")
        else:
            script = Path(config["start_script"])
            if not script.exists():
                raise RuntimeError("mount script is missing")
            if not spawn_hidden([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-WindowStyle", "Hidden", "-File", str(script),
            ]):
                raise RuntimeError(f"could not launch {config['name']} in background")
        requested = f"Started {SERVICES[key]['name']} in background"
        if wait_for_service(key, timeout=30):
            append_log(requested)
            return requested
        append_log(f"{requested}, but the mount path is still waiting")
        return requested + "; mount path is still waiting"

    if key == "jellyfin":
        for directory in (DATA_DIR, CONFIG_DIR, CACHE_DIR, LOG_DIR, TRANScode_DIR):
            directory.mkdir(parents=True, exist_ok=True)
        command = [
            str(JELLYFIN_EXE),
            "--datadir", str(DATA_DIR),
            "--configdir", str(CONFIG_DIR),
            "--cachedir", str(CACHE_DIR),
            "--logdir", str(LOG_DIR),
            "--webdir", str(WEB_DIR),
            "--ffmpeg", str(FFMPEG_EXE),
        ]
        if not JELLYFIN_EXE.exists():
            raise RuntimeError("jellyfin.exe is missing")
        if not spawn_hidden(command, cwd=SERVER_DIR):
            raise RuntimeError("could not launch Jellyfin in background")
        requested = "Started Jellyfin in background"
    else:
        task = SERVICES[key]["task"]
        command = ["schtasks.exe", "/Run", "/TN", str(task)]
        code, _, error = run_hidden(command)
        if code != 0:
            if key == "proxy" and TORBOX_PROXY_SCRIPT.exists():
                ok = spawn_hidden([str(Path(sys.executable).with_name("pythonw.exe")), str(TORBOX_PROXY_SCRIPT)], cwd=SERVER_DIR)
            elif key == "bridge" and BRIDGE_SCRIPT.exists():
                ok = spawn_hidden([str(Path(sys.executable).with_name("pythonw.exe")), str(BRIDGE_SCRIPT)])
            else:
                ok = False
            if not ok:
                raise RuntimeError(f"could not start {SERVICES[key]['name']}: {error.strip()[:160]}")
        requested = f"Started {SERVICES[key]['name']} in background"

    if wait_for_service(key, timeout=30 if key == "jellyfin" else 10):
        append_log(requested)
        return requested
    append_log(f"{requested}, but the health check is still waiting")
    return requested + "; health check is still waiting"


def stop_one(key: str) -> str:
    config = SERVICES[key]
    if config.get("kind") == "mount":
        if key == "gdrive":
            nssm = SERVER_DIR / "nssm.exe"
            run_hidden([str(nssm), "stop", config["nssm_service"]], timeout=30)
        else:
            stop_pids(query_processes()[key])
        message = f"Stopped {config['name']}"
        append_log(message)
        return message
    processes = query_processes()[key]
    if config.get("task"):
        run_hidden(["schtasks.exe", "/End", "/TN", str(config["task"])], timeout=8)
        time.sleep(0.5)
        processes = query_processes()[key]
    stop_pids(processes)
    message = f"Stopped {config['name']}"
    append_log(message)
    return message


def request_torbox_sync() -> str:
    """Ask the existing scheduled task to run the single Torbox sync pipeline."""
    code, _, error = run_hidden(
        ["schtasks.exe", "/Run", "/TN", TORBOX_SYNC_TASK],
        timeout=15,
    )
    if code != 0:
        detail = error.strip()[:160]
        raise RuntimeError(f"could not start TorBox sync: {detail or 'scheduled task request failed'}")
    message = "TorBox library sync requested"
    append_log(message)
    return message


def dispatch_action(service: str, action: str) -> str:
    acquired = _acquire_action_locks(service, action)
    try:
        if service == "torbox-sync":
            if action != "sync":
                raise ValueError("Unknown TorBox sync action")
            return request_torbox_sync()
        if service == "all":
            if action == "start":
                messages = [start_one(key) for key in ("gdrive", "torboxmount", "proxy", "bridge", "jellyfin")]
                return " | ".join(messages)
            if action == "stop":
                messages = [stop_one(key) for key in ("jellyfin", "bridge", "proxy", "torboxmount", "gdrive")]
                return " | ".join(messages)
            if action == "restart":
                for key in ("jellyfin", "bridge", "proxy", "torboxmount", "gdrive"):
                    stop_one(key)
                messages = [start_one(key) for key in ("gdrive", "torboxmount", "proxy", "bridge", "jellyfin")]
                return " | ".join(messages)
        if service not in SERVICES:
            raise ValueError("Unknown service")
        if action == "start":
            return start_one(service)
        if action == "stop":
            return stop_one(service)
        if action == "restart":
            stop_one(service)
            return start_one(service)
        raise ValueError("Unknown action")
    finally:
        _release_action_locks(acquired)


def _send_security_headers(handler: BaseHTTPRequestHandler) -> None:
    handler.send_header("Content-Security-Policy", "default-src 'self'")
    handler.send_header("X-Content-Type-Options", "nosniff")
    handler.send_header("Referrer-Policy", "no-referrer")


def _is_origin_allowed(handler: BaseHTTPRequestHandler) -> bool:
    origin = handler.headers.get("Origin")
    if not origin:
        return True  # Non-browser client (curl/python); no Origin to check.
    try:
        parsed = urlsplit(origin.strip())
    except ValueError:
        return False
    hostname = (parsed.hostname or "").lower()
    if hostname in ("127.0.0.1", "localhost", "::1"):
        return True
    host = (handler.headers.get("Host") or "").strip().lower()
    if parsed.netloc.lower() and parsed.netloc.lower() == host:
        return True
    return False


def _is_light_request(path: str) -> bool:
    if "?" not in path:
        return False
    query = path.split("?", 1)[1]
    for part in query.split("&"):
        key, _, value = part.partition("=")
        if unquote(key).strip().lower() == "light" and unquote(value).strip() == "1":
            return True
    return False


def _new_request_id() -> str:
    """Feature (6): unique id for every request (header + log line)."""
    return uuid.uuid4().hex


def _client_ip(handler: BaseHTTPRequestHandler) -> str:
    try:
        return str(handler.client_address[0]) if handler.client_address else "unknown"
    except Exception:
        return "unknown"


def _log_request(request_id: str, method: str, path: str, status: int) -> None:
    """Feature (6): one log line per request carrying the request id."""
    try:
        append_log(f"[{request_id}] {method} {path} -> {status}")
    except Exception:
        pass


def _client_accepts_gzip(handler: BaseHTTPRequestHandler) -> bool:
    """Feature (8): honour Accept-Encoding: gzip when the client offers it."""
    try:
        encoding = handler.headers.get("Accept-Encoding") or ""
        return "gzip" in encoding.lower()
    except Exception:
        return False


def _maybe_gzip(handler: BaseHTTPRequestHandler, raw: bytes) -> tuple[bytes, bool]:
    """Compress payload when the client accepts gzip; never fail the request."""
    if not raw or len(raw) < 256:
        return raw, False
    if not _client_accepts_gzip(handler):
        return raw, False
    try:
        return gzip.compress(raw), True
    except Exception:
        return raw, False


def _parse_query(raw_path: str) -> dict[str, list[str]]:
    """Parse query string into {key: [values]} with lower-cased keys."""
    try:
        query = raw_path.split("?", 1)[1] if "?" in raw_path else ""
        parsed = parse_qs(query, keep_blank_values=True)
        return {str(k).lower(): [str(v) for v in vals] for k, vals in parsed.items()}
    except Exception:
        return {}


def _parse_pagination(query: dict[str, list[str]]) -> tuple[int, int]:
    """Feature (3): ?page=&per_page= with sane clamping."""
    try:
        page_raw = (query.get("page") or [""])[0]
        per_page_raw = (query.get("per_page") or [""])[0]
        page = int(str(page_raw).strip()) if str(page_raw).strip() else _TIMELINE_PAGE_DEFAULT
    except (TypeError, ValueError):
        page = _TIMELINE_PAGE_DEFAULT
    try:
        per_page = int(str(per_page_raw).strip()) if str(per_page_raw).strip() else _TIMELINE_PER_PAGE_DEFAULT
    except (TypeError, ValueError):
        per_page = _TIMELINE_PER_PAGE_DEFAULT
    if page < 1:
        page = 1
    if per_page < 1:
        per_page = _TIMELINE_PER_PAGE_DEFAULT
    if per_page > _TIMELINE_PER_PAGE_MAX:
        per_page = _TIMELINE_PER_PAGE_MAX
    return page, per_page


def _parse_level_filter(query: dict[str, list[str]]) -> str | None:
    """Feature (4): ?level=error returns errors only (case-insensitive)."""
    try:
        vals = query.get("level")
        if not vals:
            return None
        level = str(vals[0] or "").strip().lower()
        return level or None
    except Exception:
        return None


def _check_admin_rate_limit(handler: BaseHTTPRequestHandler) -> tuple[bool, int]:
    """Feature (9): sliding-window rate limit for admin/restart endpoints.

    Returns (allowed, retry_after_seconds). Per client IP, max
    _ADMIN_RATE_LIMIT_MAX requests per _ADMIN_RATE_LIMIT_WINDOW_SECONDS.
    """
    ip = _client_ip(handler)
    now = time.monotonic()
    window = _ADMIN_RATE_LIMIT_WINDOW_SECONDS
    with _ADMIN_RATE_LOCK:
        hits = _ADMIN_RATE_BUCKETS.get(ip, [])
        hits = [t for t in hits if (now - t) < window]
        if len(hits) >= _ADMIN_RATE_LIMIT_MAX:
            oldest = min(hits) if hits else now
            retry_after = max(1, int(window - (now - oldest)) + 1)
            _ADMIN_RATE_BUCKETS[ip] = hits
            return False, retry_after
        hits.append(now)
        _ADMIN_RATE_BUCKETS[ip] = hits
        return True, 0


def health_payload() -> dict[str, Any]:
    """Feature (1): GET /api/health aggregating proxy/bridge/Jellyfin/mount T:.

    Lightweight: one short HTTP probe per TCP service + os.path.isdir for
    the T:\\ mount. Never raises; degrades to stopped/unknown on failure.
    """
    services: dict[str, dict[str, Any]] = {}
    try:
        proxy_probe = http_probe("http://127.0.0.1:8888/health", timeout=2.0)
    except Exception:
        proxy_probe = {"ok": False, "code": 0, "body": ""}
    services["proxy"] = {
        "id": "proxy",
        "name": "TorBox Proxy",
        "port": 8888,
        "ok": bool(proxy_probe.get("ok")),
        "code": int(proxy_probe.get("code") or 0),
        "state": "healthy" if proxy_probe.get("ok") else "stopped",
    }
    try:
        bridge_probe = http_probe("http://127.0.0.1:18099/health", timeout=2.0)
    except Exception:
        bridge_probe = {"ok": False, "code": 0, "body": ""}
    services["bridge"] = {
        "id": "bridge",
        "name": "PotPlayer Bridge",
        "port": 18099,
        "ok": bool(bridge_probe.get("ok")),
        "code": int(bridge_probe.get("code") or 0),
        "state": "healthy" if bridge_probe.get("ok") else "stopped",
    }
    try:
        jelly_probe = http_probe("http://127.0.0.1:8096/System/Info/Public", timeout=2.0)
    except Exception:
        jelly_probe = {"ok": False, "code": 0, "body": ""}
    jelly_entry: dict[str, Any] = {
        "id": "jellyfin",
        "name": "Jellyfin",
        "port": 8096,
        "ok": bool(jelly_probe.get("ok")),
        "code": int(jelly_probe.get("code") or 0),
        "state": "healthy" if jelly_probe.get("ok") else "stopped",
    }
    if jelly_probe.get("ok"):
        try:
            info = json.loads(str(jelly_probe.get("body") or ""))
            if isinstance(info, dict):
                if info.get("Version"):
                    jelly_entry["version"] = info.get("Version")
                if info.get("ServerName"):
                    jelly_entry["server_name"] = info.get("ServerName")
        except Exception:
            pass
    services["jellyfin"] = jelly_entry
    try:
        mount_ok = os.path.isdir("T:\\")
    except Exception:
        mount_ok = False
    services["torboxmount"] = {
        "id": "torboxmount",
        "name": "TorBox Mount",
        "port": None,
        "mount_path": "T:\\",
        "ok": bool(mount_ok),
        "state": "healthy" if mount_ok else "stopped",
        "detail": "T:\\ is mounted" if mount_ok else "T:\\ is not mounted",
    }
    overall = "healthy" if all(str(v.get("state")) == "healthy" for v in services.values()) else "degraded"
    return {
        "status": "ok" if overall == "healthy" else "degraded",
        "overall": overall,
        "services": services,
        "time": datetime.now().isoformat(timespec="seconds"),
    }


def config_payload() -> dict[str, Any]:
    """Feature (7): read-only GET /api/config (ports, paths, versions).

    Never includes secrets: no tokens, API keys, passwords, or command lines.
    Only static ports, safe mount paths, and version strings.
    """
    try:
        python_version = sys.version.split()[0]
    except Exception:
        python_version = "unknown"
    return {
        "ports": {
            "panel": PANEL_PORT,
            "jellyfin": 8096,
            "proxy": 8888,
            "bridge": 18099,
        },
        "paths": {
            "mount_t": "T:\\",
            "mount_gdrive": r"F:\Media",
            "mount_gdrive_alias": "R:\\",
        },
        "versions": {
            "panel": PANEL_VERSION,
            "python": python_version,
        },
    }


def preflight_check(port: int = PANEL_PORT) -> None:
    """Feature (10): startup preflight with a clear error on port conflict.

    Tries to bind 127.0.0.1:port briefly. On EADDRINUSE raises SystemExit(1)
    with a human-readable message (also appended to the panel log).
    """
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
        probe.bind(("127.0.0.1", port))
    except OSError as exc:
        message = (
            f"Control panel preflight failed: port {port} is already in use "
            f"({exc.strerror or exc}); is another control-panel instance running? "
            f"Stop the existing process on 127.0.0.1:{port} and retry."
        )
        try:
            append_log(message)
        except Exception:
            pass
        print(message, file=sys.stderr)
        raise SystemExit(1) from exc
    finally:
        try:
            probe.close()
        except Exception:
            pass


def json_response(
    handler: BaseHTTPRequestHandler,
    data: dict[str, Any],
    status: int = 200,
    request_id: str | None = None,
) -> None:
    raw = json.dumps(data, ensure_ascii=False).encode("utf-8")
    body, did_gzip = _maybe_gzip(handler, raw)
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(body)))
    if did_gzip:
        handler.send_header("Content-Encoding", "gzip")
        handler.send_header("Vary", "Accept-Encoding")
    if request_id:
        handler.send_header("X-Request-ID", request_id)
    _send_security_headers(handler)
    handler.end_headers()
    handler.wfile.write(body)


def _serve_static(
    handler: BaseHTTPRequestHandler,
    raw: bytes,
    content_type: str,
    request_id: str | None = None,
    status: int = 200,
) -> None:
    body, did_gzip = _maybe_gzip(handler, raw)
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(body)))
    if did_gzip:
        handler.send_header("Content-Encoding", "gzip")
        handler.send_header("Vary", "Accept-Encoding")
    if request_id:
        handler.send_header("X-Request-ID", request_id)
    _send_security_headers(handler)
    handler.end_headers()
    handler.wfile.write(body)


class ControlPanelHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:
        pass

    def do_GET(self) -> None:
        request_id = _new_request_id()
        raw_path = self.path
        path = raw_path.split("?", 1)[0]
        query = _parse_query(raw_path)
        try:
            if path == "/health":
                json_response(self, {"status": "ok", "service": "jellyfin-control-panel"}, 200, request_id)
                _log_request(request_id, "GET", raw_path, 200)
                return
            if path == "/api/health":
                # Feature (1): aggregated health for proxy/bridge/Jellyfin/mount T:.
                payload = health_payload()
                json_response(self, payload, 200, request_id)
                _log_request(request_id, "GET", raw_path, 200)
                return
            if path == "/api/status":
                light = _is_light_request(raw_path)
                json_response(self, status_payload(light=light), 200, request_id)
                _log_request(request_id, "GET", raw_path, 200)
                return
            if path == "/api/activity":
                json_response(self, {"activity": read_activity(), "timeline": read_timeline()}, 200, request_id)
                _log_request(request_id, "GET", raw_path, 200)
                return
            if path == "/api/metrics":
                # Feature (2): proxies torbox-proxy /metrics via get_metrics() (5s cache).
                light = _is_light_request(raw_path)
                json_response(self, get_metrics(include_gdrive=not light), 200, request_id)
                _log_request(request_id, "GET", raw_path, 200)
                return
            if path == "/api/timeline":
                # Features (3/4): pagination (?page=&per_page=) + errors-only (?level=error).
                light = _is_light_request(raw_path)
                full = read_timeline(include_gdrive=not light)
                level = _parse_level_filter(query)
                if level == "error":
                    full = [e for e in full if str(e.get("level") or "").lower() == "error"]
                page, per_page = _parse_pagination(query)
                total = len(full)
                total_pages = max(1, (total + per_page - 1) // per_page) if total else 1
                if page > total_pages:
                    page = total_pages
                start = (page - 1) * per_page
                sliced = full[start:start + per_page]
                json_response(
                    self,
                    {
                        "timeline": sliced,
                        "page": page,
                        "per_page": per_page,
                        "total": total,
                        "total_pages": total_pages,
                        "level": level,
                    },
                    200,
                    request_id,
                )
                _log_request(request_id, "GET", raw_path, 200)
                return
            if path == "/api/config":
                # Feature (7): read-only config (ports, paths, versions; no secrets).
                json_response(self, config_payload(), 200, request_id)
                _log_request(request_id, "GET", raw_path, 200)
                return

            files = {
                "/": ("index.html", "text/html; charset=utf-8"),
                "/index.html": ("index.html", "text/html; charset=utf-8"),
                "/app.css": ("app.css", "text/css; charset=utf-8"),
                "/app.js": ("app.js", "text/javascript; charset=utf-8"),
            }
            entry = files.get(path)
            if not entry:
                json_response(self, {"error": "Not found"}, 404, request_id)
                _log_request(request_id, "GET", raw_path, 404)
                return
            file_path = CONTROL_DIR / entry[0]
            try:
                raw = file_path.read_bytes()
            except OSError:
                json_response(self, {"error": "Panel asset missing"}, 500, request_id)
                _log_request(request_id, "GET", raw_path, 500)
                return
            _serve_static(self, raw, entry[1], request_id, 200)
            _log_request(request_id, "GET", raw_path, 200)
        except Exception as exc:
            try:
                json_response(self, {"error": str(exc) or "Internal error"}, 500, request_id)
            except Exception:
                pass
            _log_request(request_id, "GET", raw_path, 500)

    def do_POST(self) -> None:
        request_id = _new_request_id()
        raw_path = self.path
        path = raw_path.split("?", 1)[0]
        if path == "/api/config":
            # Feature (7): config is read-only.
            json_response(self, {"ok": False, "error": "Read-only: use GET /api/config"}, 405, request_id)
            _log_request(request_id, "POST", raw_path, 405)
            return
        if path not in ("/api/action", "/api/restart"):
            json_response(self, {"ok": False, "error": "Not found"}, 404, request_id)
            _log_request(request_id, "POST", raw_path, 404)
            return
        # Feature (9): rate limit admin/restart endpoints.
        allowed, retry_after = _check_admin_rate_limit(self)
        if not allowed:
            try:
                raw = json.dumps({"ok": False, "error": "Rate limit exceeded; retry later"}).encode("utf-8")
                body, did_gzip = _maybe_gzip(self, raw)
                self.send_response(429)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Retry-After", str(retry_after))
                if did_gzip:
                    self.send_header("Content-Encoding", "gzip")
                    self.send_header("Vary", "Accept-Encoding")
                if request_id:
                    self.send_header("X-Request-ID", request_id)
                _send_security_headers(self)
                self.end_headers()
                self.wfile.write(body)
            except Exception:
                pass
            _log_request(request_id, "POST", raw_path, 429)
            try:
                append_log(f"[{request_id}] rate-limited POST {raw_path} from {_client_ip(self)}")
            except Exception:
                pass
            return
        if not _is_origin_allowed(self):
            json_response(self, {"ok": False, "error": "Cross-origin request rejected"}, 403, request_id)
            _log_request(request_id, "POST", raw_path, 403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
            raw_body = self.rfile.read(max(0, length)).decode("utf-8") if length > 0 else "{}"
            try:
                payload = json.loads(raw_body) if raw_body.strip() else {}
            except json.JSONDecodeError:
                payload = {}
            if path == "/api/restart":
                # Feature (5): per-service restart with hardcoded allowlist.
                service = str(payload.get("service", "") or "").strip()
                if not service:
                    json_response(self, {"ok": False, "error": "Missing 'service'"}, 400, request_id)
                    _log_request(request_id, "POST", raw_path, 400)
                    return
                if service not in RESTART_ALLOWLIST:
                    json_response(
                        self,
                        {
                            "ok": False,
                            "error": f"Unknown or not restartable service: {service}",
                            "allowed": sorted(RESTART_ALLOWLIST),
                        },
                        400,
                        request_id,
                    )
                    _log_request(request_id, "POST", raw_path, 400)
                    return
                message = dispatch_action(service, "restart")
                json_response(self, {"ok": True, "message": message, "status": status_payload()}, 200, request_id)
                _log_request(request_id, "POST", raw_path, 200)
                return
            # Legacy /api/action path (start/stop/restart/sync).
            action = str(payload.get("action", ""))
            service = str(payload.get("service", ""))
            # Enforce the same hardcoded allowlist for restart via /api/action.
            if action == "restart" and service not in RESTART_ALLOWLIST and service != "all":
                json_response(
                    self,
                    {
                        "ok": False,
                        "error": f"Unknown or not restartable service: {service}",
                        "allowed": sorted(RESTART_ALLOWLIST),
                        "status": status_payload(),
                    },
                    400,
                    request_id,
                )
                _log_request(request_id, "POST", raw_path, 400)
                return
            message = dispatch_action(service, action)
            json_response(self, {"ok": True, "message": message, "status": status_payload()}, 200, request_id)
            _log_request(request_id, "POST", raw_path, 200)
        except ActionBusyError as exc:
            append_log(f"[{request_id}] Action conflict: {exc.service}/{exc.action} busy")
            json_response(
                self,
                {"ok": False, "error": str(exc), "service": exc.service, "action": exc.action, "status": status_payload()},
                409,
                request_id,
            )
            _log_request(request_id, "POST", raw_path, 409)
        except Exception as exc:
            append_log(f"[{request_id}] Action failed: {type(exc).__name__}")
            json_response(self, {"ok": False, "error": str(exc), "status": status_payload()}, 500, request_id)
            _log_request(request_id, "POST", raw_path, 500)


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    # Do not allow two hidden logon/manual launches to share the panel port.
    # A second instance should fail quietly instead of creating split state.
    allow_reuse_address = False
    daemon_threads = True


def main() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    # Feature (10): startup preflight — clear error on port conflict.
    preflight_check(PANEL_PORT)
    append_log("Control panel process started in background")
    try:
        server = ReusableThreadingHTTPServer(("127.0.0.1", PANEL_PORT), ControlPanelHandler)
    except OSError as exc:
        message = (
            f"Control panel failed to bind 127.0.0.1:{PANEL_PORT}: "
            f"{exc.strerror or exc}. Another instance is likely running; "
            f"stop it before starting a new one."
        )
        try:
            append_log(message)
        except Exception:
            pass
        print(message, file=sys.stderr)
        raise SystemExit(1) from exc
    server.serve_forever()


if __name__ == "__main__":
    main()
