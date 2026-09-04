# Security Policy

Thank you for helping keep this project and its users safe. Read this policy
before reporting a vulnerability.

## Supported Versions

| Version | Supported |
|---|---|
| Latest `main` branch | Yes |
| Latest tagged release (`v*`) | Yes, until superseded by the next tag |
| Older tags and archived snapshots (including `archive/`) | No |

Security fixes are applied to the current `main` branch and released as a new
tag. There are no long-term support branches. If you are pinned to an older
snapshot, upgrade to the latest release before reporting.

## How to Report a Vulnerability

1. Do not open a public issue, discussion, or pull request for the report.
2. Contact the maintainers privately at `[INSERT-MAINTAINER-CONTACT]`
   (replace with the published maintainer email before public launch).
   Include the affected component, version or commit hash, impact, and
   step-by-step reproduction details.
3. Allow up to five business days for an initial response. Maintainers will
   confirm receipt, assess severity, and coordinate a fix and disclosure
   timeline with you.
4. Keep the report confidential until maintainers confirm a fix is released
   or agree on a disclosure date. Credit is given with your permission.

## Rules for Reports

- Never include live keys, tokens, passwords, or session cookies in a
  report. Replace them with `<redacted>` placeholders and describe where the
  value was used.
- Do not include a working credential even to demonstrate impact. A
  redacted reproduction is sufficient.
- Do not test against systems you do not own. Limit probing to local
  installations of this stack.
- The no-secrets rule from [Contributing](CONTRIBUTING.md) applies to all
  security correspondence.

## Scope

In scope: the proxy (`server/torbox-proxy.py`), the control panel
(`control-panel/`), the supervisor and check scripts (`supervisor.ps1`,
`check_*.ps1`), and the launch and sync scripts. Out of scope: upstream
services (TorBox, Google Drive, Jellyfin itself), reporter infrastructure,
and social-engineering or physical attacks.

## Related Documents

- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Support](SUPPORT.md)
