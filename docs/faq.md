# Frequently Asked Questions

This FAQ answers the ten most common questions in full sentences so each answer stands alone in search results.

## Contents

- [General](#general)
- [Questions and answers](#questions-and-answers)

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
