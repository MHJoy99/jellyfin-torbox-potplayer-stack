# Install, Update, and Uninstall

This guide covers every install path plus updating and clean removal, so one file owns the full lifecycle from first setup to final teardown. The supported one-click installer is `install.ps1`; the interactive first-run alternative is `setup-wizard.ps1`.

## Contents

- [Which path to pick](#which-path-to-pick)
- [Prerequisites](#prerequisites)
- [One-click install with install.ps1](#one-click-install-with-installps1)
- [Interactive setup with setup-wizard.ps1](#interactive-setup-with-setup-wizardps1)
- [Step-by-step verification matrix](#step-by-step-verification-matrix)
- [Manual install in order](#manual-install-in-order)
- [Portable run without tasks](#portable-run-without-tasks)
- [Verify the install](#verify-the-install)
- [Updating](#updating)
- [Uninstall and clean removal](#uninstall-and-clean-removal)
- [Version stamps and receipts](#version-stamps-and-receipts)

## Which path to pick

Use `install.ps1` when you want the supported one-click order with automatic verification. Use `setup-wizard.ps1` when you want an interactive first-run menu for TorBox key, library roots, Jellyfin connection, PotPlayer path, rclone config, ports, and playback mode, with a dry-run review before anything is applied. Use manual steps when you need to debug one piece of the `install.ps1` order or reinstall a single artifact. Use the portable run when you cannot create scheduled tasks or registry keys and only want processes under your current session. The advanced per-service orchestrator `install-all.ps1` (six service installers in dependency order) is only for service-by-service reinstalls; it is not the primary path. All paths share the same health endpoints and the same env-only secrets rule described in [TorBox](torbox.md) and [Reference](reference.md).

## Prerequisites

Install these before running anything, from the repo root:

- Windows 10/11 x64. PowerShell 5.1 or newer is supported; PowerShell 7 or newer is recommended (`https://aka.ms/pwsh`). `install.ps1` and `setup-wizard.ps1` use only built-in cmdlets plus `reg.exe` and `schtasks.exe`; no extra modules are imported.
- Administrator rights for the default install (registry `HKCR\potplayer` plus `HKCR\potplayer64`, Machine/User environment persist, and the `MediaStackSupervisor` logon task). No admin is needed for `install.ps1 -Portable`, which writes no registry keys and creates no task.
- Tools auto-detected by `install.ps1` with a versions table and download links for anything missing: `pwsh`, `python` (`https://www.python.org/downloads/windows/`, required by proxy, bridge, and panel), `node` (`https://nodejs.org/en/download`), `rclone` (`https://rclone.org/downloads/`, required for mounts). Missing tools print a warning with the link; install continues so you can install the tool and re-run.
- PotPlayer 64-bit installed before protocol registration. `install.ps1` searches well-known paths, `App Paths`, and an optional `-PotPlayerExe` override; `setup-wizard.ps1` scans registry DAUM keys, `App Paths`, Program Files, `PATH`, and accepts a manual `.exe` override.
- Jellyfin server files or an existing Jellyfin on `:8096`, rclone with WinFsp, and NSSM when mounts run as services. Keep the repo folder path short and without special characters.
- A TorBox API key from the TorBox dashboard under Settings and API access (Machine or User scope). TorBox requires the key as a `?token=` query parameter; header-only auth returns HTTP 422. You can pre-set `$env:TORBOX_API_KEY` or let `install.ps1` / the wizard prompt for it with masked input. The key is validated with exactly one `GET /v1/api/user/me?token=<key>` call before any mutation, and it is persisted to Machine scope by default (User scope with `-KeyScope User`) plus the current session. It is never written to the receipt, the log, or the repo; logs record only length, validation result, and scope.
- Default target `F:\Jellyfin` (override with `-BaseDir`). The installer creates `logs`, `cache`, `run`, `backups`, plus `.install-versions` for receipts and stamps. Existing directories, receipts, tasks, and protocol keys are detected and upgraded in place on re-run.

## One-click install with install.ps1

Run from the repo root:

```powershell
pwsh -File install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1
pwsh -File install.ps1 -WhatIf
pwsh -File install.ps1 -TorboxApiKey $env:TORBOX_API_KEY -KeyScope User -NonInteractive
pwsh -File install.ps1 -SkipTasks
pwsh -File install.ps1 -Portable
pwsh -File install.ps1 -Uninstall
```

`-WhatIf` prints every planned action and changes nothing. `-SkipTasks` installs files, directories, and registry only with no scheduled task. `-Portable` uses current-directory mode with no registry or task writes. `-NonInteractive` with `-TorboxApiKey` is for automation and exits `2` on preflight failure. Exit codes are `0` ok, `1` failed, `2` preflight failed. Everything is logged to `install-<date>.log` under `BaseDir\logs` (fallback: script directory, then temp).

The installer runs these steps in order and stops on the first failure with rollback of `.bak` files, `.reg` backups, and any partially created task:

1. Preflight: admin check with a friendly message (offers relaunch as Administrator or the `-Portable` alternative, never a silent fail), PowerShell 5.1 or newer check, idempotency probe (existing receipt, task, or protocol means upgrade in place), and `pwsh` exe resolution for the task and supervisor start.
2. Tool detection table for `pwsh`, `python`, `node`, and `rclone` with versions and download links for anything missing.
3. Prompt for `TORBOX_API_KEY` with a masked-input option (reuses `$env:TORBOX_API_KEY` when present), scope choice Machine (default) or User (skipped when `-KeyScope` was given, in `-Portable`, or in `-NonInteractive`), then exactly one TorBox validation call before any mutation. Abort before changes when validation fails.
4. Create the `F:\Jellyfin` directory layout (`logs`, `cache`, `run`, `backups`, plus `.install-versions`), keeping existing directories.
5. Persist the key: `[Environment]::SetEnvironmentVariable` to the chosen Machine/User scope plus `$env:TORBOX_API_KEY`, verified by read-back. In `-Portable`, load the key into the session only plus a `portable.env` note; write no Machine/User value.
6. Register the `potplayer://` plus `potplayer64://` protocol handler to the `potplayer-launcher.ps1` wrapper (direct PotPlayer exe fallback), backing up each `HKCR` key to a `.reg` file first and verifying by read-back. Skipped in `-Portable`; the manual step (`register-potplayer-protocol.ps1` from an elevated shell) is printed instead. Details are in [PotPlayer](potplayer.md).
7. Create the `MediaStackSupervisor` scheduled task (AtLogOn, highest run level) via cmdlets first with `schtasks.exe` fallback, backing up any existing task XML first and verifying the task is present. Skipped with `-SkipTasks` or `-Portable`; the exact manual `schtasks /Create` command is printed instead.
8. Start the supervisor once with `supervisor.ps1 -Mode Start` and verify exit code `0`. Warns and continues to health checks when mounts still need rclone remotes. Skipped when tasks were skipped. After success, use `supervisor.ps1` Run or Start mode as shown in [Quickstart](quickstart.md) and [Supervisor](supervisor.md).
9. Health-check table with TCP plus HTTP probes: `:8888/health` (torbox-proxy), `:18099/health` (bridge), `:18080/health` (control panel), `:8096/System/Info/Public` (Jellyfin). Rows report `PASS`, `PORT-ONLY`, or `FAIL`; fresh installs may show `FAIL` until Jellyfin and the proxy finish their first start.
10. Write the install receipt plus version stamp (installer name, version, install time, user, computer, base dir, task name, upgraded flag, options, tool and health rows, and TorBox key length, scope, and validation result only; key material is never written), then show the final summary with the four URLs, next steps (`rclone listremotes` for `torbox:` and `gdrive-media:`, open the panel and use Start all, play via `potplayer://` links), and log locations (installer log, receipt, supervisor log, launcher log, Jellyfin data log).

Only paths, ports, and switches are forwarded between steps, and no tokens are passed on the command line except the explicit automation `-TorboxApiKey` value. Re-running is idempotent: existing installs are detected and upgraded in place without duplicating tasks or protocol keys.

## Interactive setup with setup-wizard.ps1

Use the wizard for guided first-run configuration with validation on every prompt (`q` quits, `back` returns, defaults accepted with Enter):

```powershell
pwsh -File setup-wizard.ps1
pwsh -File setup-wizard.ps1 -Resume
pwsh -File setup-wizard.ps1 -NonInteractive
```

`-Resume` continues from the saved `setup-answers.json`. `-NonInteractive` reads that answers file only with secrets taken from the environment (`$env:TORBOX_API_KEY`, `$env:JELLYFIN_API_KEY`); it never prompts and requires a valid answers file from a prior interactive run.

The menu runs in this order with a progress counter (`step X of 10`):

1. TorBox key plus scope: masked entry, Machine (default) or User choice, persist plus verify via one `GET /v1/api/user/me` call.
2. Library roots editor: add, remove, list, done (for example `F:\TorboxMedia`), validating characters and flagging missing paths for creation on apply.
3. Jellyfin connection test: server URL (default `http://127.0.0.1:8096`) plus optional API token, checked with `GET {url}/System/Info/Public` (no auth needed; the token is stored for later).
4. PotPlayer path auto-detect via registry DAUM keys, `App Paths`, Program Files scan, and `PATH`, with manual `.exe` override.
5. `rclone.conf` presence check (`config\rclone.conf`, `F:\Jellyfin\config\rclone.conf`, `%APPDATA%\rclone\rclone.conf`) plus guided pointer to create it with `rclone --config "<path>" config` and verify with `rclone --config "<path>" lsd <remote>:`.
6. Port availability check for `8888`, `18099`, `18080`, and `8096` with occupant process name (`Get-NetTCPConnection` first, `netstat -ano` fallback). `IN USE` is fine when the occupant is your own service; investigate only unexpected owners.
7. Playback mode choice: `FullSeason` (default, whole season queued) versus `Single` (one item only), persisted to `$env:POTPLAYER_SINGLE` plus the answers file.
8. Dry-run summary of every pending change (env vars masked, library directories marked `exists` or `CREATE`, files, and checks-only items including rclone path, ports, and the four health probes) before apply.
9. Apply step with per-item ok or fail plus an automatic rollback list (user env restored to pre-apply values on failure, answers backup path printed).
10. Post-setup health check reusing the installer probes: `:8888/health`, `:18099/health`, `:18080/health`, `:8096/System/Info/Public`.
11. Save answers plus opt-in open of the panel URL plus finish screen with docs links.

Answers are saved to `setup-answers.json` minus secrets, and the run is appended to `setup-wizard.log` with secrets redacted. TorBox keys and Jellyfin tokens live only in memory plus User and process environment variables; they are never written to the answers file or the log.

## Step-by-step verification matrix

Use this matrix to verify every step of `install.ps1` and `setup-wizard.ps1` independently, matching the installer's internal checks:

| Step / Action | Command | Expected Output | What Failure Looks Like |
| --- | --- | --- | --- |
| **1. Admin check & PS version** | `[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent(); $PSVersionTable.PSVersion` | IsInRole `True` for Administrator; Major `>= 5` (recommend `>= 7`) | `[fail] Preflight failed: not elevated` (exit `2`), prompt offer to re-launch as Admin, or PS `< 5.1` abort |
| **2. Tool detection** | `pwsh --version; python --version; node --version; rclone --version` | Formatted table showing `Found: yes` and versions for `pwsh`, `python`, `node`, `rclone` | `Found: NO` with download link warning (e.g. `Missing python: install from https://www.python.org/downloads/windows/`) |
| **3. TorBox key validation** | `Invoke-RestMethod "https://api.torbox.app/v1/api/user/me?token=$env:TORBOX_API_KEY"` | `success: True` with user profile object (`[ok] TorBox key validated`) | HTTP 401/403/422 or network exception; `[fail] TorBox rejected the key (HTTP 401)` (exit `1`) |
| **4. Directory layout** | `Test-Path F:\Jellyfin\logs, F:\Jellyfin\cache, F:\Jellyfin\run, F:\Jellyfin\backups, F:\Jellyfin\.install-versions` | All return `True` (`[ok] Directory layout ready`) | Permission error `Access is denied` or path not found; install triggers rollback |
| **5. Key persistence** | `[Environment]::GetEnvironmentVariable('TORBOX_API_KEY', 'Machine'); [Environment]::GetEnvironmentVariable('TORBOX_API_KEY', 'User')` | Returns non-empty key string matching chosen scope | Empty string or `Could not persist TORBOX_API_KEY to Machine scope: Access is denied` |
| **6. Protocol registration** | `(Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\potplayer\shell\open\command').'(default)'; (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\potplayer64\shell\open\command').'(default)'` | Both show `powershell.exe ... -File "F:\Jellyfin\potplayer-launcher.ps1" "%1"` | Empty/missing key or `Verification failed: potplayer handler is empty` |
| **7. Scheduled task** | `Get-ScheduledTask -TaskName 'MediaStackSupervisor' \| Select-Object TaskName, State` | `TaskName: MediaStackSupervisor`, `State: Ready` | `Task verification failed: MediaStackSupervisor not found`; prints manual `schtasks /Create` command |
| **8. Supervisor Start** | `pwsh -File F:\Jellyfin\supervisor.ps1 -Mode Start; $LASTEXITCODE` | Exit code `0` (`[ok] Supervisor Start completed (exit 0)`) | Exit code `!= 0`; mounts down, proxy fails to bind port, or missing prerequisite remotes |
| **9. Health table: Proxy (:8888)** | `Invoke-RestMethod http://127.0.0.1:8888/health` | `status: "ok"` or `{"status":"ok"}` (TCP listening, HTTP pass) | Connection refused (`FAIL`), HTTP 5xx, or process not listening |
| **9. Health table: Bridge (:18099)** | `Invoke-RestMethod http://127.0.0.1:18099/health` | HTTP `200` response (TCP listening, HTTP pass) | Connection refused (`FAIL`), port closed, or proxy prerequisite down |
| **9. Health table: Panel (:18080)** | `Invoke-RestMethod http://127.0.0.1:18080/health` | `status: "ok"` with version (TCP listening, HTTP pass) | Connection refused (`FAIL`), port conflict, or pythonw process crashed |
| **9. Health table: Jellyfin (:8096)** | `Invoke-RestMethod http://127.0.0.1:8096/System/Info/Public` | JSON with `ServerName`, `Version`, `Id` | Connection refused (`FAIL`), port closed, or server still starting |
| **10. Receipt & version stamp** | `Get-Content F:\Jellyfin\.install-versions\install.receipt.json \| ConvertFrom-Json` | JSON with `status: "installed"`, `installer: "oneclick-install"`, masked key metadata (no secrets) | File missing, invalid JSON, or TorBox key material found in JSON payload |
| **Wizard: Library roots** | `Test-Path F:\TorboxMedia` | `True` for each configured library root | `missing` flag in wizard table, created on wizard apply |
| **Wizard: Port occupancy** | `Get-NetTCPConnection -LocalPort 8888,18099,18080,8096 -State Listen -ErrorAction SilentlyContinue` | Ports free before start, occupied by expected stack processes after start | Unexpected occupant process name (e.g. conflicting web server or zombie PID) |
| **Wizard: rclone.conf check** | `rclone --config "F:\Jellyfin\config\rclone.conf" listremotes` | Lists configured remotes (e.g. `torbox:`, `gdrive-media:`) | `rclone.conf NOT found` warning; wizard provides step-by-step `rclone config` instructions |

## Manual install in order

Run the same `install.ps1` order by hand from the repo root when you need to debug one artifact, checking health after mounts, proxy, bridge, Jellyfin, and panel:

1. Confirm tool detection (`pwsh`, `python`, `node`, `rclone`) and install anything missing from the download links the installer prints.
2. Set or confirm `TORBOX_API_KEY` at Machine or User scope in a fresh terminal, then validate with the single `user/me` call before mutating anything.
3. Ensure the `F:\Jellyfin` layout (`logs`, `cache`, `run`, `backups`, `.install-versions`) exists.
4. Register the `potplayer://` plus `potplayer64://` handler from an elevated prompt, then verify both command values read back correctly. Details are in [PotPlayer](potplayer.md).
5. Create or verify the `MediaStackSupervisor` logon task, or record the manual `schtasks /Create` line the installer prints when tasks are skipped.
6. Run `supervisor.ps1 -Mode Start` once and confirm exit code `0`, then run the four health probes from [Verify the install](#verify-the-install).
7. Confirm the receipt and version stamp were written under `.install-versions`.

For service-by-service reinstalls only, the advanced orchestrator `install-all.ps1` calls six service installers in dependency order and stops on the first failure: `install-rclone-service.ps1` (mount service foundation), `create_rclone_mcp.ps1` (MCP bridge), `register-potplayer-protocol.ps1` (`potplayer://` handlers, needs elevation), `update_registry.ps1` (wrapper launcher handler), `lock_registry.ps1` (final locked handler state), `install-control-panel.ps1` (top-level UI last). It supports `-Uninstall` in reverse order and audits version stamps after each run.

Each installer writes a version stamp on success and supports a rollback path that restores file backups and re-imports registry backups when a step fails.

## Portable run without tasks

Run `install.ps1 -Portable` for current-directory mode with no registry or scheduled-task writes. The base dir defaults to the script directory, the key stays in the session plus a `portable.env` note (no Machine/User persist), protocol registration is skipped (run `register-potplayer-protocol.ps1` from an elevated shell later to enable `potplayer://` links), task creation and supervisor start are skipped (start services with `supervisor.ps1 -Mode Start` for a one-time ordered start or Run mode for ordered start plus the looping watchdog), and the health table still prints as informational. Open the same loopback URLs from [Quickstart](quickstart.md). Alternatively, copy or clone the repo to any folder, set the same environment variables from [TorBox](torbox.md), and start services directly. Nothing is written outside the repo except user-scope tasks you explicitly opt into.

## Verify the install

Check version stamps, tasks, ports, and app health from the repo root:

```powershell
pwsh -File supervisor.ps1 -Mode Status
pwsh -File check_status.ps1 -AsJson
pwsh -File check_user_views.ps1 -AsJson
rclone listremotes
Invoke-RestMethod http://127.0.0.1:8888/health
Invoke-RestMethod http://127.0.0.1:18099/health
Invoke-RestMethod http://127.0.0.1:18080/health
Invoke-RestMethod http://127.0.0.1:8096/System/Info/Public
```

Expect a healthy row for mounts, proxy, bridge, Jellyfin, and panel from Status mode, exit code `0` from the status scripts (`0` OK, `1` WARNING such as zero libraries or views, `2` CRITICAL such as API down or missing `JELLYFIN_USER` and `JELLYFIN_PASSWORD`), both remotes listed by rclone, and HTTP `200`-range responses from all four probes. The expected ports and probes are listed in [Architecture](architecture.md) and [Docs Index](index.md), and failure patterns are in [Troubleshooting](troubleshooting.md). If views are empty right after a restart, wait about sixty seconds for the scan, then re-run the views check.

## Updating

Updating is a pull plus a rerun plus a verify, and it preserves untracked runtime state.

1. Stop the stack cleanly with Stop mode so VFS and Jellyfin flush.
2. Pull the latest branch with git pull.
3. Re-run the one-click installer (`pwsh -File install.ps1`), which detects the existing install and upgrades each artifact in place, refreshing receipts without duplicating tasks or protocol keys.
4. Start the stack with the supervisor and run the full verify block above plus the post-restart views probe.
5. If views are warming, wait sixty seconds and re-trigger a library refresh before investigating logs.

Do not copy tracked files over local untracked config. Keep the untracked rclone config, tunnel config, and env values, and compare any new template files by hand.

## Uninstall and clean removal

Remove only what `install.ps1` installed (user data is kept):

```powershell
pwsh -File install.ps1 -Uninstall
```

This attempts `supervisor.ps1 -Mode Stop` first (best effort), then removes the `MediaStackSupervisor` task, removes the `potplayer` and `potplayer64` protocol keys under the classes root (with `.reg` backup first), clears `TORBOX_API_KEY` from Machine plus User scope and the session (`portable.env` only in `-Portable` mode), and deletes the receipt plus version stamp. Then finish manual cleanup:

- Run `supervisor.ps1 -Mode Stop` to stop panel, Jellyfin, bridge, proxy, and mounts in reverse order when the best-effort stop did not cover it.
- Confirm no listener remains on the proxy (`8888`), bridge (`18099`), panel (`18080`), Jellyfin (`8096`), and rclone RC ports.
- Remove the per-user logon task named for the control panel and the supervisor task when present.
- Remove the `potplayer` and `potplayer64` protocol keys under the classes root only if you intend to fully detach playback.
- Delete the version stamp folder and any registry backup folder created under it.
- Leave untracked runtime folders such as logs, cache, transcodes, data, run, backups, and config in place until you have exported what [Reference](reference.md) says to back up, then delete them for a fully clean disk.

For the advanced per-service path only, `pwsh -File install-all.ps1 -Uninstall` reverses its six steps in reverse order with stamp removal verified per step.

Reboot and confirm the panel no longer auto-starts and no mount processes return on their own.

## Version stamps and receipts

Every installer writes a JSON receipt with name, version, install time, user, computer, base dir, task name, upgraded flag, options, tool and health rows, and TorBox key length, scope, and validation result only (key material is never written) under `.install-versions` (for example `install.receipt.json` plus the version stamp). The orchestrator audits stamps after both install and uninstall and warns when a stamp is missing after install or still present after uninstall. Keep these receipts for support and include them when you collect the forensics bundle from [Supervisor](supervisor.md).

---

Back to [Docs Index](index.md).
