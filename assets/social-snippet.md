# Social / repo-header snippets (copy-paste)

Status: no PNG screenshots are committed yet — `assets/screenshots/` holds only
`PLACEHOLDER.md` with a 4-shot capture checklist. The only committed visual is
the vector banner `assets/social-preview.svg` (1200x630, dark-first). Do not
point `og:image` / `twitter:image` at the pending PNG names until they land.

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

### Variant A — Feature & Architecture focus (Default)

```text
og:title = NexusMedia Jellyfin Stack — Direct-Stream 4K Media Server
og:description = High-performance local Jellyfin stack: TorBox to rclone VFS to Jellyfin to PotPlayer direct-stream, with web control panel and watchdog supervisor.
og:type = website
og:image = assets/social-preview.svg (1200x630, vector-only until screenshots land)
```

### Variant B — Benefits & Experience focus (No Transcoding / Instant Seek)

```text
og:title = NexusMedia Jellyfin Stack — No-Transcode 4K TorBox Streaming
og:description = Mount cloud torrents locally, click Play in Jellyfin, and direct-stream full seasons in PotPlayer with resume sync and zero buffering.
og:type = website
og:image = assets/social-preview.svg (1200x630, vector-only until screenshots land)
```

## X / Twitter card

### Variant A — Feature & Architecture focus (Default)

```text
twitter:card = summary_large_image
twitter:title = NexusMedia Jellyfin Stack — Direct-Stream 4K Media Server
twitter:description = TorBox to PotPlayer in one local stack — Jellyfin + TMDB, .strm libraries, control panel on :18080, proxy on :8888.
twitter:image = assets/social-preview.svg
```

### Variant B — Benefits & Experience focus (No Transcoding / Instant Seek)

```text
twitter:card = summary_large_image
twitter:title = NexusMedia Jellyfin Stack — No-Transcode 4K TorBox Streaming
twitter:description = Turn Jellyfin into a 4K direct-stream powerhouse on Windows: TorBox cloud mounts + PotPlayer season playback with live resume sync.
twitter:image = assets/social-preview.svg
```

Source banner: `assets/social-preview.svg` (`viewBox 0 0 1200 630`, vector text, dark-first `#070B12`, no raster, no external URLs).
Alt text (use verbatim): `NexusMedia Jellyfin Stack banner — title, tagline and Windows, PowerShell, MIT badges on dark background`.

Screenshot note: pending captures from `assets/screenshots/PLACEHOLDER.md`
(`01-control-panel.png`, `02-jellyfin-nextup.png`,
`03-potplayer-direct-stream.png`, `04-watch-console.png`) are not committed
yet and are not referenced here. Keep this file SVG-only until they land.
