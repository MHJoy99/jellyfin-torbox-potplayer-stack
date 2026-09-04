# Contributing

Thank you for your interest in contributing. This guide explains how to set up
your environment, propose changes, and submit pull requests that are easy to
review.

## Documentation Index

| Document | Purpose |
|---|---|
| [Code of Conduct](CODE_OF_CONDUCT.md) | Expected behavior for everyone in this community |
| [Security Policy](SECURITY.md) | Supported versions and how to report vulnerabilities privately |
| [Support](SUPPORT.md) | Where to ask questions and how to build a log bundle |
| [Bug report template](.github/ISSUE_TEMPLATE/bug_report.md) | Template for filing reproducible bug reports |
| [Feature request template](.github/ISSUE_TEMPLATE/feature_request.md) | Template for proposing new features |
| [Pull request template](.github/pull_request_template.md) | Template used for all pull requests |
| [README](README.md) | Stack overview, layout, and setup |
| [Runbook](RUNBOOK.md) | Restart order, key rotation, and operations |
| [Architecture](ARCHITECTURE.md) | System design and component notes |

## Getting Started

1. Fork the repository and clone your fork.
2. Install prerequisites: Windows 10 or later, Windows PowerShell 5.1 or
   PowerShell 7, Python 3.11 or later, and Git.
3. Set secrets as environment variables (never in files). The stack requires
   `$env:TORBOX_API_KEY` at a minimum. See [No Secrets Rule](#no-secrets-rule)
   below.
4. Verify services locally before changing code:
   `pwsh -File check_status.ps1` should exit with code 0.
5. Keep changes focused. One pull request should address one issue.

## First-Time Contributors

First-time contributors are welcome. Look for issues labeled
`good-first-issue` for small, well-scoped tasks such as documentation fixes,
log-message clarity, or adding checks to existing scripts. If no such issue
exists, open a new issue describing what you would like to work on and wait
for maintainer feedback before starting. Mention in your pull request that it
is your first contribution so reviewers can give extra context.

## Branch Naming

Create a feature branch from `main` for every change. Use a short,
lowercase, hyphen-separated suffix after one of these prefixes:

| Prefix | Use for |
|---|---|
| `feat/` | New features (for example `feat/retry-mylist-refresh`) |
| `fix/` | Bug fixes (for example `fix/launcher-resume-offset`) |
| `docs/` | Documentation only (for example `docs/clarify-runbook-order`) |

For anything that does not fit, use `chore/` (for example
`chore/update-gitattributes`). Do not commit directly to `main`.

## Commit Style

Write commits in the imperative present tense with a prefix matching the
branch type:

- `feat: add retry to mylist refresh`
- `fix: correct resume offset when episode hint is missing`
- `docs: clarify supervisor restart order`
- `chore: normalize line endings for scripts`

Keep the subject line under 72 characters. Add a body paragraph when the
change needs context: what was broken, why this approach was chosen, and any
follow-up work. Reference related issues with `Refs #123` or `Fixes #123`.

## Local Checks

Run these checks locally before opening a pull request. All of them must pass.

PowerShell parser gate (must report zero errors):

```powershell
$files = @('check_status.ps1','check_user_views.ps1','check_views_after_restart.ps1','clean_and_setup_libraries.ps1','cleanup_and_check_items.ps1','cleanup_extra_libraries.ps1','delete_stale_views.ps1','test_dpl.ps1','test_mcp_server.ps1','annotate_screenshot.ps1','PotPlayerLauncher.ps1')
$e = 0
foreach ($f in $files) {
  $errs = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
  Write-Host "$f errors=$($errs.Count)"
  $e += $errs.Count
}
exit $e
```

Python syntax check for the files you touched (extend the list as needed):

```powershell
python -m py_compile server/torbox-proxy.py control-panel/control_panel.py mcp-servers/rclone-storage/server.py
```

If you changed JavaScript, load the control panel locally and confirm the
browser console shows no errors. If you changed Markdown, confirm headers use
a space after `#` (for example `## Setup`) and that relative links resolve.

## No Secrets Rule

Never commit secrets. All credentials are environment variables or the OS
credential store:

- `$env:TORBOX_API_KEY` for the proxy, launcher, and supervisor.
- `$env:JELLYFIN_USER` and `$env:JELLYFIN_PASSWORD` for automation.
- `$env:JELLYFIN_API_KEY` for Jellyfin API access.

Do not paste keys, tokens, passwords, OAuth blobs, or full `rclone.conf`
contents into code, issues, pull requests, or logs. Redact them as
`<redacted>` before sharing. Maintainers recommend running
[gitleaks](https://github.com/gitleaks/gitleaks) (`gitleaks detect --source .`)
before pushing. A pull request containing a secret will be closed until the
secret is revoked and the history is cleaned.

## Windows-Specific Gotchas

- Execution policy: scripts require `RemoteSigned` or `Bypass`. If a script
  is blocked, run `Get-ExecutionPolicy -List` and then either
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` or invoke with
  `pwsh -ExecutionPolicy Bypass -File <script>.ps1`.
- Administrator rights: mount, service-install, and protocol-registration
  scripts (`install-rclone-service.ps1`, `install-control-panel.ps1`,
  `register-potplayer-protocol.ps1`, `lock_registry.ps1`) need an elevated
  PowerShell prompt. Day-to-day checks do not.
- Line endings: `.ps1` and `.bat` files use CRLF; `.sh`, `.py`, `.js`, and
  `.md` files use LF (enforced by `.gitattributes` and `.editorconfig`).
  Configure Git with `core.autocrlf=true` on Windows and do not reformat
  unrelated files.
- Paths: the stack uses absolute Windows paths such as `F:\Jellyfin\logs`.
  When reporting issues, keep drive letters accurate but redact user names.
- PowerShell edition: `supervisor.ps1` and the check scripts run under both
  Windows PowerShell 5.1 and PowerShell 7. Test parser compatibility with
  both when possible.

## Release and Version Note

Releases follow Semantic Versioning (`MAJOR.MINOR.PATCH`). The convention is
a plain-text `VERSION` file at the repository root containing a single
version string such as `1.4.0` with no trailing whitespace. Maintainers bump
this file on release commits; contributors should not bump it in feature
pull requests unless the maintainer asks. Tag names match the file
(`v1.4.0` for contents `1.4.0`).

## License and CLA

This project is MIT licensed (see `LICENSE`). There is no Contributor
License Agreement. Contribution is inbound-equals-outbound: by submitting a
pull request you agree that your contribution is offered under the same MIT
license as the repository.

## Pull Request Checklist

- [ ] Linked issue referenced (`Fixes #123` or `Refs #123`).
- [ ] Branch follows the `feat/`, `fix/`, `docs/`, or `chore/` convention.
- [ ] PowerShell parser gate passes with zero errors.
- [ ] `python -m py_compile` passes for every Python file touched.
- [ ] No secrets, tokens, or credentials in code, comments, or logs.
- [ ] Documentation updated (`README.md`, `RUNBOOK.md`, or `ARCHITECTURE.md`
      as applicable).
- [ ] Tested on Windows; execution-policy and admin notes included if needed.

## Response Times

Maintainers aim to acknowledge new issues and pull requests within five
business days. Reviews may take longer during busy periods. If there is no
response after seven days, a polite follow-up comment is welcome. Security
reports are prioritized; see [Security Policy](SECURITY.md). For general
questions, see [Support](SUPPORT.md).

## Related Documents

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Support](SUPPORT.md)
- [README](README.md)
- [Runbook](RUNBOOK.md)
- [Architecture](ARCHITECTURE.md)
