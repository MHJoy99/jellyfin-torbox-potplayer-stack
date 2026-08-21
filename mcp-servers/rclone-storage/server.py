import sys
import json
import subprocess
import os

def run_rclone(args):
    cmd = ["F:\\Jellyfin\\server\\rclone.exe", "--config", "F:\\Jellyfin\\config\\rclone.conf"] + args
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    return res.stdout, res.stderr, res.returncode

def main():
    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                break
            req = json.loads(line)
            req_id = req.get("id")
            method = req.get("method")

            if method == "initialize":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "rclone-storage-mcp", "version": "1.0.0"}
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()

            elif method == "tools/list":
                tools = [
                    {
                        "name": "rclone_list_files",
                        "description": "List files in any mounted or remote cloud directory (e.g. gdrive-media:Motion Picture)",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "remote_path": {"type": "string", "description": "Remote path like 'gdrive-media:Motion Picture' or 'gdrive-media:'"},
                                "recursive": {"type": "boolean", "default": False}
                            },
                            "required": ["remote_path"]
                        }
                    },
                    {
                        "name": "rclone_rename_or_move",
                        "description": "Fast server-side rename or move file in cloud without re-uploading",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "source": {"type": "string", "description": "Source path e.g. 'gdrive-media:Motion Picture/old.mkv'"},
                                "destination": {"type": "string", "description": "Dest path e.g. 'gdrive-media:Motion Picture/new.mkv'"}
                            },
                            "required": ["source", "destination"]
                        }
                    },
                    {
                        "name": "rclone_command",
                        "description": "Execute any direct rclone command (lsf, moveto, copyto, mkdir, purge, rmdir, check)",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "subcommand": {"type": "string", "description": "e.g. lsf, moveto, copyto, about, size"},
                                "args": {"type": "array", "items": {"type": "string"}, "description": "Command arguments"}
                            },
                            "required": ["subcommand", "args"]
                        }
                    }
                ]
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"tools": tools}
                }
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()

            elif method == "tools/call":
                params = req.get("params", {})
                name = params.get("name")
                args = params.get("arguments", {})

                if name == "rclone_list_files":
                    rpath = args.get("remote_path", "")
                    rec = args.get("recursive", False)
                    rargs = ["lsjson", rpath]
                    if rec:
                        rargs.append("-R")
                    out, err, code = run_rclone(rargs)
                    content = out if code == 0 else f"Error ({code}): {err}"
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": content}]}
                    }
                    sys.stdout.write(json.dumps(resp) + "\n")
                    sys.stdout.flush()

                elif name == "rclone_rename_or_move":
                    src = args.get("source")
                    dst = args.get("destination")
                    out, err, code = run_rclone(["moveto", src, dst])
                    msg = f"Successfully moved/renamed '{src}' -> '{dst}'" if code == 0 else f"Error ({code}): {err}"
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": msg}]}
                    }
                    sys.stdout.write(json.dumps(resp) + "\n")
                    sys.stdout.flush()

                elif name == "rclone_command":
                    subcmd = args.get("subcommand")
                    cargs = args.get("args", [])
                    out, err, code = run_rclone([subcmd] + cargs)
                    result_text = out if out else (f"Success (Code {code})" if code == 0 else f"Error ({code}): {err}")
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"content": [{"type": "text", "text": result_text}]}
                    }
                    sys.stdout.write(json.dumps(resp) + "\n")
                    sys.stdout.flush()
                else:
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "error": {"code": -32601, "message": f"Tool not found: {name}"}
                    }
                    sys.stdout.write(json.dumps(resp) + "\n")
                    sys.stdout.flush()

        except Exception as e:
            err_resp = {
                "jsonrpc": "2.0",
                "id": req.get("id") if "req" in locals() else None,
                "error": {"code": -32603, "message": str(e)}
            }
            sys.stdout.write(json.dumps(err_resp) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
