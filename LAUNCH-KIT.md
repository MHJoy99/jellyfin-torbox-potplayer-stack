# Launch kit

How to introduce this stack without spamming, and how fans can help it grow.

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

### r/jellyfin pitch

I open-sourced a Jellyfin stack that keeps large libraries direct-played through PotPlayer with one-click season queues, resume seeking, and progress sync back to Jellyfin, plus a local proxy with Range support and a small panel for status and playback, and I would love feedback on library sync and Next-Up accuracy.

### r/selfhosted pitch

I published a self-hosted media stack built around Jellyfin with a local proxy that hides short-lived links behind stable URLs, a watchdog that keeps services in order, JSON health checks and Prometheus metrics, preview-first maintenance scripts, and a local-only panel, all MIT licensed with a runbook for recovery.

### r/PotPlayer pitch

I built an open bridge that sends a full Jellyfin season to PotPlayer as an ordered queue with resume seeking and pause-aware progress sync, so the player bar fills fully and Next-Up stays correct, and the launcher handles stale listings and fallback streams automatically.

### Jellyfin forum pitch

This guide and toolkit shows a complete Jellyfin setup with cloud mounts, stream-file sync, a local proxy for stable seeking, PotPlayer queues with resume, a control panel for status and logs, and health scripts for daily checks, with architecture and runbook docs included for troubleshooting.

### General self-hosted forum pitch

If you like owning your media chain, this MIT stack pairs Jellyfin with an external player, a caching proxy, and a local panel, focusing on direct-play quality, clear logs, and safe defaults, and the roadmap lists small ways to contribute even without coding.

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

## Badges block for README

Copy and paste this block at the top of README.md:

```markdown
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/MHJoy99/jellyfin-torbox-potplayer-stack.svg)](https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack/releases)
[![Platform](https://img.shields.io/badge/platform-Windows-blue.svg)](https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack)
[![PowerShell](https://img.shields.io/badge/powershell-7-blue.svg)](https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack)
[![Python](https://img.shields.io/badge/python-3.10+-yellow.svg)](https://github.com/MHJoy99/jellyfin-torbox-potplayer-stack)
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
