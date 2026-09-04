# Archive Rescue — `archive/old-main-2026-08-21`

Rescued 3 stdlib-only tools from the old tree into `tools/rescued/` for the PUBLIC MIT repo.
Read-only survey via `git show archive/old-main-2026-08-21:<path>` — no branch checkouts.
Write scope strictly `tools/rescued/` + this index. Total new files: **4** (≤ 8 cap).

## Index

- [Survey — Top-10 by rescue value](#survey--top-10-by-rescue-value)
- [Port #1 — discord_notifier](#port-1--toolsrescueddiscord_notifierpy-winner-1)
- [Port #2 — media_quality_analyzer](#port-2--toolsrescuedmedia_quality_analyzerpy-winner-2)
- [Port #3 — rclone_cache_inspector](#port-3--toolsrescuedrclone_cache_inspectorpy-winner-3)
- [Drop list — worst 5](#drop-list--worst-5-old-files)
- [Intentionally left behind](#intentionally-left-behind)
- [Guardrails checklist](#guardrails-checklist)
- [Final verdict — rescue ROI](#final-verdict--rescue-roi)

Live tree context: no `tools/` or `docs/` dir; live owns `supervisor.ps1` (1020-line watchdog),
`check_status.ps1` (Nagios-style Jellyfin probe), `control-panel/` (stdlib web panel `:18080`),
`server/torbox-proxy.py`, `gdrive-library-sync.ps1`, `mcp-servers/rclone-storage/server.py`.
Ports were picked to fill gaps with zero overlap.

## Survey — Top-10 by rescue value

| Rank | Old path | Size | One-line verdict |
|---|---|---|---|
| 1 | `tools/discord_notifier.py` | 46,140 B, 984 lines | **Winner #1 — only alerting path** (ingest/VFS/Jellyfin/DB/custom embeds, stdlib urllib, env secrets, `--dry-run`); no live equivalent. |
| 2 | `tools/media_quality_analyzer.py` | 32,171 B, 775 lines | **Winner #2 — ffprobe HDR/audio/subtitle S/A/B/C/D scorer** (HEVC/DV/Atmos/PGS lint); stdlib, zero secrets, fills curation gap. |
| 3 | `tools/rclone_cache_inspector.py` | 24,042 B, 637 lines | **Winner #3 — NTFS sparse + WinFsp lock + safe LRU purge**; stdlib ctypes, safety-critical, no live equivalent. |
| 4 | `tools/sub_sync_organizer.py` | 26,050 B | Strong #4 — Jellyfin `.eng.default.srt` normalizer + ffprobe extract + OpenSubtitles via env; deferred (ffmpeg + API friction, file-cap). |
| 5 | `tools/media_ingest_processor.py` | 24,493 B | Release parser (S01E01/Remux/HEVC/DV) + TMDB via env + `rclone moveto` dry-run; deferred (overlaps live `gdrive-library-sync.ps1`). |
| 6 | `scripts/export-metrics.ps1` | 42,027 B | Prometheus exporter (VFS/Jellyfin/GPU/PotPlayer `:9100`); deferred (large, overlaps panel `/metrics`, needs `SupportsShouldProcess` rework). |
| 7 | `scripts/backup-and-vacuum-db.ps1` | 14,368 B | `VACUUM INTO` zero-downtime + 7-day rotation + rclone sync; honorable mention, deferred for file-cap. |
| 8 | `scripts/healthcheck.ps1` | 6,071 B | Compact 4-point check (Jellyfin/mount/GPU/protocol); low marginal gain — superseded by live `check_status.ps1` + `supervisor.ps1`. |
| 9 | `tools/benchmark_stack.py` | 32,039 B | NVMe seek + rclone TTFB + NVENC FPS suite (stdlib); niche — hardware-specific synthetic, low PUBLIC reuse. |
| 10 | `sdk/jellyfin_sdk.py` | 23,941 B | Typed Jellyfin 10.11 SDK (async+sync); **not portable as-is** — requires `httpx` + `pydantic` (fails stdlib rule), overlaps live direct REST. |

Method: ranked by (live-gap × PUBLIC reuse × stdlib-clean × secrets-safe × verification-cost).
All secrets already env-based (`DISCORD_WEBHOOK_URL`, `TMDB_API_KEY`, `OPENSUBTITLES_API_KEY`, `JELLYFIN_API_KEY`); no hardcoded keys found in winners.

## Port #1 — `tools/rescued/discord_notifier.py` (Winner #1)

- **Origin:** `archive/old-main-2026-08-21:tools/discord_notifier.py`
- **What changed:** header added; branding `Nexus Media …` → `Jellyfin Stack …` (bot name, footers, server-name defaults, User-Agent); `--cache-dir`/`--log-path` now prefer `$env:RCLONE_CACHE_DIR` / `$env:DB_BACKUP_LOG` (old example paths kept as fallback); `--dry-run` also accepts `--DryRun`/`--WhatIf`; dry-run print falls back to `ensure_ascii=True` + stdout UTF-8 reconfigure for Windows cp1252 consoles; no new deps.
- **Secrets:** none hardcoded. `DISCORD_WEBHOOK_URL` (required to POST), `TMDB_API_KEY` (optional poster enrichment) via env/flags only.
- **Writes + safe preview:** send-only. Without webhook **or** with `--dry-run`/`--DryRun`/`--WhatIf` it prints JSON payload and exits 0, never POSTs.
- **Verified:** `python -m py_compile` exit 0; stdlib-only (`argparse/datetime/json/logging/os/platform/re/shutil/socket/subprocess/sys/time/urllib/dataclasses/pathlib/typing`); secret scan 0 hits.
- **Stdlib:** yes, no pip packages. Optional external: network to Discord/TMDB, `ffprobe` for `--file` auto-probe (graceful fallback).

Usage:

```powershell
# Safe preview (no webhook needed) — custom embed
python tools/rescued/discord_notifier.py --dry-run custom --title Hello --desc World

# Media ingest (TMDB enrichment optional; ffprobe auto-probe optional)
python tools/rescued/discord_notifier.py --WhatIf media-ingest --title Inception --type movie --year 2010
$env:DISCORD_WEBHOOK_URL = "https://discord.com/api/webhooks/<id>/<token>"
$env:TMDB_API_KEY = "<tmdb-v3-key>"
python tools/rescued/discord_notifier.py media-ingest --title Severance --type tv --year 2022 -s 2 -e 1 --source WEB-DL --video-codec HEVC --audio-codec Atmos

# VFS / Jellyfin / DB (all support --dry-run first)
python tools/rescued/discord_notifier.py --dry-run vfs-cache --auto-probe
python tools/rescued/discord_notifier.py --dry-run jellyfin-service --event heartbeat --auto-probe
python tools/rescued/discord_notifier.py --dry-run db-backup --integrity PASS
```

## Port #2 — `tools/rescued/media_quality_analyzer.py` (Winner #2)

- **Origin:** `archive/old-main-2026-08-21:tools/media_quality_analyzer.py`
- **What changed:** header added; `--ffprobe-path` defaults to `$env:FFPROBE_PATH`; added `--DryRun`/`--dry-run`/`--WhatIf` (lists files that WOULD be analyzed, invokes no ffprobe, writes nothing) + `--out-file <path>` (JSON report; with DryRun only previews); stdout UTF-8 guard for Windows; no new deps.
- **Secrets:** none (no keys/tokens/webhooks in source).
- **Writes + safe preview:** read-only by default (stdout only). Only `--out-file` writes; `--DryRun --out-file X` prints `Would write …` and writes nothing.
- **Verified:** `python -m py_compile` exit 0; stdlib-only (`argparse/json/logging/os/shutil/subprocess/sys/dataclasses/pathlib/typing`); secret scan 0 hits.
- **Stdlib:** yes. Requires `ffprobe` binary on PATH (or `FFPROBE_PATH`) at analyze time; DryRun needs no binary.

Usage:

```powershell
# Preview without touching ffprobe
python tools/rescued/media_quality_analyzer.py --DryRun ./Media --recursive
python tools/rescued/media_quality_analyzer.py --DryRun ./movie.mkv --out-file report.json

# Analyze (human report) / JSON / tier gate / file output
python tools/rescued/media_quality_analyzer.py ./movie.mkv
python tools/rescued/media_quality_analyzer.py --json -r ./Media > report.json
python tools/rescued/media_quality_analyzer.py --min-tier B ./movie.mkv; echo $LASTEXITCODE
python tools/rescued/media_quality_analyzer.py -r ./Media --out-file report.json
```

Scoring: Video 40 + Audio 30 + HDR 20 + Container 10 − penalties → S (90+), A (80+), B (65+), C (50+), D (<50).
Flags e.g. `8BIT_HDR_BANDING_RISK`, `INEFFICIENT_4K_CODEC_H264`, `IMAGE_SUBTITLES_ONLY_PGS_VOBSUB`, `DV_PROFILE_5_FALLBACK_RISK`, `STARVED_4K_BITRATE`.

## Port #3 — `tools/rescued/rclone_cache_inspector.py` (Winner #3)

- **Origin:** `archive/old-main-2026-08-21:tools/rclone_cache_inspector.py`
- **What changed:** header added; `--cache-dir` defaults to `$env:RCLONE_CACHE_DIR` (fallback old example `F:\rclone-cache\gdrive-media`); added `--DryRun`/`--dry-run`/`--WhatIf` preview for **all** purge paths (prints WOULD-PURGE/SKIP-DIRTY/SKIP-LOCKED + freed bytes, deletes nothing even with `--force`); purge guards unchanged (skip dirty + locked unless `--force`); stdout UTF-8 guard; no new deps.
- **Secrets:** none.
- **Writes + safe preview:** `scan/tree/lru/check-locks` read-only. Only `--purge-item/--purge-all` delete; always rehearse with `--DryRun` first.
- **Verified:** `python -m py_compile` exit 0; stdlib-only (`os/sys/json/time/ctypes/argparse/datetime/pathlib/typing`); secret scan 0 hits.
- **Stdlib:** yes. Windows sparse (`GetCompressedFileSizeW`) + exclusive-open lock check; Unix fallback via `open(r+b)`.

Usage:

```powershell
# Read-only first
python tools/rescued/rclone_cache_inspector.py --cache-dir $env:RCLONE_CACHE_DIR --tree
python tools/rescued/rclone_cache_inspector.py --lru 20
python tools/rescued/rclone_cache_inspector.py --check-locks

# Safe purge rehearsal (ALWAYS run before real purge)
python tools/rescued/rclone_cache_inspector.py --DryRun --purge-item "MovieName" --json
python tools/rescued/rclone_cache_inspector.py --DryRun --purge-all --older-than-days 30

# Real purge (deletes unlocked, non-dirty only unless --force)
python tools/rescued/rclone_cache_inspector.py --purge-item "MovieName"
python tools/rescued/rclone_cache_inspector.py --purge-all --older-than-days 30
```

## Drop list — worst 5 old files

| Old path | Reason |
|---|---|
| `tests/__pycache__/*.pyc` (5 blobs) | **Binary** — compiled caches, regenerable, must never be committed. |
| `mcp-servers/rclone-storage/server.py` | **Duplicated** — live tree already tracks the same helper; rescuing would fork it. |
| `scripts/NexusMediaMasterControl.ahk` | **Superseded** — live `supervisor.ps1` watchdog owns ordering/health/backoff; AHK needs v2 runtime and fails `ParseFile/py_compile` verification. |
| `deployments/docker-compose.yml` | **Superseded** — live stack is Windows-native (NSSM/schtasks, `F:\`/`T:\` mounts); containers add Linux/GPU-passthrough complexity for PUBLIC. |
| `web/netflix-theme.css` | **Superseded** — live `control-panel/app.css` owns UI; orphan CSS without its JS bridge has near-zero standalone value. |

Also intentionally not rescued: `deployments/Caddyfile` (same container reason), `tools/benchmark_summary.json` (generated artifact, not source).

## Intentionally left behind

File-cap (≤ 8) forced triage after the top-3. Left for follow-ups, not for lack of quality:

- `tools/sub_sync_organizer.py` + `docs/SUBTITLE_AND_METADATA_PIPELINE.md` — best follow-up candidate (needs ffmpeg + `OPENSUBTITLES_API_KEY`/`JELLYFIN_API_KEY` docs).
- `tools/media_ingest_processor.py` + `docs/TELEGRAM_MEDIA_PIPELINE.md` — overlaps live sync; rescue only with dedupe plan.
- `scripts/export-metrics.ps1` + `docs/OBSERVABILITY_TELEMETRY.md` — needs `SupportsShouldProcess` + secret-via-env rework.
- `scripts/backup-and-vacuum-db.ps1`, `scripts/healthcheck.ps1`, `scripts/potplayer-*.ps1`, `scripts/install-rclone-service.ps1` — live already covers most; backup is next-best PS rescue.
- `sdk/jellyfin_sdk.py` + `docs/JELLYFIN_API_SDK.md` — blocked by `httpx`/`pydantic` (stdlib rule); needs stdlib rewrite (`urllib`) to qualify.
- `scripts/NexusMediaMasterControl.ahk` + `docs/DESKTOP_AHK_AUTOMATION.md` — AHK runtime, superseded by supervisor.
- `tools/benchmark_stack.py` + `docs/BENCHMARK_AND_PERFORMANCE.md`, `docs/*` (19 files), `web/*`, `deployments/*`, `config/*.template`, `mcp-servers/*`, `tests/*` — docs/configs superseded or niche; web needs DOM harness to verify; tests reference unrescued modules.

## Guardrails checklist

- [x] Writes only under `tools/rescued/` + `docs/rescued.md` (4 files total, ≤ 8).
- [x] No `.pyc`/binaries committed; `.gitignore` covers `__pycache__/`.
- [x] No hardcoded secrets/keys/tokens (env-only: `DISCORD_WEBHOOK_URL`, `TMDB_API_KEY`, `RCLONE_CACHE_DIR`, `FFPROBE_PATH`, `DB_BACKUP_LOG`).
- [x] Stdlib-only ports (verified via `sys.stdlib_module_names`; no `httpx`/`pydantic`).
- [x] Headers with origin + changes on all 3 ports.
- [x] `--DryRun`/`--dry-run`/`--WhatIf` preview on every write path; read-only by default.
- [x] Verified: `py_compile` 0 for all 3; `--help` + live DryRun exercised (see commit message).
- [x] Cross-linked index (top of this file) to all rescued docs/sections.

## Final verdict — rescue ROI

High ROI on 3 files, deliberate restraint on the rest: the old tree's unique value was not the Windows service plumbing (live `supervisor.ps1` + `control-panel` already supersede it) but the portable, stdlib-only media intelligence — Discord alerting, ffprobe quality scoring, and sparse-cache safety — none of which exist live. Those three port with near-zero dependency cost, env-only secrets, and DryRun-guarded writes, so they are safe to publish in a PUBLIC MIT repo and immediately useful to any Jellyfin operator. Everything else was correctly left: either duplicated live, superseded by the Windows-native design, blocked by non-stdlib deps, or too niche/hardware-specific to justify spending the 8-file budget. Rescue 3, document 10, drop 5 — the right trade.
