# Tests for jellyfin-torbox-potplayer-stack.

Run the full suite (Windows, pwsh 5.1+ or pwsh 7):

```powershell
pwsh -File tests/run-tests.ps1
```

Add `-Verbose` for per-test timing. Exit code is `0` when everything
passes, `1` otherwise. Missing runtimes (python/node) skip gracefully.

## Prerequisites

- Windows with `pwsh` (7 preferred, 5.1 works) in `PATH`.
- Optional: `python` (for `test-py-*.py`) and `node` (for `test-js-*.js`).
  When absent, those tests report `SKIP`, never `FAIL`.

## Running tests

```powershell
# Full suite, quiet (failures still print)
pwsh -File tests/run-tests.ps1

# Full suite with per-test timing
pwsh -File tests/run-tests.ps1 -Verbose

# Single test (same exit-code contract: 0 pass, non-zero fail)
pwsh -File tests/test-no-absolute-paths.ps1
pwsh -File tests/test-no-secrets.ps1
python tests/test-proxy-contracts.py
node tests/test-js-syntax.js
```

## What is covered

| Test | What it proves |
|---|---|
| `test-ps-parse.ps1` | Every `.ps1` parses with zero syntax errors |
| `test-py-compile.py` | Every `.py` compiles |
| `test-js-syntax.js` | Every `.js` passes `node --check` |
| `test-no-secrets.ps1` | No hardcoded keys/tokens in code files |
| `test-no-absolute-paths.ps1` | Public docs stay portable (examples in fences only) |
| `test-panel-contracts.ps1` | Every DOM id the panel JS uses exists in `index.html` |
| `test-proxy-contracts.py` | Proxy exposes `/mylist /metrics /ready /health /torbox/`, token bucket + env key |
| `test-gdrive-modes.ps1` | GDrive `Test` PASS + `Status` exit 0 |
| `test-tracker-dryrun.ps1` | Tracker `-DryRun` prints `RESUME=` first (launcher contract) |

## Adding a test

1. Create `tests/test-<area>.<ps1|py|js>`.
2. Print `PASS`-style lines, exit `0` on success, non-zero on failure.
3. No network calls (localhost only), no writes outside `$env:TEMP`.
4. The runner picks it up automatically — no registration needed.

## Portable-path rule

`test-no-absolute-paths.ps1` keeps public docs portable: outside
code fences, only documented install roots are allowed
(e.g., `F:\Jellyfin`, `F:\Media`, `F:\TorboxMedia`, `E:\MediaServer`, `T:\`, `G:\`, `R:\`).
Put machine-specific examples inside fenced code blocks or remove them:

```text
# Example machine-specific path inside code fence:
C:\Users\Username\AppData\Local\...
```

Forensic `GLOBAL_FIX_*` logs and `CONTROL_PANEL.md` are frozen history
and skipped.

## Latest Test Run Results

```text
> pwsh -File tests/test-no-absolute-paths.ps1
no-absolute-paths: 33 md files checked, 0 violations

> pwsh -File tests/test-no-secrets.ps1
no-secrets: 0 code files checked, 0 violations
```

## Line endings

Windows scripts (`.ps1`, `.bat`, `.cmd`) stay `CRLF`; shell, Python,
JS, Markdown, YAML, and JSON stay `LF` (see `.gitattributes` and
`.editorconfig`). Keep that policy when adding tests.
