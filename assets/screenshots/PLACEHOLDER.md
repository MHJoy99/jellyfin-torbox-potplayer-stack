# Screenshots — shot list (PLACEHOLDER, no binaries yet)

Drop the captures here as `assets/screenshots/*.png` in a follow-up.
Do not commit secrets, tokens, or personal library titles — use demo data.

## Required shots

1. `panel-overview.png` — Control panel (`http://127.0.0.1:18080`)
   full window, dark theme, all services green.
   Alt: `Control panel overview showing all media-stack services running`.
2. `watch-console.png` — Watch-logs console (`show-playback-log.ps1`)
   tailing playback + resume sync lines.
   Alt: `Watch console streaming playback and resume-sync log lines`.
3. `playback-potplayer.png` — PotPlayer during direct-stream from the
   local proxy (`:8888`), season playlist visible.
   Alt: `PotPlayer playing a direct stream launched from the season launcher`.

## Capture how-to (Windows)

1. Start the stack: `pwsh -File supervisor.ps1`.
2. Open the panel at `http://127.0.0.1:18080`, maximize the window.
3. `Win + Shift + S` → crop chrome, save PNG (≤ 1600 px wide).
4. Redact: blur tokens, hostnames, and private titles before saving.
5. Name files exactly as above so `README.md` links stay stable.
