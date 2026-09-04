# Tests for jellyfin-torbox-potplayer-stack.

Run the full suite (Windows, pwsh 5.1+ or pwsh 7):

```powershell
pwsh -File tests/run-tests.ps1
```

Add `-Verbose` for per-test timing. Exit code is `0` when everything
passes, `1` otherwise. Missing runtimes (python/node) skip gracefully.

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
