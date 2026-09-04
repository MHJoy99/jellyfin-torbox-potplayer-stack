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
    cand = os.environ.get("RCLONE_EXE", DEFAULT_EXE)
    if cand and os.path.exists(cand):
        return cand
    found = shutil.which("rclone")
    if found:
        return found
    return cand or "rclone"


def _rclone_config():
    return os.environ.get("RCLONE_CONFIG", DEFAULT_CONFIG)


def run_rclone(args):
    cmd = [_rclone_exe(), "--config", _rclone_config()] + args
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", timeout=60)
    return res.stdout, res.stderr, res.returncode


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
