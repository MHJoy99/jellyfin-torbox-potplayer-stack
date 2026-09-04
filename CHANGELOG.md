# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Placeholder for the next release. See ROADMAP.md for planned work.

## [1.0.0] - 2026-09-04

First public release. MIT licensed public stack tree.

### Added

- Core media chain: cloud remotes through a local cache engine into
  stream-file libraries, cataloged by Jellyfin with movie database metadata,
  played back in an external direct-play player through a local bridge.
- Local HTTP proxy with stable stream URLs, Range seeking, short-lived link
  cache, retry with backoff, per-client limits, request log sampling,
  shared-list cache endpoint, and Prometheus metrics endpoint.
- Full-season external-player launcher with resume seeking, shared-list-first
  resolution, stale-cache refresh, and proxy fallback for cloud items.
- Playback progress tracker with frequent progress posts, pause awareness,
  watched marking near the end of an item, and Next-Up advancement.
- Local-only web control panel with service status, metrics view, playback
  actions, log tailing, timeline pagination, restart allowlist, and rate
  limits on admin actions.
- Watchdog supervisor with ordered start and stop helpers for mounts, proxy,
  media server, and panel.
- Cloud library sync that writes stream files plus sidecars and triggers a
  library scan.
- Storage automation bridge over the sync engine with an allowlisted command
  surface, strict validation, and transfer status queries.
- Ordered installer orchestrator plus per-component installers for mount
  service, automation bridge, player protocol handler, registry wiring, and
  control panel, with verify and uninstall paths.
- Health and library maintenance scripts with dry-run modes, JSON output for
  monitoring, and assert-based smoke tests for playlists and the bridge.
- Screenshot annotation helper for docs and release art.
- Documentation set: overview, architecture with stack diagram and ports,
  runbook with restart order and log guide, panel guide, and field notes for
  stale-cache and mount-down recovery.
- Jellyfin REST client SDK with test suite.
- Notification bot for ingest, cache alerts, and backups via webhook.
- Media quality analyzer, cache inspector, and full test suites.
- Telemetry exporter and observability docs with Prometheus guidance.
- Subtitle synchronization pipeline and docs.
- Public launch tree with MIT license and ignored runtime folders for logs,
  cache, transcodes, data, config, and backups.

### Changed

- Consolidated the earlier enterprise layout into a single public stack tree
  while preserving the prior layout in an archive snapshot.
- Cleaned generated cache artifacts from tracked history before launch.

### Fixed

- Stale cloud-cache playback failures handled with refresh and fallback paths.
- Mount-down recovery path documented and wired into panel actions and checks.

## Versioning policy

- Versions are `MAJOR.MINOR.PATCH` following semver.
- `MAJOR` increments for breaking changes such as changed install steps,
  changed protocol links, removed scripts, or required config migration.
- `MINOR` increments for backward-compatible features such as new panel
  actions, new health checks, or new automation commands.
- `PATCH` increments for backward-compatible fixes such as proxy retry
  tuning, launcher edge cases, or docs corrections.
- Each release tags `vMAJOR.MINOR.PATCH`, updates the VERSION file, adds a
  CHANGELOG entry, and ships a zip artifact of tracked files built by
  `release.ps1`.
- Pre-releases use `X.Y.Z-rc.N` tags and are not pushed as stable.

## Deprecation policy

- A feature slated for removal is marked deprecated in CHANGELOG and docs
  for at least one minor release before removal.
- Deprecated scripts keep working and print a warning pointing to the
  replacement and the target removal version.
- Breaking removals only land in a MAJOR release, except for security fixes
  which may land sooner with a clear CHANGELOG callout.
- Renames ship a compatibility shim for one minor release cycle where
  practical (for example a thin wrapper that forwards flags).

[Unreleased]: https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack/releases/tag/v1.0.0
