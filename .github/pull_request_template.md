# Pull Request

## Linked Issue

Fixes #<!-- issue number --> / Refs #<!-- issue number -->

## What and Why

What does this change do, and why is it needed? Keep the summary to a few
sentences and explain the approach for anything non-obvious.

## Verification Checklist

- [ ] PowerShell parser gate passes with zero errors
- [ ] `python -m py_compile` passes for every Python file touched
- [ ] Tested on Windows (state PowerShell edition and elevation used)
- [ ] No secrets, tokens, or credentials in code, comments, or logs
- [ ] Documentation updated (`README.md`, `RUNBOOK.md`, or `ARCHITECTURE.md`
      as applicable)

Paste the relevant command output (parser counts, `py_compile` result,
`check_status.ps1` exit code) below:

```text
<paste verification output here>
```

## Screenshots

If this change affects the control panel, playback flow, or any user-visible
output, attach before and after screenshots. If there is no visual change,
write `No visual change.`

| Before | After |
|---|---|
| <!-- image or `No visual change.` --> | <!-- image or `No visual change.` --> |
