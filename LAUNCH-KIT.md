# NexusMedia Jellyfin Stack — Launch Kit

How to introduce the NexusMedia Jellyfin Stack without spamming, and how fans can help it grow.

Brand rules are authoritative in `assets/BRAND.md` (Naming, Misuse rules,
no binary blobs). This kit reuses its badge snippet, Open Graph strings,
and banner verbatim — do not restyle them per venue.

## Where to announce

- r/jellyfin at https://www.reddit.com/r/jellyfin/ for Jellyfin owners who
  want direct-play and external-player workflows.
- r/selfhosted at https://www.reddit.com/r/selfhosted/ for self-hosters who
  enjoy observable local services with metrics and health checks.
- r/PotPlayer at https://www.reddit.com/r/PotPlayer/ for PotPlayer users who
  want one-click season queues with resume from a media server.
- Jellyfin forum at https://forum.jellyfin.org/ in the Guides or General
  section for long-form setup discussion.
- Self-hosted forums and chat groups you already take part in, plus GitHub
  Discussions once enabled, for follow-up questions and show-and-tell.

Post once per venue, answer questions for a week, and link back to the
release notes rather than reposting the same text everywhere.

## Tailored pitches

Each pitch uses the full **NexusMedia Jellyfin Stack** name on first
mention (per `assets/BRAND.md` Naming). Keep that first mention intact
when trimming for length.

### r/jellyfin pitch

I open-sourced the NexusMedia Jellyfin Stack, which keeps large libraries direct-played through PotPlayer with one-click season queues, resume seeking, and progress sync back to Jellyfin, plus a local proxy with Range support and a small panel for status and playback, and I would love feedback on library sync and Next-Up accuracy.

### r/selfhosted pitch

I published the NexusMedia Jellyfin Stack, a self-hosted media stack built around Jellyfin with a local proxy that hides short-lived links behind stable URLs, a watchdog that keeps services in order, JSON health checks and Prometheus metrics, preview-first maintenance scripts, and a local-only panel, all MIT licensed with a runbook for recovery.

### r/PotPlayer pitch

I built the NexusMedia Jellyfin Stack bridge, which sends a full Jellyfin season to PotPlayer as an ordered queue with resume seeking and pause-aware progress sync, so the player bar fills fully and Next-Up stays correct, and the launcher handles stale listings and fallback streams automatically.

### Jellyfin forum pitch

This NexusMedia Jellyfin Stack guide and toolkit shows a complete Jellyfin setup with cloud mounts, stream-file sync, a local proxy for stable seeking, PotPlayer queues with resume, a control panel for status and logs, and health scripts for daily checks, with architecture and runbook docs included for troubleshooting.

### General self-hosted forum pitch

If you like owning your media chain, the NexusMedia Jellyfin Stack (MIT) pairs Jellyfin with an external player, a caching proxy, and a local panel, focusing on direct-play quality, clear logs, and safe defaults, and the roadmap lists small ways to contribute even without coding.

## Star CTA copy variants

Short: If this saved you a transcode, please star the repo.

Medium: Star the repo to help others find a direct-play Jellyfin setup, and open an issue with your player and server versions when something breaks.

Long: If this stack made movie night smoother, please star the repo so others can find it, watch releases for stable tags, and share one screenshot or log bundle with your issue reports so fixes land faster for everyone.

## Contributing to growth

You do not need to code to move this project forward.

- Stars: star the repo and watch releases so stable tags reach more people.
- Issues: report bugs with steps to reproduce, expected versus actual
  behavior, and a health bundle or log excerpt with personal titles blurred.
- Ports: propose install or launcher variants for new setups, starting with
  a short design note and a dry-run friendly script.
- Docs: fix a typo, clarify a step, or add one annotated screenshot for the
  quickstart.
- Discussions: answer one newcomer question per week in your favorite venue.

Please be kind, stay on topic, and play only files you own or have the right
to play.

## Brand rules for launch assets

- Name: full **NexusMedia Jellyfin Stack** on first mention; `NexusMedia`
  wordmark is never re-typeset (scale `assets/logo.svg` as a unit).
- Banner: `assets/social-preview.svg` (1200×630, dark-first) for OG / X
  cards. Do not use it below **600 px** wide — use `assets/favicon.svg`.
  Alt: `NexusMedia Jellyfin Stack banner — title, tagline and Windows, PowerShell, MIT badges on dark background`.
- No binary blobs: never commit PNG / JPG / ICO / WOFF for launch posts.
  Screenshots follow `assets/screenshots/PLACEHOLDER.md` (attach to
  releases / issues, do not commit). Full misuse list: `assets/BRAND.md`.

## Badges block for README

Canonical block — verbatim from `assets/BRAND.md`. Do not restyle colors
or add extra badges here; brand-token colors only.

Copy and paste this block at the top of README.md:

```markdown
[![License: MIT](https://img.shields.io/badge/License-MIT-38D6C0.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows-4F8CFF.svg)](#setup)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%2B-5391FE.svg)](supervisor.ps1)
```

## Release-notes template

```markdown
## Highlights

- One line per user-visible win.

## What changed

- Added:
- Changed:
- Fixed:

## Install or upgrade

1. Download the zip for this tag.
2. Back up your config and data folders.
3. Run the ordered installer, then the health checks.
4. Play one item and confirm resume and Next-Up.

## Checksums

- `stack-vX.Y.Z.zip`: `<sha256 here>`

## Thanks

- Thanks to everyone who filed issues, tested fixes, and shared screenshots.
```

## Translation and internationalization invitation

The panel and docs are English-only today, and help is welcome to change that.
If you can translate, open an issue named `i18n: <language>` with your
language name, translate five panel strings as a sample, and note whether you
can review future updates. Docs translations can start with the quickstart
page plus one screenshot with translated captions. We will credit every
translator in the release notes.

## FAQ

### Is this legal

Yes, when used as designed: to play files you own or have the right to play
on hardware you control. This project ships no media, no keys, and no
credentials. It simply organizes your own library, catalogs it locally, and
plays it back through a player you installed. You are responsible for having
the rights to any file you add, and for following the terms of any cloud
provider you connect. If in doubt, keep it to discs you ripped yourself,
home videos, and other files you clearly own.

### Does it upload my library anywhere

No. Status checks, metrics, and playback stay on your machine unless you
choose to expose them. The proxy and panel bind to loopback by default.

### Do I need paid services

No. The stack works with local files alone. Cloud mounts are optional and
follow whatever plan you already have with your provider.

### Will it transcode my files

The goal is to avoid it. Direct-play through the external player plus Range
seeking keeps large files original quality on capable hardware.

---

Launch Kit v1.1 — 2026-09-06. Companion to `assets/BRAND.md` v1.1.
v1.1: canonical title, full-name first mentions, canonical badges verbatim from BRAND.md, brand-rules + no-binary-blobs section.
