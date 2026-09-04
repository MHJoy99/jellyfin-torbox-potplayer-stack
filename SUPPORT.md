# Support

This page explains where to ask for help and what information to include so
maintainers can respond quickly.

## Where to Ask

| Channel | Use for |
|---|---|
| GitHub Issues with the bug report template | Reproducible defects, crashes, or regressions |
| GitHub Issues with the feature request template | Proposals for new behavior or improvements |
| GitHub Discussions (Q and A) | Usage questions, setup help, and general guidance |
| Security Policy private contact | Vulnerabilities; never file these as public issues |

Before opening a new issue, search existing issues and discussions for the
same symptom. If you find a match, add your environment details and logs to
that thread instead of opening a duplicate.

## Response Times

Maintainers aim to acknowledge new issues and discussions within five
business days. Bug reports with a complete environment table and log bundle
are triaged first. Security reports follow the timelines in the
[Security Policy](SECURITY.md). A polite follow-up comment after seven days
without a response is welcome.

## Log Bundle How-To

A complete log bundle lets maintainers diagnose most problems without a
follow-up round. Redact all keys, tokens, and passwords as `<redacted>`
before posting.

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
   template, the two health-command outputs, the forensics output, and the
   trimmed log excerpts. Trim long logs rather than pasting entire files.

For usage questions, include the same environment table plus the exact
command you ran and its full error text.

## Related Documents

- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Runbook](RUNBOOK.md)
