# TorBox Setup and Key Rotation

This guide explains where the TorBox API key comes from, how to expose it to every service through the environment, and how to rotate it without breaking playback.

## Contents

- [Where to get the key](#where-to-get-the-key)
- [Environment setup](#environment-setup)
- [How the proxy uses the key](#how-the-proxy-uses-the-key)
- [Rotation without downtime](#rotation-without-downtime)
- [Verify after any change](#verify-after-any-change)

## Where to get the key

Get the key from the TorBox web dashboard under settings and API access, where you can create a Machine or User scoped key for automation. Use a dedicated key for this stack so revoking it affects only local playback and sync. Copy the value once into a password manager, because the dashboard may only show it at creation time. Never paste the key into chat logs, screenshots, or tracked files. If you suspect exposure, revoke it in the same dashboard screen and issue a replacement.

## Environment setup

All credentials come from the environment or the OS credential store, and no script in this repo accepts a token as a committed default.

- Set `TORBOX_API_KEY` at Machine or User scope so the proxy, launcher, and supervisor all see the same value.
- The supervisor re-reads the live Machine value, then the User value, on every start, which repairs child shells that were opened before the key was set.
- Keep `JELLYFIN_USER`, `JELLYFIN_PASSWORD`, and `JELLYFIN_API_KEY` in the same scopes and never in scripts.
- Keep the real rclone config untracked and edit only the template copy when sharing examples.

Open a fresh terminal after setting Machine scope, because existing processes keep their old snapshot. Confirm visibility with the status scripts before starting the proxy, as described in [Quickstart](quickstart.md) and [Supervisor](supervisor.md).

## How the proxy uses the key

The local proxy in `server/torbox-proxy.py` is the only component that calls TorBox with the key, which keeps the secret in one place.

- TorBox requires the key as a `token` query parameter, while header-only auth returns HTTP 422, so the proxy always builds query auth.
- The proxy serves stable local URLs shaped like proxy host plus torrent, file, and display name, then302-redirects each request to a fresh CDN link, so playlists never store expiring CDN tokens.
- A shared `mylist` cache is refreshed from TorBox at most once per ten minutes, with concurrent callers coalesced so parallel probes cause one upstream call.
- A token bucket paces download-link calls and backs off on rate-limit responses, with live counters on the metrics endpoint.
- The proxy stays on HTTP version 1.0 for compatibility, and per-IP stream slots plus latency histograms are exposed for the panel and Prometheus.

Because proxy URLs re-resolve the CDN on every request, they stay valid across rotation, while direct CDN URLs expire and must never be cached. Architecture and tuning details are in [Architecture](architecture.md).

## Rotation without downtime

Rotate in this order so playback keeps working while the old key drains.

1. Issue the new key in the TorBox dashboard and store it in your password manager.
2. Update `TORBOX_API_KEY` at the same Machine or User scope the stack already uses.
3. Restart the TorBox proxy first, then the supervisor or panel so children inherit the fresh snapshot.
4. Test the CDN path with a launcher play and a direct proxy health plus `mylist` check.
5. Revoke the old key in the dashboard only after the new path plays and sync succeeds.
6. Re-run the MCP smoke test and the Jellyfin status check to confirm automation still authenticates.

If you also rotate Jellyfin credentials, update their env values and re-run the status scripts with no file edits, then restart panel and proxy. The reboot checklist in [Supervisor](supervisor.md) applies after any rotation.

## Verify after any change

```powershell
pwsh -File check_status.ps1 -AsJson
pwsh -File test_mcp_server.ps1
Invoke-RestMethod http://127.0.0.1:8888/health
Invoke-RestMethod http://127.0.0.1:8888/mylist
Invoke-RestMethod http://127.0.0.1:8888/metrics
```

Expect exit code zero, a fresh `mylist` payload, and metrics without sustained rate-limit counters. If `mylist` looks stale, confirm the proxy age header and force one refresh rather than hammering the API. If every TorBox call returns auth errors, confirm the live env value the supervisor sees and check for an extra header-only client in [Troubleshooting](troubleshooting.md). Security rules for storing and sharing keys are in [Reference](reference.md).

---

Back to [Docs Index](index.md).
