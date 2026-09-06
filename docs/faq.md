# Frequently Asked Questions

This FAQ answers the thirty most common questions in full sentences so each answer stands alone in search results.

## Contents

- [General](#general)
- [Questions and answers](#questions-and-answers)
  - [1. What is the NexusMedia Jellyfin stack?](#1-what-is-the-nexusmedia-jellyfin-stack)
  - [2. Where do I get the TorBox API key and how do I install it?](#2-where-do-i-get-the-torbox-api-key-and-how-do-i-install-it)
  - [3. How do Jellyfin libraries stay in sync with cloud files?](#3-how-do-jellyfin-libraries-stay-in-sync-with-cloud-files)
  - [4. Why does PotPlayer open the whole season instead of one episode?](#4-why-does-potplayer-open-the-whole-season-instead-of-one-episode)
  - [5. How does resume between Jellyfin and PotPlayer work?](#5-how-does-resume-between-jellyfin-and-potplayer-work)
  - [6. What does clicking a Play in PotPlayer link actually do?](#6-what-does-clicking-a-play-in-potplayer-link-actually-do)
  - [7. Which ports must be listening for a healthy stack?](#7-which-ports-must-be-listening-for-a-healthy-stack)
  - [8. What does the supervisor do when a service crashes?](#8-what-does-the-supervisor-do-when-a-service-crashes)
  - [9. Is it safe to expose the panel or proxy to the local network?](#9-is-it-safe-to-expose-the-panel-or-proxy-to-the-local-network)
  - [10. How do I update or fully remove the stack?](#10-how-do-i-update-or-fully-remove-the-stack)
  - [11. Why does the TorBox mount script leave a healthy mount alone instead of restarting it?](#11-why-does-the-torbox-mount-script-leave-a-healthy-mount-alone-instead-of-restarting-it)
  - [12. How is the TorBox VFS mount tuned for streaming?](#12-how-is-the-torbox-vfs-mount-tuned-for-streaming)
  - [13. What do Jellyfin Sessions calls do while PotPlayer is playing?](#13-what-do-jellyfin-sessions-calls-do-while-potplayer-is-playing)
  - [14. Why does the TorBox proxy reuse one shared session and one shared list cache?](#14-why-does-the-torbox-proxy-reuse-one-shared-session-and-one-shared-list-cache)
  - [15. What does a green panel card actually prove about service health?](#15-what-does-a-green-panel-card-actually-prove-about-service-health)
  - [16. Which panel health endpoints should I check first and what does each return?](#16-which-panel-health-endpoints-should-i-check-first-and-what-does-each-return)
  - [17. Why does the bridge stay unhealthy while the proxy is down?](#17-why-does-the-bridge-stay-unhealthy-while-the-proxy-is-down)
  - [18. Which bridge and proxy ports must stay on loopback and how are duplicates handled?](#18-which-bridge-and-proxy-ports-must-stay-on-loopback-and-how-are-duplicates-handled)
  - [19. What starts automatically after a reboot and what must be started by hand?](#19-what-starts-automatically-after-a-reboot-and-what-must-be-started-by-hand)
  - [20. Why are Jellyfin views empty right after a reboot and when should I worry?](#20-why-are-jellyfin-views-empty-right-after-a-reboot-and-when-should-i-worry)
  - [21. Which Windows scheduled tasks belong to this stack and how are they managed?](#21-which-windows-scheduled-tasks-belong-to-this-stack-and-how-are-they-managed)
  - [22. Why are the synchronization tasks excluded from supervisor watchdog restarts?](#22-why-are-the-synchronization-tasks-excluded-from-supervisor-watchdog-restarts)
  - [23. How does the control panel autostart without showing a console window?](#23-how-does-the-control-panel-autostart-without-showing-a-console-window)
  - [24. What should I do if the Drive mount does not autostart after a system reboot?](#24-what-should-i-do-if-the-drive-mount-does-not-autostart-after-a-system-reboot)
  - [25. How do I detect if Google Drive library sync has become stale or failed?](#25-how-do-i-detect-if-google-drive-library-sync-has-become-stale-or-failed)
  - [26. Why do `.strm` files sometimes turn into tiny ninety-three byte stubs and how is that fixed?](#26-why-do-strm-files-sometimes-turn-into-tiny-ninety-three-byte-stubs-and-how-is-that-fixed)
  - [27. What causes port conflicts on the TorBox proxy port and how does the stack resolve them?](#27-what-causes-port-conflicts-on-the-torbox-proxy-port-and-how-does-the-stack-resolve-them)
  - [28. How does the supervisor prevent port conflicts on the PotPlayer bridge port?](#28-how-does-the-supervisor-prevent-port-conflicts-on-the-potplayer-bridge-port)
  - [29. What happens if the control panel port is already bound by another application?](#29-what-happens-if-the-control-panel-port-is-already-bound-by-another-application)
  - [30. How do I safely stop and restart the entire stack when recovering from multiple service failures?](#30-how-do-i-safely-stop-and-restart-the-entire-stack-when-recovering-from-multiple-service-failures)

## General

These answers assume a default install from [Install](install.md) verified with [Quickstart](quickstart.md). Follow the cross-links for the full guide behind each short answer.

## Questions and answers

### 1. What is the NexusMedia Jellyfin stack?

The NexusMedia Jellyfin stack is a local-first media system that exposes TorBox and Drive files through rclone mounts, lists them in Jellyfin as `.strm` libraries with TMDB metadata, resolves them through a local proxy, plays them in PotPlayer with resume sync, and supervises every service with a panel plus watchdog.

### 2. Where do I get the TorBox API key and how do I install it?

You create a Machine or User scoped key in the TorBox dashboard under API access, then you set it only as the `TORBOX_API_KEY` environment variable at Machine or User scope and restart the proxy and supervisor so children inherit the fresh value. The full env setup and rotation order are in [TorBox](torbox.md).

### 3. How do Jellyfin libraries stay in sync with cloud files?

The sync scripts write one `.strm` file per episode or movie into the media folder, then Jellyfin scans that folder on library refresh and rebuilds views, seasons, and episodes from the new files. Mounts must be healthy before the scan, as explained in [Jellyfin](jellyfin.md) and [Supervisor](supervisor.md).

### 4. Why does PotPlayer open the whole season instead of one episode?

PotPlayer opens the whole season because the launcher intentionally builds a natural-sorted full-season `.dpl` playlist for every play, so next-episode navigation never needs another browser click. The playlist format and sample tests are covered in [PotPlayer](potplayer.md).

### 5. How does resume between Jellyfin and PotPlayer work?

Resume works because the launcher passes the saved Jellyfin offset as a seek argument on start, while the tracker posts progress every five seconds and marks the item played at eighty percent, which advances Next Up. The API calls and timing are listed in [Jellyfin](jellyfin.md) and [PotPlayer](potplayer.md).

### 6. What does clicking a Play in PotPlayer link actually do?

Clicking the link invokes a registered `potplayer://` URL that Windows forwards to the launcher shim, which decodes the payload, resolves item IDs and `.strm` targets, refreshes stale VFS entries, picks a VFS path or proxy URL, and starts PotPlayer with resume. Protocol registration is detailed in [PotPlayer](potplayer.md).

### 7. Which ports must be listening for a healthy stack?

A healthy stack listens on Jellyfin HTTP, the TorBox proxy, the control panel, the PotPlayer bridge, and rclone RC on loopback, with optional Caddy and FlareSolverr ports only when the edge profile is enabled. Every port plus its health probe is tabled in [Architecture](architecture.md) and summarized in the [Docs Index](index.md).

### 8. What does the supervisor do when a service crashes?

The supervisor probes every service every fifteen seconds with HTTP, path, and PID checks, then restarts failures with three fast retries followed by sixty-second cooldowns while logging dedupe, forensics, and crash-loop alerts. The modes and ordered chain are in [Supervisor](supervisor.md).

### 9. Is it safe to expose the panel or proxy to the local network?

No, you must not expose the panel or proxy to the local network without adding authentication and TLS, because both bind to localhost with no login by design and anyone on the network could control playback or services. The localhost rule and safer remote options are in [Reference](reference.md).

### 10. How do I update or fully remove the stack?

You update by stopping the stack, pulling the latest branch, re-running the one-click installer, and re-running every health check, while you uninstall by running the orchestrator in uninstall mode and then removing tasks, protocol keys, stamps, and runtime folders in the documented order. Both lifecycles are step-by-step in [Install](install.md), with backup guidance in [Reference](reference.md).

### 11. Why does the TorBox mount script leave a healthy mount alone instead of restarting it?

The TorBox mount script leaves a healthy mount alone because it first checks for a live rclone process serving the TorBox remote together with a browsable TorBox drive path, and it returns immediately with a healthy log line when both are present. This idempotent guard prevents a kill-loop where every supervisor or panel retry would kill a working mount and the fresh cold mount would never finish its file-system init inside the start wait, which previously caused repeated mount flapping. Only a missing path or a missing process triggers a controlled restart through a control-port unmount call followed by a process stop and a settle wait. The mount-first gating behind this behavior is described in [Supervisor](supervisor.md), and the stale-mount symptoms it protects are in [Troubleshooting](troubleshooting.md).

### 12. How is the TorBox VFS mount tuned for streaming?

The TorBox VFS mount is presented as a local drive letter through rclone with full cache mode plus capped size, capped age, and minimum free-space guards so large media can stream without filling the system disk. Reads use chunked fetching with read-ahead and buffering for fast sequential playback, while a multi-minute directory cache keeps listings snappy and a loopback control port allows targeted refreshes of stale paths instead of shortening the global cache. The mount log rotates when it grows past its size cap so a long-lived mount never grows unbounded. Cache and refresh trade-offs are explained in [Architecture](architecture.md), and the ordered mount gate before the proxy is in [Supervisor](supervisor.md).

### 13. What do Jellyfin Sessions calls do while PotPlayer is playing?

Jellyfin Sessions calls carry playback telemetry while PotPlayer is playing, because the hidden per-play tracker reports start, periodic progress, and stop events against the Jellyfin item, user, and server that were embedded in the play link. Progress is posted every five seconds with silent failure and backoff so telemetry never blocks playback, and the item is marked played at eighty percent watched, which is what advances Next Up to the following episode. Only one tracker runs per episode through a per-item mutex, so a second launch for the same item exits instead of double-reporting. Resume ownership and the eighty-percent rule are detailed in [Jellyfin](jellyfin.md), and tracker logging is covered in [PotPlayer](potplayer.md).

### 14. Why does the TorBox proxy reuse one shared session and one shared list cache?

The TorBox proxy reuses one pooled HTTP session with keep-alive connections for TorBox API and CDN calls so parallel plays and probes do not open a new connection per request. It also keeps one shared list cache that refreshes at most once per ten minutes with concurrent callers coalesced into a single upstream call, which avoids rate-limit cooldowns from polling. A token bucket paces download-link calls and backs off on rate-limit responses with live counters on the metrics endpoint, while every play URL stays stable and re-resolves to a fresh expiring CDN link per request. Proxy auth, caching, and tuning are detailed in [TorBox](torbox.md) and [Architecture](architecture.md).

### 15. What does a green panel card actually prove about service health?

A green panel card proves that a real process match, a real listener PID where applicable, and a real health probe all passed together, because the panel never trusts config alone. Jellyfin is healthy when public system info answers without auth, the proxy is healthy when its health endpoint answers and its metrics are fresh, the bridge is healthy only while its own health endpoint answers and the proxy is also healthy, each mount is healthy only when its media path is browsable plus its mount process exists, and the panel itself is healthy when its own health endpoint answers. Every start, stop, or restart action re-probes those real endpoints before flipping a card to green, with per-service locks preventing overlapping operations. Card definitions and the same ordered chain are in [Panel](panel.md) and [Supervisor](supervisor.md).

### 16. Which panel health endpoints should I check first and what does each return?

The minimal liveness endpoint is checked first for a fast up-or-down answer used by supervisors and installers, while the JSON health endpoint adds the same liveness plus version info for automation. The full status endpoint returns per-service state with PIDs, listener PIDs, VFS details, and playback summary plus a light mode that skips expensive scans for frequent polling. Metrics re-expose the proxy counters through a short cache, activity tails recent merged log lines with a shared limit, timeline merges timestamped entries with per-source quotas and pagination, and config exposes only non-secret panel settings. All endpoints are loopback-only with security headers and origin checks and never return tokens or command lines. Every endpoint and its polling guidance is tabled in [Panel](panel.md), with verify order in [Quickstart](quickstart.md).

### 17. Why does the bridge stay unhealthy while the proxy is down?

The bridge stays unhealthy while the proxy is down by design, because the start chain requires the proxy to be healthy first and gates the bridge behind it with its own health wait. The background watchdog preserves the same dependency by deferring bridge restarts while the proxy is also down, so it does not thrash a downstream helper whose upstream is missing. Bulk panel actions follow the same mount-first order in both directions, aborting on the first unhealthy gate and stopping in reverse order with mounts last. This dependency is documented in [Supervisor](supervisor.md) and [Panel](panel.md), with port assignments in [Architecture](architecture.md).

### 18. Which bridge and proxy ports must stay on loopback and how are duplicates handled?

The TorBox proxy port, the PotPlayer bridge port, the control panel port, the Jellyfin HTTP port, and the rclone control port all bind to loopback by default and must stay there unless Jellyfin alone is exposed through an authenticated TLS reverse proxy or tunnel. The proxy keeps compatibility-focused HTTP behavior, the bridge keeps strict loopback semantics, and the optional edge profile adds its own forwarded ports for TLS and indexer bypass only when that profile is enabled. Duplicate proxy or bridge listeners are reconciled by keeping the actual listening PID and stopping non-listening duplicates with forensics that record parent identity and creation time, plus a post-start guard that settles, rechecks health, and sweeps duplicates. Port assignments are in [Architecture](architecture.md), dedupe behavior is in [Supervisor](supervisor.md), and the no-auth LAN warning is in [Reference](reference.md).

### 19. What starts automatically after a reboot and what must be started by hand?

After a reboot, the control panel returns on its own after sign-in because it is registered as a hidden per-user logon task with a Start Menu shortcut and no console window, while the Drive mount persists through its service wrapper with auto-restart. The TorBox mount has no scheduled task and the supervisor creates no scheduled task and kills nothing on load, so the ordered stack must be started explicitly in Start or Run mode after the mounts are confirmed. The supported order is always Drive mount, then TorBox mount, then proxy with a thirty-second health wait, then bridge with a ten-second wait requiring proxy health, then Jellyfin with a sixty-second wait, then panel with a fifteen-second wait, aborting on the first failed gate. Task registration is covered in [Panel](panel.md) and [Install](install.md), modes and waits are in [Supervisor](supervisor.md), and missing-mount recovery is in [Troubleshooting](troubleshooting.md).

### 20. Why are Jellyfin views empty right after a reboot and when should I worry?

Jellyfin views are often empty right after a reboot because the library is still warming and the post-restart probe reports warming rather than failure, so the correct response is to wait about sixty seconds, re-run the views probe, and trigger a library refresh when warming is reported. Worry only when the probe reports investigate instead of warming, which points at scans, mounts, or logs rather than timing. The usual root cause is Jellyfin starting before the mounts were healthy, since a missing or warming VFS mount produces stub streams or missing views that a rescan cannot fix until the mount paths are browsable again. Status output plus the forensics bundle should be collected before restarting a crash loop, because restarts rotate evidence. Warming versus investigate codes are in [Jellyfin](jellyfin.md), symptom fixes are in [Troubleshooting](troubleshooting.md), and forensics timing is in [Supervisor](supervisor.md).

### 21. Which Windows scheduled tasks belong to this stack and how are they managed?

The scheduled tasks belonging to this stack are the per-user logon task for the control panel and the periodic synchronization tasks for TorBox and Google Drive library sync, while long-running services like the proxy, bridge, Jellyfin, and TorBox mount intentionally avoid task-scheduler supervision. The TorBox sync task runs on a thirty-minute schedule and shares its single-instance mutex with manual panel clicks, while the Drive sync task runs periodically to scan cloud remotes, update local `.strm` media files, and trigger library refreshes. Task installation and audit receipts are detailed in [Install](install.md), panel sync button wiring is in [Panel](panel.md), and recovery steps for missing tasks are in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).

### 22. Why are the synchronization tasks excluded from supervisor watchdog restarts?

The synchronization tasks are excluded from supervisor watchdog restarts because they are periodic batch jobs that execute run-to-completion passes under global mutex guards rather than continuous HTTP listeners or file-system daemons. Supervising them as continuous daemons would falsely treat normal run completions as process exits and spawn unnecessary restart loops that contend with active sync runs. The supervisor focuses strictly on the six core long-running services in the ordered chain, while sync tasks retain their independent schedules and status logging. The supervisor scope is defined in [Supervisor](supervisor.md), service definitions are in [Architecture](architecture.md), and task logs are listed in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).

### 23. How does the control panel autostart without showing a console window?

The control panel autostarts at user logon because its installer registers a per-user scheduled task configured to run quietly in the background using the windowless Python executable without creating a terminal window. The installer also places a standard shortcut in the Start Menu for quick browser access and audits the resulting version stamp so upgrades preserve existing settings in place. If the task fails to trigger or the web interface is unavailable after sign-in, the installer can be re-run safely to recreate the task definition and verify loopback reachability. Autostart setup is explained in [Install](install.md) and [Panel](panel.md), and diagnostic steps are documented in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).

### 24. What should I do if the Drive mount does not autostart after a system reboot?

If the Drive mount does not autostart after a system reboot, you should verify whether the underlying service wrapper is running and check whether the media folder path has become browsable before starting downstream services. When the service is stopped or missing, you start the mount service or invoke the fallback mount script directly, allow up to thirty seconds for the virtual file system to initialize, and confirm that the directory is readable. Starting Jellyfin while the mount is still down must be avoided because Jellyfin would index empty folders or generate broken stream stubs. The reboot checklist and mount requirements are covered in [Supervisor](supervisor.md) and [Install](install.md), and symptom-to-fix instructions are in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).

### 25. How do I detect if Google Drive library sync has become stale or failed?

You can detect if Google Drive library sync has become stale or failed by inspecting the panel timeline for sync error counts over the last twenty-four hours, checking the sync state JSON file for recent completion timestamps, and examining the sync heartbeat log for consecutive failures. If the sync has stalled or error counts exceed warning thresholds, re-running a self-test or validation pass confirms whether cloud remote credentials and path mappings remain healthy without writing destructive changes. The Drive sync state file and log rotation paths are documented in [Architecture](architecture.md) and [Panel](panel.md), while error diagnosis and state recovery are detailed in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).

### 26. Why do `.strm` files sometimes turn into tiny ninety-three byte stubs and how is that fixed?

Files turn into tiny stub streams when a library scan runs while the underlying VFS mount is offline or returning empty directory responses, causing the scanner to write placeholder text instead of indexing full media targets. To fix this condition, you first ensure that both the TorBox and Drive mounts are healthy and browsable, trigger a control-port VFS refresh to clear cached empty listings, remove the invalid stub stream files, and then run a library sync followed by a forced library refresh. Preserving the mount-first startup order prevents this failure from recurring on future reboots. The library structure is covered in [Jellyfin](jellyfin.md), mount-first ordering is in [Supervisor](supervisor.md), and full cleanup steps are in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).

### 27. What causes port conflicts on the TorBox proxy port and how does the stack resolve them?

Port conflicts on the TorBox proxy port occur when previous background Python processes survive an unclean termination or when an overlapping manual launch attempts to bind the same loopback port simultaneously. The supervisor and control panel resolve this by scanning for the active listener process ID, retaining the single process that holds the listening socket, and terminating non-listening zombie duplicates while logging diagnostic forensics. A post-start listener guard then waits for the surviving process to settle and re-verifies health before proceeding with downstream dependents. Port deduplication rules are detailed in [Supervisor](supervisor.md) and [Architecture](architecture.md), and listener conflict resolution is in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).

### 28. How does the supervisor prevent port conflicts on the PotPlayer bridge port?

The supervisor prevents port conflicts on the PotPlayer bridge port by enforcing strict loopback binding, deferring bridge startup whenever the TorBox proxy is unhealthy, and identifying the genuine listener process before stopping stale helper duplicates. Because the bridge requires proxy availability to process media resolution requests, the watchdog will not spawn repeated bridge instances when the upstream proxy is down, avoiding orphan processes that hold resources without answering health probes. If multiple bridge processes are detected, deduplication keeps the listening process and clears non-listening siblings. The bridge health dependency is explained in [Supervisor](supervisor.md) and [PotPlayer](potplayer.md), with operational recovery steps in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).

### 29. What happens if the control panel port is already bound by another application?

If the control panel port is already bound by another application, the panel installer and startup checks report that the port is busy and prevent duplicate conflicting background listeners from starting. To resolve the conflict, you identify the process holding the port using system process inspection, terminate the conflicting application or reconfigure the panel to use an alternate port parameter, and re-verify the panel health endpoint. Re-running the panel installer upgrades the scheduled logon task cleanly without creating duplicate tasks. Reinstallation procedures are described in [Panel](panel.md) and [Install](install.md), and conflict remediation is in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).

### 30. How do I safely stop and restart the entire stack when recovering from multiple service failures?

To safely stop and restart the entire stack when recovering from multiple service failures, you stop services in reverse dependency order (panel, Jellyfin, bridge, proxy, and mounts last) so active streams do not lose file-system access mid-shutdown, verify that all listener ports have cleared, and then restart in forward dependency order starting with mounts. Once the Drive and TorBox mount paths are confirmed browsable, you start the proxy and bridge with their respective health waits, start Jellyfin and allow its warming scan to proceed, and start the control panel last before running status verification scripts. The full reverse-stop and forward-start sequence is documented in [Supervisor](supervisor.md) and [Install](install.md), with emergency recovery checklists in [Troubleshooting](troubleshooting.md) and [RUNBOOK.md](../RUNBOOK.md).
