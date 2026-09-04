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
| Commit hash or release tag | |
| Jellyfin URL and port (default `http://127.0.0.1:8096`) | |
| Proxy URL and port (default `http://127.0.0.1:8888`) | |
| Control panel URL and port (default `http://127.0.0.1:18080`) | |
| rclone remotes (`rclone listremotes`) | |
| Mounts present (`T:\`, `G:\`) | Yes / No |

## Steps to Reproduce

1. Step one with the exact command or click path.
2. Step two with expected intermediate state.
3. Step three that triggers the defect.

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

## Additional Context

Anything else that helps: screenshots, frequency, recent changes, or links
to related issues. See also [Contributing](../../CONTRIBUTING.md),
[Code of Conduct](../../CODE_OF_CONDUCT.md), and
[Security Policy](../../SECURITY.md).
