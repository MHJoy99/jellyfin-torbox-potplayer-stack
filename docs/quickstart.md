# Quickstart

This quickstart expands the README setup into a copy-plus-detail path that takes a fresh machine from secrets to first playback in minutes.

## Contents

- [Prerequisites](#prerequisites)
- [Three-step setup](#three-step-setup)
- [Verify everything](#verify-everything)
- [Play something](#play-something)
- [Next steps](#next-steps)

## Prerequisites

You need Windows with PowerShell 7 or newer, Python 3.11 or newer, PotPlayer 64-bit, Jellyfin server files in the repo `server` folder, rclone with WinFsp, and NSSM when mounts run as services. Install PotPlayer before registering the protocol handler, and keep the repo folder path short and without special characters.

## Three-step setup

This mirrors the README setup, with extra detail so each step can be checked.

### 1. Set secrets as environment variables

Set secrets only in the environment, and never commit them to git.

- `TORBOX_API_KEY` with Machine or User scope is required by the proxy, the launcher, and the supervisor, which re-reads the live Machine or User value on start. See [TorBox](torbox.md) for where the key comes from and how to rotate it.
- `JELLYFIN_USER` and `JELLYFIN_PASSWORD` are used by health scripts, with no hardcoded fallbacks.
- `JELLYFIN_API_KEY` is used by automation after you issue it from the Jellyfin dashboard.

Set them at Machine or User scope, then open a fresh terminal so the new values are visible. Confirm with `check_status.ps1 -AsJson`, which must exit with code zero.

### 2. Start the stack with the supervisor

Run the supervisor from the repo root:

```powershell
pwsh -File supervisor.ps1
```

This performs the ordered start of mounts, proxy, bridge, Jellyfin, and panel, with health gates that abort on the first failure. For a one-time ordered start without the looping watchdog, use Start mode, and for a table of every service use Status mode. Full mode details are in [Supervisor](supervisor.md), and the full installer order is in [Install](install.md).

You can also start everything once with the one-click orchestrator `install-all.ps1`, which calls each installer in dependency order and stops on the first failure.

### 3. Open the three local URLs

- Panel at `http://127.0.0.1:18080`
- Proxy at `http://127.0.0.1:8888`
- Jellyfin at `http://127.0.0.1:8096`

The panel is bound to localhost only and is registered as a logon task with a Start Menu shortcut, so it is available after sign-in without a console window. The proxy stays on HTTP version 1.0 because some clients hang when the length header is missing under 1.1.

## Verify everything

Run these from the repo root after the supervisor reports a complete ordered start:

```powershell
pwsh -File check_status.ps1
pwsh -File check_status.ps1 -AsJson
pwsh -File check_user_views.ps1 -AsJson
Invoke-RestMethod http://127.0.0.1:8888/health
Invoke-RestMethod http://127.0.0.1:18080/health
```

Expect exit code zero from the status scripts, a healthy proxy response, and a panel response. If views are empty right after a restart, wait about sixty seconds for the scan, then re-run the views check. The reboot checklist and log locations are in [Supervisor](supervisor.md) and [Troubleshooting](troubleshooting.md).

## Play something

Open Jellyfin, pick an episode, and choose the Play in PotPlayer action, which builds a `potplayer://` link. The registry handler forwards it to the launcher shim, the launcher resolves the item, builds a full-season playlist, passes resume with seek, and PotPlayer starts. Progress posts back every few seconds and marks played at eighty percent. Details are in [Jellyfin](jellyfin.md) and [PotPlayer](potplayer.md).

## Next steps

- [Install](install.md) for one-click, manual, portable, update, and uninstall paths.
- [TorBox](torbox.md) for API key setup and rotation.
- [Panel](panel.md) for what each card and endpoint means.
- [FAQ](faq.md) for quick answers and [Troubleshooting](troubleshooting.md) when health checks fail.
- [Architecture](architecture.md) for the diagram and data flow and [Reference](reference.md) for security and backup.

---

Back to [Docs Index](index.md).
