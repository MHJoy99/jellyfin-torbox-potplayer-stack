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

| Field | Value |
|---|---|
| OS and build (for example Windows 11 23H2) | |
| PowerShell version (`$PSVersionTable.PSVersion`) | |
| Python version (`python --version`) | |
| rclone version (`rclone version`) + WinFsp version | |
| PotPlayer version (Help > About) | |
| Commit hash or release tag (`git rev-parse --short HEAD`) | |
| Install method (one-click `install-all.ps1` / manual / portable) | |
| Supervisor mode used (Watchdog / Start / Status / Forensics) | |
| Jellyfin URL and port (default `http://127.0.0.1:8096`) | |
| Proxy URL and port (default `http://127.0.0.1:8888`) | |
| Control panel URL and port (default `http://127.0.0.1:18080`) | |
| rclone remotes (`rclone listremotes`) | |
| Mounts present (`T:\`, `G:\`) | Yes / No |

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

## Logs

Paste the relevant outputs with secrets redacted as `<redacted>`. See
[SUPPORT.md](../../SUPPORT.md) for the full log-bundle guide.

```powershell
# Supervisor forensics snapshot
pwsh -File supervisor.ps1 -Mode Forensics

# Structured health output
pwsh -File check_status.ps1 -AsJson; $LASTEXITCODE
```

Attach excerpts from `F:\Jellyfin\logs\supervisor.log`,
`F:\Jellyfin\logs\potplayer-launcher.log`, Jellyfin `data/log/`, or the
proxy `/metrics` endpoint as applicable. Do not paste API keys, passwords,
tokens, or `rclone.conf` contents.

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
