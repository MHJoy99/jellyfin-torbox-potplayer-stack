# Install, Update, and Uninstall

This guide covers every install path plus updating and clean removal, so one file owns the full lifecycle from first setup to final teardown.

## Contents

- [Which path to pick](#which-path-to-pick)
- [One-click install](#one-click-install)
- [Manual install in order](#manual-install-in-order)
- [Portable run without tasks](#portable-run-without-tasks)
- [Verify the install](#verify-the-install)
- [Updating](#updating)
- [Uninstall and clean removal](#uninstall-and-clean-removal)
- [Version stamps and receipts](#version-stamps-and-receipts)

## Which path to pick

Use the one-click orchestrator when you want the supported order with automatic verification. Use manual steps when you need to debug one service or reinstall a single piece. Use the portable run when you cannot create scheduled tasks or services and only want processes under your current session. All paths share the same health endpoints and the same env-only secrets rule described in [TorBox](torbox.md) and [Reference](reference.md).

## One-click install

Run from the repo root in PowerShell 7 or newer:

```powershell
pwsh -File install-all.ps1
```

The orchestrator calls six installers in dependency order and stops on the first failure:

1. `install-rclone-service.ps1` for the cloud mount service, which is the foundation.
2. `create_rclone_mcp.ps1` for the MCP bridge over rclone and its config.
3. `register-potplayer-protocol.ps1` for the `potplayer://` handlers, which needs elevation.
4. `update_registry.ps1` for the wrapper launcher handler.
5. `lock_registry.ps1` for the final locked handler state.
6. `install-control-panel.ps1` for the top-level UI last.

Only paths, ports, and switches are forwarded between steps, and no tokens are passed on the command line. If a step fails, fix it, then re-run the orchestrator, which is idempotent and upgrades matching handlers in place. After success, start the stack with `supervisor.ps1` as shown in [Quickstart](quickstart.md) and [Supervisor](supervisor.md).

## Manual install in order

Run each installer from the repo root in the same order the orchestrator uses, checking health after mounts, proxy, Jellyfin, and panel.

1. Install the rclone mount service first and confirm the TorBox mount and Drive mount are browsable and that the rclone RC port answers for VFS calls.
2. Create the rclone MCP bridge and run the MCP smoke script `test_mcp_server.ps1` to confirm listing still works.
3. Register the PotPlayer protocol from an elevated prompt, then verify both `potplayer://` and the 64-bit variant resolve to the installed player. Details are in [PotPlayer](potplayer.md).
4. Apply the wrapper registry update, then the registry lock, verifying each protocol command value reads back correctly.
5. Install the control panel last, which registers the per-user logon task plus Start Menu shortcut and checks panel health. Details are in [Panel](panel.md).

Each installer writes a version stamp on success and supports a rollback path that restores file backups and re-imports registry backups when a step fails.

## Portable run without tasks

Copy or clone the repo to any folder, set the same environment variables from [TorBox](torbox.md), and start services directly without registering tasks or services. Use `supervisor.ps1 -Mode Start` for a single ordered start, or Run mode for ordered start plus the looping watchdog. Open the same three loopback URLs from [Quickstart](quickstart.md). Skip the mount service and use foreground rclone mounts when a service install is not allowed. Nothing is written outside the repo except user-scope tasks you explicitly opt into.

## Verify the install

Check version stamps, tasks, ports, and app health:

```powershell
pwsh -File supervisor.ps1 -Mode Status
pwsh -File check_status.ps1 -AsJson
pwsh -File check_user_views.ps1 -AsJson
pwsh -File test_mcp_server.ps1
Invoke-RestMethod http://127.0.0.1:8888/health
Invoke-RestMethod http://127.0.0.1:18080/health
```

Expect a healthy row for mounts, proxy, bridge, Jellyfin, and panel, exit code zero from status checks, and a passing MCP smoke test. The expected ports and probes are listed in [Architecture](architecture.md), and failure patterns are in [Troubleshooting](troubleshooting.md).

## Updating

Updating is a pull plus a rerun plus a verify, and it preserves untracked runtime state.

1. Stop the stack cleanly with Stop mode so VFS and Jellyfin flush.
2. Pull the latest branch with git pull.
3. Re-run the one-click installer, which upgrades each step in place and refreshes version stamps without duplicating tasks or protocol keys.
4. Start the stack with the supervisor and run the full verify block above plus the post-restart views probe.
5. If views are warming, wait sixty seconds and re-trigger a library refresh before investigating logs.

Do not copy tracked files over local untracked config. Keep the untracked rclone config, tunnel config, and env values, and compare any new template files by hand.

## Uninstall and clean removal

The orchestrator reverses the same six steps in reverse order:

```powershell
pwsh -File install-all.ps1 -Uninstall
```

This removes the panel task and shortcut, unlocks and removes the protocol keys, removes the MCP bridge registration, and removes the mount service, with stamp removal verified per step. Then finish manual cleanup:

- Run `supervisor.ps1 -Mode Stop` to stop panel, Jellyfin, bridge, proxy, and mounts in reverse order.
- Confirm no listener remains on the proxy, bridge, panel, Jellyfin, and rclone RC ports.
- Remove the per-user logon task named for the control panel and the supervisor task when present.
- Remove the `potplayer` and `potplayer64` protocol keys under the classes root only if you intend to fully detach playback.
- Delete the version stamp folder and any registry backup folder created under it.
- Leave untracked runtime folders such as logs, cache, transcodes, data, run, backups, and config in place until you have exported what [Reference](reference.md) says to back up, then delete them for a fully clean disk.

Reboot and confirm the panel no longer auto-starts and no mount processes return on their own.

## Version stamps and receipts

Every installer writes a JSON receipt with name, version, install time, user, computer, and status under the version folder. The orchestrator audits stamps after both install and uninstall and warns when a stamp is missing after install or still present after uninstall. Keep these receipts for support and include them when you collect the forensics bundle from [Supervisor](supervisor.md).

---

Back to [Docs Index](index.md).
