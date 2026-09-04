# Features

Why this stack exists: keep your own media library fast, direct-played, and
observable, without re-encoding everything on a home server.

## Direct-play playback

- Full-season queue that opens every episode in order with one click.
- Resume seeking that picks up where you left off across restarts.
- Pause-aware progress sync that keeps Next-Up accurate.
- Playlist files in the native player format with correct text encoding.
- One-click protocol links from the browser or panel into the player.

## Cloud and library

- Stream-file libraries that keep the catalog light and fast to scan.
- Automatic metadata matching with posters, seasons, and episode order.
- Cloud library sync that writes stream files plus sidecars and rescans.
- Stale-cache recovery that refreshes listings instead of failing playback.
- Library cleanup tools with preview mode and age filters.

## Local proxy and streaming

- Stable local stream URLs that hide short-lived provider links.
- True seeking with Range requests so the progress bar fills fully.
- Retry with backoff that rides out transient rate limits.
- Shared-list cache that cuts repeated lookups to seconds.
- Prometheus metrics endpoint for traffic, cache age, and errors.

## Control, supervision, and setup

- Local-only web panel for status, metrics, playback, and logs.
- Watchdog supervisor that owns services in the right start order.
- Ordered installer that stops on first failure and supports uninstall.
- Safe registry wiring with locked final handler state.
- Preview-first maintenance scripts that never delete without asking.

## Automation and observability

- Storage automation bridge with an allowlisted, validated command surface.
- Nagios-style health checks with JSON output for monitoring.
- Assert-based smoke tests for playlists and the automation bridge.
- Webhook notifications for ingest events, cache alerts, and backups.
- Client SDK, quality analyzer, cache inspector, and telemetry exporter.
