# Screenshots — capture checklist (no PNGs committed yet)

Status: this directory contains only this file. No `.png` captures are
committed in this change. Future captures land here as
`assets/screenshots/*.png` (`docs/screenshots/` is not used).
`README.md` intentionally lists them as a checklist table, not embedded
images, so there are no broken image links until the PNGs land.

Rules for every shot: demo library only. Do not commit secrets, tokens,
private library titles, hostnames, or personal paths. Blur before saving.

## Pending shots (4)

| File | Target surface | Recommended window & resolution | Must show (demo data only) | Alt text (use verbatim on embed) |
|---|---|---|---|---|
| `01-control-panel.png` | Control panel at `http://127.0.0.1:18080` | Browser window, 1600×900 (max width 1600 px) | Full window, dark theme, all services green, Start all and metrics cards visible | `Control panel overview showing all media-stack services running` |
| `02-jellyfin-nextup.png` | Jellyfin at `http://127.0.0.1:8096`, Series view | Browser window, 1600×900 (max width 1600 px) | Demo series posters, Next-Up row, and the Play-in-PotPlayer entry button | `Jellyfin Series page with demo posters, Next-Up row, and Play-in-PotPlayer entry` |
| `03-potplayer-direct-stream.png` | PotPlayer x64 via local `:8888` proxy | Player window, 1600×900 or 1920×1080 (max width 1600 px) | Direct-stream playback with playlist drawer open showing season queue | `PotPlayer playing a direct stream with the full-season playlist visible` |
| `04-watch-console.png` | Watch console (`show-playback-log.ps1`) | Terminal window, 1280×720 (max width 1600 px) | Progress ticks (5s intervals) and 80% Played marking with demo titles | `Watch console showing playback progress ticks and Played marking` |

## Exact capture checklist (Windows)

- [ ] **Directory target:** save all output captures directly under `assets/screenshots/` (paths: `assets/screenshots/01-control-panel.png`, `assets/screenshots/02-jellyfin-nextup.png`, `assets/screenshots/03-potplayer-direct-stream.png`, `assets/screenshots/04-watch-console.png`).
- [ ] **Maximum resolution:** keep width ≤ 1600 px (1600×900 recommended for browser/player windows; 1280×720 for terminal).
- [ ] **Window state:** maximize or frame window cleanly; crop out OS taskbar and external browser chrome.
- [ ] **Demo data isolation:** use demo titles only; hide or rename any personal library before capture.
- [ ] **Control panel (`01-control-panel.png`):** wait until all services indicate healthy/green before capture; include status tiles and metrics area.
- [ ] **Jellyfin (`02-jellyfin-nextup.png`):** capture Series view with posters + Next-Up visible; ensure no personal user accounts or private collections are exposed.
- [ ] **PotPlayer (`03-potplayer-direct-stream.png`):** ensure playlist pane is open showing the season queue; verify no local file-system paths or personal directories are visible.
- [ ] **Watch console (`04-watch-console.png`):** capture active progress ticks + 80% Played line; redact any token, IP, or hostname.
- [ ] **Redaction pass:** inspect full image and blur tokens, API keys, hostnames, usernames, and private titles before saving.
- [ ] **Filename stability:** name files exactly as listed in the table above so `README.md` links stay stable.
- [ ] **Visual assets policy:** keep the vector banner `assets/social-preview.svg` (1200×630) as the only committed visual until these PNGs land.
