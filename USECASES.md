# Use cases

Five people this stack was built for. Each one plays only files they own or
have the right to play, and uses the stack to keep playback smooth.

## 1. The 4K remux fan

Loves full-quality movies with lossless audio and hates forced transcoding.

- Goals: direct-play large files, instant seeking, no stutter on high bitrates.
- How this helps: external-player queue with resume, stable local stream URLs,
  Range seeking, and retry logic that hides brief provider hiccups.
- Tips: use the health checks before movie night, keep the cache budget
  generous, and wire one click from the panel to the player.

## 2. The anime watcher

Follows seasonal shows with absolute ordering, specials, and subtitles.

- Goals: correct episode order, fast Next-Up, reliable subtitles.
- How this helps: metadata matching for seasons and specials, full-season
  queues, frequent progress sync, and a subtitle pipeline with docs.
- Tips: name specials clearly, verify order after each sync, and keep a
  small test library for new subtitle styles.

## 3. The family server

Runs one quiet box that everyone can use without calling for help.

- Goals: simple start and stop, green means go, kids keep their own progress.
- How this helps: local panel with clear service status, watchdog that keeps
  the right start order, and per-user resume and watched state.
- Tips: pin the panel to the taskbar, teach one restart flow, and schedule
  backups so a reboot is never scary.

## 4. The debrid migrant

Moves from hosted debrid apps to a self-hosted library they control.

- Goals: familiar instant links, but with their own catalog and history.
- How this helps: cloud mounts plus stream-file sync, shared-list cache for
  fast repeat plays, and a proxy that keeps links fresh without manual work.
- Tips: migrate one collection at a time, compare old and new resume states,
  and keep the old setup until the new Next-Up feels right.

## 5. The tinkerer

Enjoys logs, metrics, scripts, and automating the boring parts.

- Goals: observable services, scriptable maintenance, room to extend.
- How this helps: Prometheus metrics, JSON health output, an automation
  bridge with strict validation, a client SDK, and assert-based smoke tests.
- Tips: start with dry-run flags, bundle a health report with every bug
  report, and prototype new panel actions as small scripts first.
