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

### Verification checklist

- [ ] PowerShell parser gate passes with zero errors
- [ ] `python -m py_compile` passes for every Python file touched
- [ ] Tested on Windows (state PowerShell edition and elevation used)
- [ ] Ordered start verified (`supervisor.ps1 -Mode Start` or Status)
      with mounts healthy before Jellyfin, where applicable
- [ ] `check_status.ps1` exit code recorded (`0` / `1` / `2`)
- [ ] No secrets, tokens, or credentials in code, comments, or logs
- [ ] Documentation updated (`README.md`, `RUNBOOK.md`, or `ARCHITECTURE.md`
      as applicable; `docs/index.md` link updated when a guide is added,
      renamed, or removed)

Paste the relevant command output (parser counts, `py_compile` result,
`check_status.ps1` exit code) below:

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
