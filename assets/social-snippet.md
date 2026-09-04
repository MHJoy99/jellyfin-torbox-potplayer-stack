# Social / repo-header snippets (copy-paste)

## GitHub About description (Settings → General → About → Description)

```text
High-performance local Jellyfin stack: TorBox → rclone VFS → .strm libraries → Jellyfin + TMDB → PotPlayer direct-stream, with web control panel and watchdog supervisor.
```

Short variant (if the field truncates):

```text
Local Jellyfin stack: TorBox to PotPlayer direct-stream with control panel + watchdog.
```

## Website field

Leave **blank** — this stack is localhost-only
(`http://127.0.0.1:18080`, `:8888`, `:8096`) with no public demo site.
If GitHub requires a URL, point it at the releases page of this repo.

## Topics (Add topics)

```text
jellyfin, potplayer, torbox, rclone, strm, powershell, windows, media-server, direct-stream, tmdb
```

## Open Graph (for a future docs site)

```text
og:title = NexusMedia Jellyfin Stack
og:description = High-performance local Jellyfin stack: TorBox to rclone VFS to Jellyfin to PotPlayer direct-stream, with web control panel and watchdog supervisor.
og:type = website
og:image = assets/social-preview.svg (1200x630)
```

## X / Twitter card

```text
twitter:card = summary_large_image
twitter:title = NexusMedia Jellyfin Stack
twitter:description = TorBox to PotPlayer in one local stack — Jellyfin + TMDB, .strm libraries, control panel on :18080, proxy on :8888.
twitter:image = assets/social-preview.svg
```

Source banner: `assets/social-preview.svg` (1200×630, vector text, dark-first).
Alt text: `NexusMedia Jellyfin Stack banner — title, tagline and Windows, PowerShell, MIT badges on dark background`.
