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
   PowerShell 7, Python 3.11 or later, Node.js 20 or later (for JavaScript
   syntax checks), and Git.
3. Set secrets as environment variables (never in files). The stack requires
   `$env:TORBOX_API_KEY` at a minimum. See [Secret Policy](#secret-policy)
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

Create a feature branch from `main` for every change. Sync first:

```powershell
git fetch origin
git checkout main
git pull --ff-only origin main
git checkout -b feat/short-description origin/main
```

Use a short, lowercase, hyphen-separated suffix after one of these prefixes:

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

## Pull Request Steps

Follow these steps for every pull request:

1. **Sync and branch.** Fetch `origin`, create your branch from
   `origin/main` using the naming convention above.
2. **Link an issue.** Open or pick an issue first. Small typo fixes are the
   only exception; every code or behavior change needs a tracked issue.
3. **Make a focused change.** One issue per pull request. Do not reformat
   unrelated files or mix features with refactors.
4. **Run the local checks.** Complete every check in
   [Test Expectations](#test-expectations). All of them must pass before
   you push.
5. **Verify the secret scan.** Confirm no keys, tokens, passwords, OAuth
   blobs, or `rclone.conf` contents are present in the diff, comments, or
   attached logs. See [Secret Policy](#secret-policy).
6. **Push and open the pull request.** Fill in the entire pull request
   template: linked issue, what and why, verification output pasted as text,
   and screenshots (or `No visual change.`).
7. **Respond to review.** Address every comment, push fixup commits to the
   same branch, and re-run the local checks. Mark threads resolved only
   after pushing the fix.
8. **Wait for merge.** Maintainers squash or merge once CI is green and at
   least one approval is recorded. Do not merge your own pull request
   unless a maintainer asks you to.

Draft pull requests are welcome for early feedback; mark the pull request
ready for review only when steps 1-6 are complete.

## Test Expectations

Every pull request must meet these expectations. They mirror the CI jobs in
`.github/workflows/ci.yml` and `.github/workflows/secret-scan.yml`.

| Check | CI job | Local command | Pass criteria |
|---|---|---|---|
| PowerShell parse | `ps1-parse` | Parse every `*.ps1` recursively (see snippet) | Zero errors |
| Python compile | `python-compile` (3.11 and 3.12) | `python -m py_compile` on every `*.py` touched, or all files | Exit code 0 |
| JavaScript syntax | `js-syntax` (Node 20 and 22) | `node --check` on every `*.js` touched | Exit code 0 |
| Markdown hygiene | `markdown-links` | No new absolute local paths; headers use a space after `#`; relative links resolve | No new warnings |
| Secret scan | `no-secrets` + `secret-scan.yml` (gitleaks) | Manual diff review plus `gitleaks detect --source .` when available | Zero hits |
| Smoke test | Manual | `pwsh -File check_status.ps1` | Exit code 0 |

PowerShell parser gate over all files (must report zero errors):

```powershell
$ErrorActionPreference = 'Stop'
$files = Get-ChildItem -Recurse -Filter *.ps1 -File
$e = 0
foreach ($f in $files) {
  $errs = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
  if ($errs.Count -gt 0) {
    Write-Host ("FAIL " + $f.FullName + " errors=" + $errs.Count)
  }
  $e += $errs.Count
}
Write-Host ("Total errors=" + $e)
exit $e
```

Python syntax check for the files you touched (or all files to match CI):

```powershell
python -m py_compile server/torbox-proxy.py control-panel/control_panel.py mcp-servers/rclone-storage/server.py
```

JavaScript syntax check for the files you touched:

```powershell
node --check control-panel/app.js
```

If you changed JavaScript, also load the control panel locally and confirm
the browser console shows no errors. If you changed Markdown, confirm headers
use a space after `#` (for example `## Setup`), relative links resolve, and
you did not introduce new absolute local paths except for
documented stack paths such as `F:\Jellyfin\logs`.

Paste the relevant command output (parser counts, `py_compile` result,
`node --check` result, `check_status.ps1` exit code) into the
`Verification Checklist` section of the pull request template. An empty
checklist or a screenshot of a terminal is not sufficient; paste the text.

## Secret Policy

Never commit secrets. All credentials are environment variables or the OS
credential store:

- `$env:TORBOX_API_KEY` for the proxy, launcher, and supervisor.
- `$env:JELLYFIN_USER` and `$env:JELLYFIN_PASSWORD` for automation.
- `$env:JELLYFIN_API_KEY` for Jellyfin API access.

Rules:

- Do not paste keys, tokens, passwords, OAuth blobs, session cookies, or
  full `rclone.conf` contents into code, comments, issues, pull requests,
  discussions, or logs. Redact them as `<redacted>` before sharing.
- Do not add a working credential even to demonstrate a bug. A redacted
  reproduction is sufficient.
- Run [gitleaks](https://github.com/gitleaks/gitleaks)
  (`gitleaks detect --source .`) before pushing when possible. CI also runs
  a `no-secrets` pattern scan and a weekly secret scan; either one failing
  blocks the pull request.
- If a secret leaks into a commit, issue, or log: revoke and rotate it
  immediately, then clean the history (for example with `git filter-repo`
  or BFG) and force-push only your feature branch. Tell a maintainer so the
  exposure window can be assessed. A pull request containing a live secret
  will be closed until the secret is revoked and the history is cleaned.
- The same policy applies to security reports and support bundles; see
  [Security Policy](SECURITY.md) and [Support](SUPPORT.md).

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

Copy this checklist into your pull request description (it mirrors
`.github/pull_request_template.md`) and check every box:

- [ ] Linked issue referenced (`Fixes #123` or `Refs #123`).
- [ ] Branch created from `origin/main` and follows the `feat/`, `fix/`,
      `docs/`, or `chore/` convention.
- [ ] PowerShell parser gate passes with zero errors (output pasted).
- [ ] `python -m py_compile` passes for every Python file touched
      (output pasted).
- [ ] `node --check` passes for every JavaScript file touched, or `No JS
      change` noted.
- [ ] `check_status.ps1` smoke test passes (exit code pasted).
- [ ] No secrets, tokens, or credentials in code, comments, or logs;
      gitleaks or CI `no-secrets` passes.
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
