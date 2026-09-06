# Roadmap

Where this stack is heading. Items are checked off as they land in CHANGELOG.md.

Current state: `VERSION` is `1.0.0` with no new tag cut. Work since
v1.0.0 lives under `[Unreleased]` in CHANGELOG.md (one-click installer,
setup wizard, 12-file docs site, CI pipeline, 9-suite test harness,
rescued curation tools, mount guard). Nothing below invents a release;
v1.1 / v1.2 / v2.0 are future planning milestones.

## Landed in Unreleased (ready for next release tag)

- [x] One-click installer `install.ps1` with 20 behaviors (PowerShell 5.1 & 7 stdlib).
- [x] Interactive first-run setup wizard `setup-wizard.ps1` with resume and headless modes.
- [x] 12-file complete documentation site under `docs/`.
- [x] Automated Windows CI and secret scanning workflows.
- [x] 9-suite regression test harness (`tests/run-tests.ps1`).
- [x] Rescued curation tools: Discord notifier, media quality analyzer, cache inspector (`tools/rescued/`).
- [x] Idempotent TorBox mount guard in `mount-torbox.ps1` preventing supervisor kill-loops.
- [x] Release automation toolkit (`release.ps1` + `LAUNCH-KIT.md`).

## Now (v1.1)

- [ ] Control panel playback timeline export (CSV) for personal watch history.
- [ ] One-command health bundle that collects service status and recent logs.
- [ ] Launcher resume accuracy pass with edge-case tests for multi-episode queues.
- [ ] Quickstart polish: shorter setup steps plus annotated screenshots.

## Next (v1.2)

- [ ] Multi-user play-state isolation so two viewers keep separate resume points.
- [ ] Proxy cache-hit dashboard tiles inside the control panel metrics view.
- [ ] Scheduled backup and database vacuum with retention settings.
- [ ] Cross-platform launcher research for portable playback outside Windows.
- [ ] Stdlib subtitle normalizer and organizer (`tools/sub_sync_organizer.py` port).
- [ ] Stdlib metrics exporter (`scripts/export-metrics.ps1` port).

## Later (v2.0 and beyond)

- [ ] One-click GUI installer with preflight checks and clean uninstall.
- [ ] Offline-first metadata cache for faster library browsing during outages.
- [ ] Read-only mobile companion view for status and Next-Up.
- [ ] Community translation workflow for panel and docs (see LAUNCH-KIT.md).
- [ ] Stdlib Jellyfin API SDK (`sdk/jellyfin_sdk.py` stdlib rewrite).

## Screenshot requests for v1.1

Help wanted: clean screenshots make releases land. Please capture at 1920x1080
with personal titles blurred.

- Control panel home with all services green.
- Media server library view with posters and Next-Up row.
- External player open with full-season playlist queue visible.
- Health check run showing passing output in a terminal.
- Fresh install flow from first run to first playback.
- Tracker log showing progress ticks and watched marking.

If you can help, open an issue with the screenshot attached and note your
player and server versions so we can credit you in the release notes.
