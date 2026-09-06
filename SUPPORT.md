# Support

This page explains where to ask for help and what information to include so
maintainers can respond quickly.

## Support Channels

| Channel | Use for | Do not use for |
|---|---|---|
| GitHub Issues with the bug report template | Reproducible defects, crashes, or regressions | Usage questions, secrets, vulnerabilities |
| GitHub Issues with the feature request template | Proposals for new behavior or improvements | Bug reports, vulnerabilities |
| GitHub Discussions (Q and A) | Usage questions, setup help, and general guidance | Reproducible bugs, vulnerabilities |
| Private contact in the [Security Policy](SECURITY.md) | Vulnerabilities and accidentally leaked credentials | General questions, feature ideas |
| Project docs (`README.md`, `RUNBOOK.md`, `ARCHITECTURE.md`, FAQ, troubleshooting) | Self-serve setup, restart order, and operations answers | Reporting new bugs |

Before opening a new issue, search existing issues and discussions for the
same symptom. If you find a match, add your environment details and logs to
that thread instead of opening a duplicate. For first contributions, read
[Contributing](CONTRIBUTING.md) before filing.

## Before You Ask

Include all of the following so a maintainer can triage without a follow-up
round:

1. Environment table from the bug report template: OS build, `$PSVersionTable`
   output, `python --version`, `node --version` (if panel-related), commit
   hash or release tag, Jellyfin / proxy / control-panel URLs and ports,
   `rclone listremotes` output, and mounts present.
2. Exact command or click path, full error text, and `$LASTEXITCODE` where
   applicable.
3. Log bundle as described below, with secrets redacted.
4. What you already tried (restart order from `RUNBOOK.md`, docs searched,
   related issues checked).

For usage questions, the same environment table plus the exact command and
its full error text is enough; a full forensics bundle is optional.

## Response Times

Maintainers aim to acknowledge new issues and discussions within five
business days. Bug reports with a complete environment table and log bundle
are triaged first. Security reports follow the timelines in the
[Security Policy](SECURITY.md). A polite follow-up comment after seven days
without a response is welcome.

## Log Bundle How-To

A complete log bundle lets maintainers diagnose most problems without a
follow-up round.

> Secret hygiene: redact all keys, tokens, passwords, OAuth blobs, session
> cookies, and `rclone.conf` contents as `<redacted>` before posting. Never
> attach an unredacted config or database. See the secret policy in
> [Contributing](CONTRIBUTING.md#secret-policy). Reports containing live
> secrets will be redacted or removed and you will be asked to rotate them.

1. Record the supervisor forensics snapshot (from an elevated prompt if
   services are involved):

   ```powershell
   pwsh -File supervisor.ps1 -Mode Forensics
   ```

2. Capture structured health output:

   ```powershell
   pwsh -File check_status.ps1 -AsJson; $LASTEXITCODE
   pwsh -File check_user_views.ps1 -AsJson; $LASTEXITCODE
   ```

3. Collect the relevant log excerpts (last 100 to 200 lines are usually
   enough):
   - `F:\Jellyfin\logs\supervisor.log` for watchdog restarts.
   - `F:\Jellyfin\logs\potplayer-launcher.log` for playback resolution
     (`RAW:`, `STRM resolve`, `RESUME:` lines).
   - Jellyfin server logs under the Jellyfin `data/log/` directory for scan
     or authentication failures.
   - Proxy stdout and `http://127.0.0.1:8888/metrics` output for
     TorBox API or token-bucket errors.
4. Attach the bundle to the issue: environment table from the bug report
   template, the two health-command outputs pasted as text, the forensics
   output, and the trimmed log excerpts. Trim long logs rather than pasting
   entire files. Paste text excerpts; use file attachments only for logs
   over ~200 lines.

For playback or panel issues, also note the PotPlayer version, browser
version and console errors, and whether the issue reproduces after a clean
restart in the order documented in `RUNBOOK.md`.

## Out of Scope

Maintainers cannot help with upstream account issues (TorBox quotas,
Google Drive limits, Jellyfin upstream bugs), lost credentials, or hardware
failures. For those, check the upstream provider status and docs first, then
open a discussion only if there is a stack-specific integration question.

## Related Documents

- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Runbook](RUNBOOK.md)
