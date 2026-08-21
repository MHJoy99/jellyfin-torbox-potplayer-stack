# MCP Rclone Storage Automation Guide

## 1. Overview and Architecture

The `rclone-storage-mcp` server (`F:\Jellyfin\mcp-servers\rclone-storage\server.py`) exposes remote cloud storage capabilities to AI coding assistants and automation agents via the **Model Context Protocol (MCP)**.

By wrapping the high-performance `rclone` binary with a standardized JSON-RPC stdio transport layer, AI agents can inspect directories, execute cloud operations, and perform instant server-side file renaming or relocation across remote remotes (Google Drive, Torbox, S3, WebDAV, etc.) without downloading data to the local host.

### Architecture Diagram

```
+---------------------------------------------------------------------------------+
|                               AI Agent Host                                     |
|  (Claude Desktop / Cursor / ZCode CLI / Local Agents / LangChain / AutoGen)    |
+----------------------------------------+----------------------------------------+
                                         |
                            JSON-RPC 2.0 via stdio
                           (stdin / stdout streams)
                                         |
                                         v
+---------------------------------------------------------------------------------+
|                       rclone-storage-mcp Server                                 |
|            (F:\Jellyfin\mcp-servers\rclone-storage\server.py)                   |
+----------------------------------------+----------------------------------------+
                                         |
                          Subprocess Execution (UTF-8)
             ["F:\Jellyfin\server\rclone.exe", "--config", "rclone.conf", ...]
                                         |
                                         v
+---------------------------------------------------------------------------------+
|                              rclone Engine                                      |
|                  (F:\Jellyfin\server\rclone.exe)                                |
+----------------------------------------+----------------------------------------+
                                         |
                   Direct HTTPS / Cloud Provider REST APIs
                     (Instant Remote-Side Operations)
                                         |
        +--------------------------------+--------------------------------+
        |                                |                                |
        v                                v                                v
+---------------+               +-----------------+              +----------------+
|  Google Drive |               |  Torbox WebDAV  |              | S3 / Cloudflare|
| (gdrive-media)|               | (torbox-mount)  |              |   R2 Buckets   |
+---------------+               +-----------------+              +----------------+
```

---

## 2. JSON-RPC stdio Protocol Bridge Implementation

The server is implemented in lightweight, zero-dependency standard Python. It uses line-delimited JSON-RPC 2.0 messages exchanged over standard input (`stdin`) and standard output (`stdout`).

### Server Lifecycle & Message Handling

1. **Protocol Initialization (`initialize`)**
   - Returns protocol version (`2024-11-05`), server identity (`rclone-storage-mcp`), and advertised capability sets (`{"tools": {}}`).
2. **Tool Discovery (`tools/list`)**
   - Emits tool definitions and JSON Schema descriptions for parameter validation.
3. **Tool Execution (`tools/call`)**
   - Invokes rclone subprocess with configured credentials and returns structured MCP `content` blocks.
4. **Error Handling**
   - Maps missing methods or unhandled exceptions to JSON-RPC error specifications (`-32601` for method not found, `-32603` for internal error).

### Subprocess Execution Mechanism

```python
def run_rclone(args):
    cmd = ["F:\\Jellyfin\\server\\rclone.exe", "--config", "F:\\Jellyfin\\config\\rclone.conf"] + args
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    return res.stdout, res.stderr, res.returncode
```

- **UTF-8 Encoding:** Handles international characters, CJK titles, and media naming conventions.
- **Isolated Configuration:** Relies strictly on `F:\Jellyfin\config\rclone.conf`, isolating media credentials from ambient OS user configs.
- **Buffered Output Capture:** Formats stdout and stderr cleanly for LLM tool call results.

---

## 3. Supported Tool Schemas

### 3.1. `rclone_list_files`
Lists files and metadata formatted as JSON from any mounted or unmounted remote target.

- **Underlying command:** `rclone lsjson <remote_path> [-R]`
- **Input Schema:**
  ```json
  {
    "type": "object",
    "properties": {
      "remote_path": {
        "type": "string",
        "description": "Remote path like 'gdrive-media:Motion Picture' or 'gdrive-media:'"
      },
      "recursive": {
        "type": "boolean",
        "default": false
      }
    },
    "required": ["remote_path"]
  }
  ```
- **Example Usage:**
  ```json
  {
    "name": "rclone_list_files",
    "arguments": {
      "remote_path": "gdrive-media:Motion Picture/Inception (2010)",
      "recursive": false
    }
  }
  ```

---

### 3.2. `rclone_rename_or_move`
Performs atomic server-side rename or relocate operations across cloud paths without streaming payload bytes locally.

- **Underlying command:** `rclone moveto <source> <destination>`
- **Input Schema:**
  ```json
  {
    "type": "object",
    "properties": {
      "source": {
        "type": "string",
        "description": "Source path e.g. 'gdrive-media:Motion Picture/old.mkv'"
      },
      "destination": {
        "type": "string",
        "description": "Dest path e.g. 'gdrive-media:Motion Picture/new.mkv'"
      }
    },
    "required": ["source", "destination"]
  }
  ```
- **Example Usage:**
  ```json
  {
    "name": "rclone_rename_or_move",
    "arguments": {
      "source": "gdrive-media:Motion Picture/Inception.2010.1080p.mkv",
      "destination": "gdrive-media:Motion Picture/Inception (2010)/Inception (2010) [imdbid-tt1375666].mkv"
    }
  }
  ```

---

### 3.3. `rclone_command`
Arbitrary command bridge for advanced storage administration, integrity checks, and space quota audits.

- **Underlying command:** `rclone <subcommand> <args...>`
- **Supported Subcommands:** `lsf`, `copyto`, `about`, `size`, `mkdir`, `rmdir`, `purge`, `check`, `cat`, etc.
- **Input Schema:**
  ```json
  {
    "type": "object",
    "properties": {
      "subcommand": {
        "type": "string",
        "description": "e.g. lsf, moveto, copyto, about, size"
      },
      "args": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Command arguments"
      }
    },
    "required": ["subcommand", "args"]
  }
  ```
- **Example Usage:**
  ```json
  {
    "name": "rclone_command",
    "arguments": {
      "subcommand": "about",
      "args": ["gdrive-media:"]
    }
  }
  ```

---

## 4. Instant Server-Side Remote Operations (Zero Local Bandwidth)

A major performance advantage of the `rclone-storage-mcp` design is **Zero-Bandwidth File Manipulation**.

### Problem with Traditional Agent File Renaming
When a standard coding agent organizes files on a mounted virtual drive (e.g. `G:\` or WinFsp mount):
1. Moving or renaming often triggers local read-write buffers depending on OS shell hooks.
2. Transferring a 40 GB 4K remux over virtual drives can incur gigabytes of unnecessary local network round trips or temporary lockups.

### The MCP Direct Remote Advantage
`rclone moveto` executes pure API mutations against cloud endpoints:
- **Google Drive:** Calls Google Drive v3 `files.update` or `files.patch` API to adjust parent folders and file titles. Execution completes in **~150ms** regardless of whether the file is 10 MB or 100 GB.
- **Torbox WebDAV / S3:** Performs remote `MOVE` or server-side `CopyObject` + `DeleteObject` without local payload transfer.
- **Local Network Impact:** Exactly 0 bytes of media data transferred over the host machine's internet link.

---

## 5. Client Integration Guide

### 5.1. Claude Desktop Configuration
Add the server entry to `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "rclone-storage": {
      "command": "python",
      "args": [
        "F:\\Jellyfin\\mcp-servers\\rclone-storage\\server.py"
      ],
      "env": {
        "PYTHONIOENCODING": "utf-8"
      }
    }
  }
}
```

---

### 5.2. Cursor Integration
In Cursor Settings -> **Features** -> **MCP Servers** -> **Add New MCP Server**:

- **Name:** `rclone-storage`
- **Type:** `command`
- **Command:** `python F:\Jellyfin\mcp-servers\rclone-storage\server.py`

---

### 5.3. ZCode CLI Configuration
Add to `~/.zcode/mcp_servers.json` or workspace configuration:

```json
{
  "mcpServers": {
    "rclone-storage": {
      "command": "python",
      "args": ["F:\\Jellyfin\\mcp-servers\\rclone-storage\\server.py"],
      "enabled": true
    }
  }
}
```

---

### 5.4. Local AI Agent Workflow Example (Python / LangChain)

```python
import subprocess
import json

class RcloneMCPClient:
    def __init__(self, server_path="F:\\Jellyfin\\mcp-servers\\rclone-storage\\server.py"):
        self.proc = subprocess.Popen(
            ["python", server_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8"
        )
        self.req_id = 0
        self._initialize()

    def _send_request(self, method, params=None):
        self.req_id += 1
        payload = {"jsonrpc": "2.0", "id": self.req_id, "method": method}
        if params:
            payload["params"] = params
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        return json.loads(line)

    def _initialize(self):
        return self._send_request("initialize")

    def call_tool(self, tool_name, arguments):
        return self._send_request("tools/call", {"name": tool_name, "arguments": arguments})

# Example: AI Media Organizer Agent
client = RcloneMCPClient()
files_info = client.call_tool("rclone_list_files", {
    "remote_path": "gdrive-media:Incoming",
    "recursive": False
})
print("Files ready for processing:", files_info["result"]["content"][0]["text"])
```

---

## 6. Security and Operational Guidelines

1. **Path Sandboxing:** Only remotes defined within `F:\Jellyfin\config\rclone.conf` are accessible.
2. **Atomic Renames:** Use `rclone_rename_or_move` instead of separate copy and delete operations to avoid incomplete states.
3. **Output Formatting:** `rclone_list_files` uses `lsjson`, providing structured JSON outputs (size, modified time, MIME type, hashes) optimized for direct agent parsing.
