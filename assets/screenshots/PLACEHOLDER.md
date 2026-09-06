# Screenshots — capture checklist (no PNGs committed yet)

Status: this directory contains only this file. No `.png` captures are
committed in this change. Future captures land here as
`assets/screenshots/*.png` (`docs/screenshots/` is not used).
`README.md` intentionally lists them as a checklist table, not embedded
images, so there are no broken image links until the PNGs land.

Rules for every shot: demo library only. Do not commit secrets, tokens,
private library titles, hostnames, or personal paths. Blur before saving.

## Pending shots (4)

| File | Surface | Must show (demo data only) | Alt text (use verbatim on embed) |
|---|---|---|---|
| `01-control-panel.png` | Control panel at `http://127.0.0.1:18080` | Full maximized window, all services green, Start all and metrics visible | `Control panel overview showing all media-stack services running` |
| `02-jellyfin-nextup.png` | Jellyfin at `http://127.0.0.1:8096`, Series view | Demo posters, Next-Up row, and the Play-in-PotPlayer entry point | `Jellyfin Series page with demo posters, Next-Up row, and Play-in-PotPlayer entry` |
| `03-potplayer-direct-stream.png` | PotPlayer x64 via local `:8888` proxy | Direct-stream playback with the full-season playlist queue visible | `PotPlayer playing a direct stream with the full-season playlist visible` |
| `04-watch-console.png` | Watch console (`show-playback-log.ps1`) | Progress ticks and 80% Played marking with demo titles | `Watch console showing playback progress ticks and Played marking` |

## Capture checklist (Windows)

- [ ] Use demo titles only; hide or rename any personal library before capture.
- [ ] Maximize the window; crop browser chrome; save PNG ≤ 1600 px wide.
- [ ] Control panel: all services green before capture; include status + metrics area.
- [ ] Jellyfin: Series view with posters + Next-Up visible; no private collections.
- [ ] PotPlayer: playlist pane open showing the season queue; no file-system paths visible.
- [ ] Watch console: show progress ticks + 80% Played line; redact any token or hostname.
- [ ] Redact: blur tokens, hostnames, usernames, and private titles before saving.
- [ ] Name files exactly as in the table so `README.md` links stay stable.
- [ ] Keep the vector banner `assets/social-preview.svg` (1200x630) as the only committed visual until these PNGs land.
