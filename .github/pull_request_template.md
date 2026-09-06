# Pull Request

## Linked Issue

Fixes #<!-- issue number --> / Refs #<!-- issue number -->

## What and Why

What does this change do, and why is it needed? Keep the summary to a few
sentences and explain the approach for anything non-obvious.

## Reproduction and verification

### Reproduction (for bug fixes)

- [ ] Linked issue includes minimal reproduction steps and frequency
      (`always` / `sometimes` / `once`).
- [ ] I reproduced the defect on the base commit before the fix
      (paste command + exit code or error excerpt).
- [ ] I re-ran the same steps after the fix and record the new result below.
- [ ] N/A — not a bug fix (new feature, docs, or refactor with no
      user-visible defect to reproduce).

```text
Base result:
Fixed result:
```

### Testing and verification checklist

Complete all applicable test items before requesting review.

#### Static analysis & compilation
- [ ] PowerShell syntax gate passes with zero errors:
      `Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object { $err = $null; [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err); if ($err) { throw $err } }`
- [ ] Python syntax compile passes for all Python files:
      `Get-ChildItem -Recurse -Filter *.py | ForEach-Object { python -m py_compile $_.FullName }`
- [ ] Secret scan passes: no hardcoded API keys, tokens, bearer headers,
      or cleartext passwords committed.

#### Test suite & harness
- [ ] Test harness passes: `pwsh -File tests/run-all-tests.ps1` (or individual
      test scripts under `tests/`).
- [ ] Contract tests pass: Panel static IDs and Proxy HTTP contracts verified.

#### Runtime & smoke tests (Windows)
- [ ] Tested on Windows (state PowerShell version and elevation level):
      PowerShell version: <!-- $PSVersionTable.PSVersion --> | Elevated: Yes / No
- [ ] Ordered start verified (`supervisor.ps1 -Mode Start` or Watchdog)
      with mount health confirmed before Jellyfin starts.
- [ ] Stack health status clean: `pwsh -File check_status.ps1 -AsJson` exits `0`.
- [ ] User views sanity check: `pwsh -File check_user_views.ps1 -AsJson` exits `0`.
- [ ] Endpoint smoke tests verified:
  - [ ] `Invoke-RestMethod http://127.0.0.1:8888/health` (Proxy)
  - [ ] `Invoke-RestMethod http://127.0.0.1:18080/health` (Control Panel)
  - [ ] `Invoke-RestMethod http://127.0.0.1:8096/System/Info/Public` (Jellyfin)
- [ ] End-to-end playback smoke test (if playback/launcher touched):
      Played 1 test media item via `potplayer://` protocol link, verified
      playlist generation and playback progress tracking tick.

#### Documentation & Hygiene
- [ ] Documentation updated (`README.md`, `RUNBOOK.md`, `ARCHITECTURE.md`,
      or `CONTROL_PANEL.md` as applicable).
- [ ] `docs/index.md` updated if any guide was added, renamed, or modified.
- [ ] No temporary files, debug dumps, `.pyc`, or log bundles staged.

### Verification output

Paste the command output (parser counts, test runner summary, `py_compile`
result, `check_status.ps1` output and exit code) below:

```text
<paste verification output here>
```

## Risk and rollback

- Risk: <!-- low / medium / high plus one-line reason -->
- Rollback: <!-- revert this PR / re-run installer / restore backup note
  from docs/reference.md -->

## Screenshots

If this change affects the control panel, playback flow, or any user-visible
output, attach before and after screenshots. If there is no visual change,
write `No visual change.`

| Before | After |
|---|---|
| <!-- image or `No visual change.` --> | <!-- image or `No visual change.` --> |
