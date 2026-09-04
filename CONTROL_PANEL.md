# Jellyfin Control Panel

The local control panel is available at:

`http://127.0.0.1:18080/`

It is bound to localhost only. The panel can start, stop, and restart:

- Google Drive Mount (`F:\Media` + `R:` alias) — via the `RcloneGdriveMount` NSSM service
- TorBox Mount (`T:\`) — via `E:\MediaServer\mount-torbox.ps1` / process stop
- Jellyfin on port `8096`
- TorBox Proxy on port `8888`
- PotPlayer Bridge on port `18099`

Mount health is checked against the real mount paths and rclone processes (not just config). **Start all / Restart all / Stop all** include the mounts (mounts start first, stop last). **Sync TorBox** requests the existing `MediaServer_TorboxSmartSync` scheduled task, so manual runs use the same single-instance path as the 30-minute schedule.

All launches use hidden background processes. The panel checks the real health endpoints and process listeners, so a green button is not based on configuration alone.

## Opening it

Search Windows for **Jellyfin Control Panel**. The shortcut is installed in the user Start menu. The panel itself is registered as the hidden **Jellyfin Control Panel** logon task, so the page is available after sign-in without opening a terminal or a window.

## Permanent duplicate-proxy fix

The old `torbox_proxy_hidden.vbs` Startup entry duplicated the `TorboxProxy` scheduled task. The Startup entry was removed after a verified backup at:

`F:\Jellyfin\backups\startup-cleanup-20260824\torbox_proxy_hidden.vbs`

The panel also reconciles any duplicate TorBox proxy listeners when **Start all** is pressed.

## Reinstall or repair the panel

Run this from PowerShell if the shortcut or logon task ever needs to be recreated:

```powershell
PowerShell -ExecutionPolicy Bypass -File F:\Jellyfin\install-control-panel.ps1
```

The panel does not expose credentials or service command lines through its HTTP API.
