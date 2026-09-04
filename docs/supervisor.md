# Supervisor Modes, Watchdog, and Forensics

This guide explains the supervisor modes, the ordered start chain, the watchdog with backoff, and the forensics bundle used for support.

## Contents

- [Modes](#modes)
- [Ordered start chain](#ordered-start-chain)
- [Watchdog](#watchdog)
- [Dedupe and single instance](#dedupe-and-single-instance)
- [Status output](#status-output)
- [Forensics bundle](#forensics-bundle)
- [Logs and alerts](#logs-and-alerts)

## Modes

Run every command from the repo root with PowerShell 7 or newer.

| Mode | Command | What it does |
| --- | --- | --- |
| Run | `pwsh -File supervisor.ps1 -Mode Run` | Default. Acquires the global mutex, does one ordered start, then loops the watchdog forever. |
| Start | `pwsh -File supervisor.ps1 -Mode Start` | Does one ordered start with health gates and exits, without looping. |
| Stop | `pwsh -File supervisor.ps1 -Mode Stop` | Stops panel, Jellyfin, bridge, proxy, and mounts in reverse order and clears the supervisor PID. |
| Status | `pwsh -File supervisor.ps1 -Mode Status` | Prints a table of path checks, PID files, live processes, listener PIDs, and healthy flags. |
| Forensics | `pwsh -File supervisor.ps1 -Mode Forensics` | Builds a timestamped zip of logs, PID files, and sync state for support. |

The supervisor creates no scheduled task and kills nothing on load. All side effects happen only inside the explicitly invoked mode. Secrets are refreshed from the live Machine then User environment at start, so children inherit values that were set after the parent shell opened. See [TorBox](torbox.md) for the env setup behind this step.

## Ordered start chain

The chain always runs mounts first and panel last, aborting on the first failed gate with an explicit log.

1. Drive mount through the mount service or fallback mount script, gated on the media folder path.
2. TorBox mount through its mount script, gated on the TorBox mount path.
3. Proxy in `server/torbox-proxy.py`, gated on proxy health with a thirty-second wait.
4. Bridge helper, gated on bridge health with a ten-second wait and requiring proxy healthy first.
5. Jellyfin server executable with data, config, cache, log, web, and transcoder folders ensured, gated on public system info with a sixty-second wait.
6. Panel in `control-panel/control_panel.py`, gated on panel health with a fifteen-second wait.

A healthy fast path logs OK and refreshes the PID file without restarting. A failed gate logs an abort naming the exact service, so downstream services are never started on a broken base. The same order is used by bulk panel actions in [Panel](panel.md).

## Watchdog

The watchdog loop runs every fifteen seconds and checks three signals per service: HTTP probe, mount path presence, and PID liveness with command-line matching that detects PID reuse.

- Healthy services reset their fail counter and refresh PID files from the live listener or process.
- The bridge is deferred while the proxy is down, preserving the same dependency the start chain enforces.
- Unhealthy services restart with three fast retries, then a sixty-second cooldown between further attempts.
- Restart timestamps feed a crash-loop alert when five restarts land inside ten minutes, which is log-only and never changes restart behavior.
- Transient-tolerant re-probes retry a few times before a duplicate start, which prevents a single flapped probe from spawning a second listener.

This is the same dedupe-first design the panel uses, so manual panel actions and the background watchdog cannot fight over one port.

## Dedupe and single instance

Only one process may own Run mode at a time through a global mutex, with a second instance exiting immediately. PID files live under the run folder, one per service plus supervisor. Dedupe keeps the listening PID for the proxy and bridge ports and kills non-listening duplicates, with per-parent forensics that log parent PID, truncated parent command, creation time, and a per-parent counter. A post-start listener guard settles, rechecks health, sweeps duplicates, and reports the surviving listener PID. Jellyfin and panel ports tolerate both loopback and all-interface binds, while proxy and bridge keep strict loopback semantics.

## Status output

Status mode prints one row per service with the check that was run, path or probe result, PID file value, PID-alive flag, live process IDs, listener PID, and final healthy flag. Use it before and after any restart, and paste it into support requests alongside the forensics bundle. The expected healthy values match the health probes in [Quickstart](quickstart.md) and the ports in [Architecture](architecture.md).

## Forensics bundle

Forensics mode stages and zips the current support evidence without touching tracked files.

- Included: rotated supervisor and launcher logs, proxy and bridge logs when present, every PID file under the run folder, and the Drive sync state JSON.
- Naming: timestamped zip under the backups folder, built through a temp staging copy so locked live logs are skipped with a warning instead of failing the bundle.
- Empty case: logs an explicit nothing-to-bundle warning when no files exist.
- Send the bundle plus Status output plus the exact failing health URL when asking for help.

Collect forensics before restarting a crashed loop, because restarts rotate evidence. Log locations for deeper digging are listed below and in [Troubleshooting](troubleshooting.md).

## Logs and alerts

The supervisor log lives under the logs folder with ten-megabyte rotation across five generations. Launcher, prefetch, playback, Jellyfin, proxy metrics, and MCP logs each have their own file or endpoint, all covered in the runbook flow. Watch for ordered-start aborts, watchdog restarts with fast-retry versus backoff reasons, dedupe lines that name kept versus killed PIDs, forensics lines with bundle paths, and crash-loop alerts that signal investigation before ports wedge. Pair this guide with [Panel](panel.md) for card meanings and [Reference](reference.md) for what to back up before deleting logs.

---

Back to [Docs Index](index.md).
