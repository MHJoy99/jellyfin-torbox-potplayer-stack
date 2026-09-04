# NexusMedia Jellyfin Stack — Docs Index

This index is the starting point for the whole documentation set, with an overview of the stack and links to every guide.

## Contents

- [What this stack does](#what-this-stack-does)
- [Start here](#start-here)
- [All guides](#all-guides)
- [Ports at a glance](#ports-at-a-glance)
- [How the pieces fit](#how-the-pieces-fit)

## What this stack does

NexusMedia is a local-first Jellyfin stack that plays cloud media through PotPlayer with resume sync. TorBox torrents and Drive media are exposed through an rclone VFS layer as `.strm` libraries, Jellyfin adds TMDB metadata and tracking, a local proxy resolves fresh CDN links, PotPlayer plays full-season playlists, and a panel plus supervisor keep every service healthy.

## Start here

- New to the stack: read [Quickstart](quickstart.md) first, then [Install](install.md) for the full install, update, and uninstall lifecycle.
- Cloud setup: [TorBox](torbox.md) explains where the API key comes from and how rotation works.
- Playback setup: [Jellyfin](jellyfin.md) covers libraries and resume, while [PotPlayer](potplayer.md) covers the protocol handler and playlists.
- Operations: [Panel](panel.md) explains every card and endpoint, and [Supervisor](supervisor.md) explains modes, the watchdog, and forensics.
- Reference: [Architecture](architecture.md) has the diagram, ports, data flow, and performance tips, and [Reference](reference.md) has the glossary, security rules, and backup plan.
- Stuck: try [FAQ](faq.md) for short answers or [Troubleshooting](troubleshooting.md) for symptom-to-fix steps.

## All guides

| Guide | What it covers |
| --- | --- |
| [Quickstart](quickstart.md) | Expanded copy of the README quickstart with verify steps. |
| [Install](install.md) | One-click, manual, and portable installs, plus updating and uninstall. |
| [TorBox](torbox.md) | API key location, env setup, proxy auth, and rotation. |
| [Jellyfin](jellyfin.md) | `.strm` libraries, TMDB matching, and resume expectations. |
| [PotPlayer](potplayer.md) | Protocol handler, playlist format, and resume with seek. |
| [Panel](panel.md) | Every panel card and HTTP endpoint explained. |
| [Supervisor](supervisor.md) | Modes, ordered start, watchdog, and forensics bundle. |
| [FAQ](faq.md) | Ten question-and-answer entries with full-sentence answers. |
| [Troubleshooting](troubleshooting.md) | Ten problems with symptoms and fixes. |
| [Architecture](architecture.md) | ASCII diagram, ports, data flow, and performance tuning. |
| [Reference](reference.md) | Glossary of fifteen terms, security, and backup plus restore. |

## Ports at a glance

| Port | Service | Health probe |
| --- | --- | --- |
| 8096 | Jellyfin HTTP web and API | `http://127.0.0.1:8096/System/Info/Public` |
| 8920 | Jellyfin HTTPS when container TLS is used | Same Jellyfin public info over TLS |
| 8888 | TorBox proxy in `server/torbox-proxy.py` | `http://127.0.0.1:8888/health` |
| 18080 | Web control panel in `control-panel/control_panel.py` | `http://127.0.0.1:18080/health` |
| 18099 | PotPlayer bridge helper | `http://127.0.0.1:18099/health` |
| 5572 | rclone RC for VFS refresh and stats | VFS refresh and cache calls |
| 80 / 443 | Caddy reverse proxy when the edge profile is used | Forwards to Jellyfin |
| 8191 | FlareSolverr for indexer bypass when enabled | Indexer helper only |

All services bind to loopback by default and are exposed remotely only through an explicit reverse proxy or tunnel. See [Architecture](architecture.md) and [Reference](reference.md) for the security warning.

## How the pieces fit

Cloud remotes feed the VFS cache engine, which feeds both Jellyfin through `.strm` files and the proxy through HTTP. Jellyfin builds `potplayer://` links, the launcher resolves them to VFS paths or proxy URLs, PotPlayer plays them, the tracker reports progress back, and the panel and supervisor observe and repair the chain. The full diagram and step-by-step flow are in [Architecture](architecture.md).
