# Quickstart

This quickstart expands the README setup into a copy-plus-detail path that takes a fresh machine from secrets to first playback in minutes. It follows the same order as `install.ps1` and `setup-wizard.ps1`: install first, configure second, start third.

## Contents

- [Prerequisites](#prerequisites)
- [Three-step setup](#three-step-setup)
- [Verify everything](#verify-everything)
- [Play something](#play-something)
- [Next steps](#next-steps)

## Prerequisites

You need Windows 10/11 x64 with PowerShell 5.1 or newer (PowerShell 7 or newer recommended), Python 3.11 or newer for the proxy, bridge, and panel, Node.js, rclone with WinFsp for the mounts, PotPlayer 64-bit installed before protocol registration, Jellyfin server files in the repo `server` folder or an existing Jellyfin on `:8096`, and NSSM when mounts run as services. `install.ps1` prints a versions table for `pwsh`, `python`, `node`, and `rclone` with download links (`https://aka.ms/pwsh`, `https://www.python.org/downloads/windows/`, `https://nodejs.org/en/download`, `https://rclone.org/downloads/`) for anything missing. Run the default install elevated (registry plus Machine environment plus the `MediaStackSupervisor` logon task need admin); use `install.ps1 -Portable` when admin is not available. Keep the repo folder path short and without special characters, and have your TorBox API key ready (Machine or User scope from the TorBox dashboard under Settings and API access). For the wizard path you also need a library root (for example `F:\TorboxMedia`), a Jellyfin URL (default `http://127.0.0.1:8096`), and an `rclone.conf` (expected at `config\rclone.conf`, `F:\Jellyfin\config\rclone.conf`, or `%APPDATA%\rclone\rclone.conf`).

## Three-step setup

This mirrors the `install.ps1` plus `setup-wizard.ps1` plus supervisor order, with extra detail so each step can be checked. Full options, exit codes, and rollback behavior are in [Install](install.md).

### 1. Install with install.ps1

Run the one-click installer from the repo root (elevated for the default path):

```powershell
pwsh -File install.ps1
```

Preview without changes with `pwsh -File install.ps1 -WhatIf`. For automation use `pwsh -File install.ps1 -TorboxApiKey $env:TORBOX_API_KEY -KeyScope User -NonInteractive`. For files only use `-SkipTasks`; for no registry or task writes use `-Portable`.

In order, the installer checks admin rights plus PowerShell version, prints the tool versions table, prompts for `TORBOX_API_KEY` with a masked-input option (reusing `$env:TORBOX_API_KEY` when present) and a Machine (default) or User scope choice, validates the key with exactly one `GET /v1/api/user/me?token=<key>` call before any mutation, creates the `F:\Jellyfin` layout (`logs`, `cache`, `run`, `backups`, plus `.install-versions`), persists the key to the chosen scope with read-back verification (session only plus `portable.env` note in `-Portable` mode), registers the `potplayer://` plus `potplayer64://` handler with registry backup and read-back verification, creates the `MediaStackSupervisor` AtLogOn task with verification, runs `supervisor.ps1 -Mode Start` once, prints the TCP plus HTTP health table for `8888`, `18099`, `18080`, and `8096`, writes the receipt plus version stamp (key length, scope, and validation result only; never the key), and shows the final summary with URLs and log locations. Set secrets only in the environment, and never commit them to git. See [TorBox](torbox.md) for where the key comes from and how to rotate it.

The installer also covers the env values the health scripts need:

- `TORBOX_API_KEY` with Machine or User scope is required by the proxy, the launcher, and the supervisor, which re-reads the live Machine or User value on start.
- `JELLYFIN_USER` and `JELLYFIN_PASSWORD` are used by health scripts, with no hardcoded fallbacks.
- `JELLYFIN_API_KEY` is used by automation after you issue it from the Jellyfin dashboard.

Set them at Machine or User scope, then open a fresh terminal so the new values are visible. Confirm with `check_status.ps1 -AsJson`, which exits `0` for OK, `1` for WARNING, and `2` for CRITICAL.

### 2. Configure with setup-wizard.ps1 (recommended for first run)

Run the interactive wizard from the repo root after `install.ps1`:

```powershell
pwsh -File setup-wizard.ps1
```

Re-run with `pwsh -File setup-wizard.ps1 -Resume` to continue from the saved `setup-answers.json`, or headless with `pwsh -File setup-wizard.ps1 -NonInteractive` (answers file only, secrets from `$env:TORBOX_API_KEY` and `$env:JELLYFIN_API_KEY`).

The wizard menu runs TorBox key plus scope with one-call verification, library roots add and remove and list, Jellyfin URL plus token tested with `GET {url}/System/Info/Public`, PotPlayer auto-detect with manual `.exe` override, `rclone.conf` presence check with `rclone --config "<path>" config` guidance, port availability for `8888`, `18099`, `18080`, and `8096` with occupant process names, playback mode `FullSeason` (default) versus `Single` persisted to `$env:POTPLAYER_SINGLE`, dry-run summary of every pending change, apply with per-item results and a rollback list, health check of the four probes, and save plus opt-in browser open. Answers exclude secrets and the log redacts them.

### 3. Start the stack and open the local URLs

Run the supervisor from the repo root:

```powershell
pwsh -File supervisor.ps1 -Mode Start
pwsh -File supervisor.ps1 -Mode Run
pwsh -File supervisor.ps1 -Mode Status
```

`Start` performs one ordered start of mounts, proxy, bridge, Jellyfin, and panel with health gates that abort on the first failure. `Run` (the default when no `-Mode` is given) does the same ordered start and then loops the watchdog. `Status` prints the per-service table. Full mode details are in [Supervisor](supervisor.md), and the full installer order is in [Install](install.md).

Then open the local URLs:

- Panel at `http://127.0.0.1:18080`
- Proxy at `http://127.0.0.1:8888`
- Bridge at `http://127.0.0.1:18099`
- Jellyfin at `http://127.0.0.1:8096`

The panel is bound to localhost only and is registered as a logon task with a Start Menu shortcut, so it is available after sign-in without a console window. The proxy stays on HTTP version 1.0 because some clients hang when the length header is missing under 1.1.

## Verify everything

Run these from the repo root after the supervisor reports a complete ordered start:

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

Expect exit code `0` from the status scripts (`1` means WARNING such as zero libraries or views, `2` means CRITICAL such as API down or missing `JELLYFIN_USER` and `JELLYFIN_PASSWORD`), both remotes (`torbox:`, `gdrive-media:`) from `rclone listremotes`, a healthy proxy response, bridge and panel responses, and the Jellyfin public info payload. If views are empty right after a restart, wait about sixty seconds for the scan, then re-run the views check. The reboot checklist and log locations are in [Supervisor](supervisor.md) and [Troubleshooting](troubleshooting.md).

## Play something

Open Jellyfin, pick an episode, and choose the Play in PotPlayer action, which builds a `potplayer://` link. The registry handler forwards it to the launcher shim, the launcher resolves the item, builds a full-season playlist, passes resume with seek, and PotPlayer starts. Progress posts back every few seconds and marks played at eighty percent. Details are in [Jellyfin](jellyfin.md) and [PotPlayer](potplayer.md).

## Next steps

- [Install](install.md) for one-click, wizard, manual, portable, update, and uninstall paths.
- [TorBox](torbox.md) for API key setup and rotation.
- [Panel](panel.md) for what each card and endpoint means.
- [FAQ](faq.md) for quick answers and [Troubleshooting](troubleshooting.md) when health checks fail.
- [Architecture](architecture.md) for the diagram and data flow and [Reference](reference.md) for security and backup.

---

Back to [Docs Index](index.md).
