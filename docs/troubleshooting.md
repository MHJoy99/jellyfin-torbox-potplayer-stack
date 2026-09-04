# Troubleshooting Ten Common Problems

This guide maps ten frequent failures from symptoms to fixes, with the fastest check first in every section.

## Contents

- [How to use this guide](#how-to-use-this-guide)
- [1. Stale VFS mount shows empty or tiny streams](#1-stale-vfs-mount-shows-empty-or-tiny-streams)
- [2. TorBox calls fail with auth errors](#2-torbox-calls-fail-with-auth-errors)
- [3. Proxy hangs or never answers](#3-proxy-hangs-or-never-answers)
- [4. Duplicate proxy or bridge listeners](#4-duplicate-proxy-or-bridge-listeners)
- [5. Jellyfin views are empty after reboot](#5-jellyfin-views-are-empty-after-reboot)
- [6. Clicking Play in PotPlayer does nothing](#6-clicking-play-in-potplayer-does-nothing)
- [7. Resume never advances or always restarts](#7-resume-never-advances-or-always-restarts)
- [8. Mounts are missing after reboot](#8-mounts-are-missing-after-reboot)
- [9. TorBox rate limits and slow mylist](#9-torbox-rate-limits-and-slow-mylist)
- [10. Panel port is already in use](#10-panel-port-is-already-in-use)

## How to use this guide

Start with Status mode plus the three health URLs from [Quickstart](quickstart.md), then jump to the matching section below. Collect the forensics bundle from [Supervisor](supervisor.md) before restarting a crash loop, and check the [FAQ](faq.md) when you only need a short answer.

## 1. Stale VFS mount shows empty or tiny streams

Symptoms: listings look present but files report only a few dozen bytes, `.strm` playback fails instantly, and Jellyfin scans add stubs without posters. Fix: confirm both mounts are browsable and the mount processes exist, trigger an rclone RC directory refresh for the stale path, wait for the dir cache to expire, then trigger `POST /Library/Refresh` and rescan. Start mounts before Jellyfin in the order from [Supervisor](supervisor.md) so the next reboot does not repeat the pattern.

## 2. TorBox calls fail with auth errors

Symptoms: proxy logs show auth failures, `mylist` never refreshes, and launcher falls back without CDN links. Fix: confirm `TORBOX_API_KEY` is set at Machine or User scope in a fresh shell, confirm the supervisor re-read the live value on start, confirm the proxy builds query auth rather than header-only auth which returns HTTP 422, then restart proxy and supervisor and retest health plus `mylist`. Rotate a suspected key with the order in [TorBox](torbox.md).

## 3. Proxy hangs or never answers

Symptoms: health probes time out, panel metrics stall, and playback waits forever. Fix: confirm the proxy process owns the proxy listener PID without duplicates, confirm clients use HTTP version 1.0 against the proxy, check token-bucket and cooldown counters on the metrics endpoint, and restart only the proxy before touching downstream services. The proxy design and counters are in [Architecture](architecture.md).

## 4. Duplicate proxy or bridge listeners

Symptoms: two matching processes exist for one port, health flaps between OK and down, and restarts spawn ever more owners. Fix: run Status mode to find the listening PID, keep that PID, stop the non-listening duplicates, and let the watchdog listener guard settle before any manual start. Use panel Start all or supervisor Start rather than launching the Python scripts by hand. Dedupe details are in [Supervisor](supervisor.md).

## 5. Jellyfin views are empty after reboot

Symptoms: status auth passes but user views are empty immediately after a restart. Fix: wait sixty seconds for the warming scan, re-run the post-restart views probe, trigger a library refresh when the code reports warming, and inspect Jellyfin logs only when the code reports investigate. Confirm mounts were healthy before Jellyfin started, as described in [Jellyfin](jellyfin.md).

## 6. Clicking Play in PotPlayer does nothing

Symptoms: the browser shows an unknown-protocol prompt or nothing happens after click. Fix: confirm both `potplayer` and `potplayer64` command values under the classes root point at the installed player, re-run the protocol installer elevated when they are missing, confirm the player path still exists after an app move, and test with a minimal `potplayer://` link before testing full Jellyfin links. Handler internals are in [PotPlayer](potplayer.md).

## 7. Resume never advances or always restarts

Symptoms: episodes always start from zero, progress bars never move, or Next Up never advances. Fix: confirm the launched link carried item ID, user ID, token, and server URL, confirm the tracker singleton is running for that item prefix, tail the playback log for five-second ticks and the eighty-percent played mark, and confirm Jellyfin auth still passes. Tracker timing is in [PotPlayer](potplayer.md) and API calls are in [Jellyfin](jellyfin.md).

## 8. Mounts are missing after reboot

Symptoms: mount paths are not browsable, VFS refresh calls fail, and every downstream gate aborts. Fix: confirm the mount service exists and is running, start it or the fallback mount script, wait up to thirty seconds for the path, then restart proxy, bridge, Jellyfin, and panel in order. Never start Jellyfin first on a missing mount, per [Supervisor](supervisor.md).

## 9. TorBox rate limits and slow mylist

Symptoms: download-link calls return rate-limit responses, `mylist` takes many seconds, and background refreshes pile up. Fix: check the metrics endpoint for bucket tokens, cooldown state, and singleflight coalescing, reduce manual `mylist` refreshes to the ten-minute shared window, and let background tokens recover before retrying bulk plays. Tuning knobs are in [Architecture](architecture.md) and key hygiene is in [TorBox](torbox.md).

## 10. Panel port is already in use

Symptoms: the panel installer warns the port is busy, or panel health returns another app. Fix: find the listener PID for the panel port, stop the conflicting app or move the panel port parameter, upgrade the existing logon task in place rather than duplicating it, and recheck panel health. Reinstall steps are in [Panel](panel.md) and full removal is in [Install](install.md).

---

Back to [Docs Index](index.md).
