# NexusMedia Jellyfin Stack — Brand v1.0

Original brand marks for the public repo. No third-party logos
(Jellyfin / TorBox / PotPlayer marks are **not** reproduced here).

## Files

| File | Use | Alt text |
|---|---|---|
| `assets/logo.svg` | Default logo for **light** backgrounds | `NexusMedia Jellyfin Stack logo — play button over stacked layers beside the NexusMedia wordmark` |
| `assets/logo-dark.svg` | Variant for **dark** backgrounds | `NexusMedia Jellyfin Stack logo, light-text variant for dark backgrounds` |
| `assets/favicon.svg` | Simplified mark / browser tab icon | `NexusMedia stack mark — play button over a stack layer` |
| `assets/social-preview.svg` | 1200×630 social banner (vector text) | `NexusMedia Jellyfin Stack banner — title, tagline and Windows, PowerShell, MIT badges on dark background` |

Copy-paste helpers (no live files touched):

- `assets/favicon-snippet.html` — one `<link>` block for `control-panel/index.html`.
- `assets/social-snippet.md` — GitHub About text + website-field suggestion.
- `assets/screenshots/PLACEHOLDER.md` — shot list + capture how-to (no binaries committed).

## Colors (hex)

| Token | Hex | Role |
|---|---|---|
| `bg-deep` | `#070B12` | Page / banner background (matches panel `theme-color`) |
| `panel` | `#0E1522` | Logo tile fill |
| `panel-dark-variant` | `#131C2E` | Tile fill on dark backgrounds (slightly lifted) |
| `accent` | `#4F8CFF` | Play button / primary |
| `accent-deep` | `#2F6BFF` | Sub-head text on light backgrounds (contrast) |
| `accent-light` | `#7AA8FF` | Sub-head / strokes on dark backgrounds |
| `teal` | `#38D6C0` | Stack layers / MIT pill |
| `ink` | `#0E1522` | Wordmark on light backgrounds |
| `paper` | `#EAF0FF` | Wordmark on dark backgrounds |
| `muted` | `#9AA8C3` | Secondary tagline line |
| `muted-light` | `#C4CFE6` | Primary tagline line on dark |
| `white` | `#FFFFFF` | Play triangle |

Contrast notes: `ink on white ≈ 15.9:1`; `paper on bg-deep ≈ 14.5:1`;
`accent-deep on white ≈ 4.6:1` (body-text safe); plain `accent` is
decorative-only on white — use `accent-deep` for text.

## Dark-mode-safe palette

- Default `logo.svg` is for **light** surfaces only.
- On dark surfaces (`bg-deep`, `panel`, GitHub dark) use **`logo-dark.svg`**.
- Never place default-logo dark text (`#0E1522`) on dark backgrounds.
- `favicon.svg` tile (`#0E1522` + `#4F8CFF` ring) is tested on both light
  and dark browser chrome.
- `social-preview.svg` is dark-first (`#070B12`) for X / GitHub / Discord
  card renderers.

## Fonts

System stacks only — no webfont downloads, works offline:

- Wordmark / banner: `Inter, 'Segoe UI', system-ui, -apple-system, sans-serif`
- Mono (docs / code): `Consolas, 'Cascadia Mono', monospace`

SVG `<text>` uses the same stack so banners render without external fonts.

## Clearspace

- Keep clearspace ≥ **25% of tile width** on all sides (≈20 units on the
  80-unit tile).
- Minimum widths: full lockup ≥ **120 px**, favicon mark ≥ **16 px**.
- Don't re-set the wordmark in another typeface; scale the SVG as a unit.

## Misuse rules

1. No raster images or external URLs inside the SVGs.
2. No copyrighted logos — do not add Jellyfin / TorBox / PotPlayer artwork.
3. Don't recolor outside the table above; don't add gradients or shadows.
4. Don't stretch, rotate, outline, or rearrange the play/stack lockup.
5. Don't place the default logo on dark backgrounds (use `logo-dark.svg`).
6. Don't use the banner below **600 px** wide — use `favicon.svg` instead.

## SVG technical notes

- All SVGs are hand-written, valid XML, `viewBox`-based (scale freely).
- No `<image>`, no `href`/`xlink:href`, no `http` URLs, no embedded raster.
- Each SVG is **< 20 KB** (verified sizes listed below; re-check with
  `Get-ChildItem assets/*.svg`).

Verified 2026-09-04 (see commit message for hashes):

- `logo.svg`: 1295 bytes
- `logo-dark.svg`: 1321 bytes
- `favicon.svg`: 916 bytes
- `social-preview.svg`: 2713 bytes

## Favicon sizes note

- `favicon.svg` is resolution-independent; browsers rasterize it to
  **16×16** (tab), **32×32** (retina tab / taskbar), **180×180**
  (Apple touch / PWA) automatically.
- Optional PNG exports (not committed): export the SVG at 16, 32, 180 px
  and reference per `assets/favicon-snippet.html`. Keep the SVG as source.

## Open Graph strings (copy-paste)

```text
og:title = NexusMedia Jellyfin Stack
og:description = High-performance local Jellyfin stack: TorBox to rclone VFS to Jellyfin to PotPlayer direct-stream, with web control panel and watchdog supervisor.
og:type = website
og:image = assets/social-preview.svg (1200x630)
```

## Twitter / X card strings (copy-paste)

```text
twitter:card = summary_large_image
twitter:title = NexusMedia Jellyfin Stack
twitter:description = TorBox to PotPlayer in one local stack — Jellyfin + TMDB, .strm libraries, control panel on :18080, proxy on :8888.
twitter:image = assets/social-preview.svg
```

## README badges snippet (copy-paste)

```markdown
[![License: MIT](https://img.shields.io/badge/License-MIT-38D6C0.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows-4F8CFF.svg)](#setup)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%2B-5391FE.svg)](supervisor.ps1)
```

Paste directly under the `# NexusMedia Jellyfin Stack` H1 in `README.md`.

## Star-CTA snippet (copy-paste)

```markdown
> ⭐ If this stack saved you an evening of buffering, please **star the repo** —
> it helps others find a local-first Jellyfin + PotPlayer setup that just plays.
```

Paste at the end of `README.md` or under `## Notes`.

---

Brand v1.0 — 2026-09-04. Original marks, MIT (same as repo `LICENSE`).
