# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Current development since v1.0.0. `VERSION` remains `1.0.0`; no new tag
has been cut. See ROADMAP.md for what is still planned.

### Added

- One-click installer `install.ps1` (20 behaviors, stdlib PowerShell 5.1
  and 7, dry-run, uninstall, rollback, install receipt, secrets stay in
  environment only).
- Interactive first-run wizard `setup-wizard.ps1` (20 steps, masked key
  entry, library roots editor, Jellyfin/potplayer/rclone checks, port
  probes, dry-run summary, resume and non-interactive modes, secrets
  never written to disk).
- 12-file public docs site under `docs/` (index, quickstart, install
  lifecycle, torbox, jellyfin, potplayer, panel, supervisor, faq,
  troubleshooting, architecture+perf, reference) plus `docs/rescued.md`
  index for ported tools.
- Repo health files: `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
  `SECURITY.md`, `SUPPORT.md`, issue and PR templates, `.editorconfig`,
  `.gitattributes`.
- Brand assets under `assets/` (logo, dark variant, favicon, social
  preview, snippets, `BRAND.md`).
- Windows CI (`.github/workflows/ci.yml`) and weekly secret scan
  (`.github/workflows/secret-scan.yml`).
- Test harness under `tests/` with 9 suites (`run-tests.ps1` plus ps1
  parse, py compile, js syntax, no-secrets, no-absolute-paths, panel
  contracts, proxy contracts, gdrive modes, tracker dry-run) and
  `tests/README.md`.
- Ported curation tools under `tools/rescued/` (`discord_notifier.py`,
  `media_quality_analyzer.py`, `rclone_cache_inspector.py`) documented
  in `docs/rescued.md`.
- Mount reliability: `mount-torbox.ps1` idempotent guard that never kills
  a healthy live mount serving `T:\` (fixes supervisor kill-loop and
  `T:\` flapping).
- Release toolkit: `release.ps1` automation script and `LAUNCH-KIT.md` guide.

### Changed

- Star-worthy SEO/AEO rewrite of `README.md` for direct-play discovery.
- Control panel reliability: static `activity-filters` markup and
  `fetch-status-pill` in `control-panel/index.html`, guarded once-only
  wiring in `control-panel/app.js`.
- CI maintenance: choco-installed gitleaks (upstream action has no
  Windows asset), `No-Secrets` placeholder allowlist, README placeholder
  reword.

### Fixed

- Mount guard evaluation order: the healthy-mount check now runs before
  any stop or restart path (`834532d`).
- Supervisor kill-loop where every retry killed a healthy mount while the
  cold mount never finished WinFsp init inside the wait window (`17eb071`).
- Panel timeline filter double-binding when the filter UI already exists
  as static markup (`ddc37d2`).
- CI false positives on placeholder tokens and docs examples (`d96ca56`).

## [1.0.0] - 2026-09-04

First public release. MIT licensed public stack tree.

### Added

- Core media chain: cloud remotes through a local cache engine into
  stream-file libraries, cataloged by Jellyfin with movie database metadata,
  played back in an external direct-play player through a local bridge.
- Local HTTP proxy (`server/torbox-proxy.py`) with stable stream URLs, Range seeking,
  short-lived link cache, retry with backoff, per-client limits, request log sampling,
  shared-list cache endpoint, and Prometheus metrics endpoint.
- Full-season external-player launcher (`potplayer-launcher.ps1`, `PotPlayerLauncher.ps1`)
  with resume seeking, shared-list-first resolution, stale-cache refresh, and proxy fallback
  for cloud items.
- Playback progress tracker (`potplayer-sync-tracker.ps1`) with frequent progress posts,
  pause awareness, watched marking near the end of an item, and Next-Up advancement.
- Local-only web control panel (`control-panel/`) with service status, metrics view,
  playback actions, log tailing, timeline pagination, restart allowlist, and rate
  limits on admin actions.
- Watchdog supervisor (`supervisor.ps1`) with ordered start and stop helpers for mounts,
  proxy, media server, and panel, plus forensics bundles.
- Cloud library sync (`gdrive-library-sync.ps1`) that writes stream files plus sidecars
  and triggers a library scan.
- Storage automation bridge (`mcp-servers/rclone-storage/server.py`) over the sync engine
  with an allowlisted command surface, strict validation, and transfer status queries.
- Component installers (`install-all.ps1`, `install-control-panel.ps1`, `install-rclone-service.ps1`,
  `register-potplayer-protocol.ps1`, `lock_registry.ps1`, `update_registry.ps1`).
- Health and library maintenance scripts (`check_status.ps1`, `check_user_views.ps1`,
  `check_views_after_restart.ps1`, `clean_and_setup_libraries.ps1`, `cleanup_and_check_items.ps1`,
  `cleanup_extra_libraries.ps1`, `delete_stale_views.ps1`) with dry-run modes.
- Smoke tests for playlists and the automation bridge (`test_dpl.ps1`, `test_mcp_server.ps1`).
- Screenshot annotation helper `annotate_screenshot.ps1` for docs and release art.
- Core documentation set: overview (`README.md`), architecture (`ARCHITECTURE.md`),
  runbook with restart order and log guide (`RUNBOOK.md`), panel guide (`CONTROL_PANEL.md`),
  and field notes for stale-cache and mount-down recovery.
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
