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
snapshot, upgrade to the latest release and confirm the issue still reproduces
before reporting.

## Security Report SLAs & Response Timelines

Maintainers triage and resolve security vulnerability reports according to
the following severity SLAs:

| Severity | Target Initial Response | Target Triage & Reproduction | Target Patch & Release | Examples |
|---|---|---|---|---|
| **Critical** | 24 hours | 48 hours | 7 calendar days | Remote code execution, unauthenticated credential/token leakage, unauthorized host system execution. |
| **High** | 48 hours | 4 calendar days | 14 calendar days | Authentication bypass, privilege escalation in local services, proxy credential exposure to local unprivileged users. |
| **Medium** | 3 business days | 7 business days | 30 calendar days | Denial-of-service in local watchdog, token bucket rate-limiter bypass, SSRF in local API endpoints. |
| **Low / Informational** | 5 business days | 10 business days | Next scheduled release | Missing hardening headers, low-impact local path traversal with standard file permissions, non-sensitive error disclosure. |

## How to Report a Vulnerability

1. Do not open a public issue, discussion, or pull request for the report.
2. Contact the maintainers privately at `[INSERT-MAINTAINER-CONTACT]`
   (replace with the published maintainer email before public launch). If no
   contact is published yet, use GitHub Security Advisories
   (`Security > Report a vulnerability`) for a private report.
3. Include in your report:
   - Affected component and file paths (for example
     `server/torbox-proxy.py`, `control-panel/`, `supervisor.ps1`).
   - Version or commit hash, OS and PowerShell edition, and Python or Node
     versions where relevant.
   - Severity assessment per the SLA table above.
   - Impact assessment: what an attacker can and cannot do.
   - Step-by-step reproduction with redacted values only.
   - Any suggested mitigation or patch draft, if known.
4. Maintainers will confirm receipt within the severity SLA, assess impact,
   and coordinate a private fix and disclosure timeline with you.
5. Keep the report confidential until maintainers confirm a fix is released
   or agree on a coordinated disclosure date. Credit is given with your permission.

## Secret Policy for Reports

- Never include live keys, tokens, passwords, OAuth blobs, session cookies,
  or full `rclone.conf` contents in a report. Replace them with
  `<redacted>` placeholders and describe where the value was used.
- Do not include a working credential even to demonstrate impact. A
  redacted reproduction with placeholder values is sufficient.
- Do not test against systems you do not own. Limit probing to local
  installations of this stack on hardware you control.
- If you discover an accidentally committed secret, treat it as a security
  report: notify privately, revoke and rotate the credential immediately,
  and do not quote the secret in follow-up messages.
- The full secret rules in [Contributing](CONTRIBUTING.md#secret-policy)
  apply to all security correspondence.

## Scope

In scope: the proxy (`server/torbox-proxy.py`), the control panel
(`control-panel/`), the supervisor and check scripts (`supervisor.ps1`,
`check_*.ps1`), and the launch and sync scripts in this repository.

Out of scope: upstream services (TorBox, Google Drive, Jellyfin itself),
reporter infrastructure, denial-of-service load testing against third-party
APIs, spam, phishing, social-engineering or physical attacks, and reports
based only on automated scanner output without a working local reproduction.

## What Happens Next

1. Maintainers triage severity and reproducibility according to the SLA
   timeline, and may ask for a minimal redacted reproduction.
2. A fix is prepared on a private branch, then merged to `main` and tagged
   as a new release. There are no backports to older tags.
3. Maintainers publish a brief advisory describing the affected versions,
   the fix, and upgrade steps. Reporters are credited only with permission.
4. Good-faith local research following this policy will not result in a ban.
   Please avoid privacy violations, data destruction, or service disruption
   while investigating.

For general bugs that are not vulnerabilities, use the public bug report
template instead; see [Support](SUPPORT.md).

## Related Documents

- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Support](SUPPORT.md)
