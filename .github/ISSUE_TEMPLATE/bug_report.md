---
name: Bug report
about: Report a reproducible defect in the stack
title: "[Bug] "
labels: bug
assignees: ""
---

## Summary

A clear, one-paragraph description of the defect.

## Environment

### Versions

| Component | Version / Build | How to find |
|---|---|---|
| OS & Build | | `[System.Environment]::OSVersion.VersionString` (e.g. Windows 11 23H2) |
| PowerShell | | `$PSVersionTable.PSVersion` |
| Python | | `python --version` |
| rclone | | `rclone version` (first line) |
| WinFsp | | Control Panel > Programs or `rclone version` |
| PotPlayer | | PotPlayer > Main Menu > About (e.g. 64-bit 24xxxx) |
| Stack Commit / Release | | `git rev-parse --short HEAD` or release tag |
| Install Method | | One-click `install-all.ps1` / Manual / Portable / Service |
| Supervisor Mode | | Watchdog / Start / Status / Forensics |

### Ports and Endpoints

| Port | Service | Bound / Accessible? | Response or HTTP Code |
|---|---|---|---|
| 8096 | Jellyfin Web & API | Yes / No | (e.g. HTTP 200 / `System/Info/Public` ok) |
| 8888 | TorBox Proxy | Yes / No | (e.g. HTTP 200 `/health` / refused) |
| 18080 | Control Panel | Yes / No | (e.g. HTTP 200 `/health` / refused) |
| 18099 | PotPlayer Bridge Helper | Yes / No | (e.g. HTTP 200 `/health` / N/A) |
| 5572 | rclone RC Port | Yes / No | (e.g. `rc/noop` ok / not running) |
| 8920 / 443 | HTTPS / Reverse Proxy | Yes / No | (e.g. loopback only / Caddy active) |

### Mounts and Remotes

- rclone remotes (`rclone listremotes`):
- Mount drive `T:\` present and browsable: Yes / No
- Mount drive `G:\` present and browsable: Yes / No

## Reproduction checklist

Complete this checklist before filling in Steps to Reproduce. It keeps
reports actionable and avoids back-and-forth.

- [ ] I searched existing issues for the same symptom and error text.
- [ ] I reproduced from a fresh terminal after re-setting env secrets
      (`TORBOX_API_KEY`, `JELLYFIN_*`) so stale values are ruled out.
- [ ] I ran the ordered start (`pwsh -File supervisor.ps1 -Mode Start`
      or the watchdog) and confirmed mounts were healthy before Jellyfin.
- [ ] I can reproduce with the minimal steps below (no extra apps or tabs).
- [ ] I note the frequency: `always` / `sometimes` / `once`.
- [ ] I collected `check_status.ps1` output plus the exit code
      (`$LASTEXITCODE`) and pasted it under Logs.
- [ ] I redacted all secrets as `<redacted>` (keys, tokens, passwords,
      `rclone.conf` contents, CDN tokens, env dumps).

## Steps to Reproduce

Give the minimal path that triggers the defect. Use exact commands or
click paths plus the observed intermediate state after each step.

1. Step one with the exact command or click path.
   Observed: what you see after this step (healthy output, URL, exit code).
2. Step two with expected intermediate state.
   Observed: what you see after this step.
3. Step three that triggers the defect.
   Observed: the failure as it appears.

Frequency: `always` / `sometimes` / `once` (plus what changes between runs
when it is intermittent, for example cold boot vs. warm restart).

## Expected Behavior

What should have happened.

## Actual Behavior

What happened instead, including the full error text and exit code
(`$LASTEXITCODE`) where applicable.

## Recent Logs and Diagnostics

Paste the relevant outputs with secrets redacted as `<redacted>`. See
[SUPPORT.md](../../SUPPORT.md) for the full log-bundle guide.

### Diagnostic commands

```powershell
# 1. Structured health output
pwsh -File check_status.ps1 -AsJson; "ExitCode: $LASTEXITCODE"

# 2. Supervisor forensics snapshot (builds timestamped zip)
pwsh -File supervisor.ps1 -Mode Forensics

# 3. User views sanity probe
pwsh -File check_user_views.ps1 -AsJson; "ExitCode: $LASTEXITCODE"
```

### Recent log excerpts

Paste recent tails (last 30-50 lines) from the relevant log file below.
**Redact all API keys, bearer tokens, passwords, usernames, and rclone configs.**

#### `logs/supervisor.log` (Watchdog and service events)
```text
<paste supervisor.log tail here>
```

#### `logs/potplayer-launcher.log` (Playback, playlist, and protocol events)
```text
<paste potplayer-launcher.log tail here>
```

#### Proxy `/metrics` or `/health` response
```text
<paste proxy metrics/health output here>
```

#### Jellyfin Server Log (from `server/programdata/log/` or `data/log/`)
```text
<paste Jellyfin log excerpt here>
```

Pre-submit log check:

- [ ] Forensics or Status output attached (or reason why not applicable).
- [ ] `check_status.ps1` exit code recorded (`0` healthy / `1` warming /
      `2` investigate).
- [ ] No secrets in pasted logs, screenshots, or file names.

## Additional Context

Anything else that helps: screenshots, frequency, recent changes, or links
to related issues.

Start here when stuck: [Docs Index](../../docs/index.md),
[Troubleshooting](../../docs/troubleshooting.md),
[Reference](../../docs/reference.md). See also
[Contributing](../../CONTRIBUTING.md),
[Code of Conduct](../../CODE_OF_CONDUCT.md), and
[Security Policy](../../SECURITY.md).
