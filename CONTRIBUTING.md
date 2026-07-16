# Contributing

Thanks for improving this skill. This repository is intentionally small: changes should keep the diagnosis safer, clearer, or easier to verify.

## Before You Start

- Read [SKILL.md](SKILL.md) and the examples under [examples](examples).
- Do not paste tokens, credentials, auth cookies, private keys, OAuth codes, raw credential logs, screenshots of credential stores, customer data, or private repository data into issues, pull requests, commits, or tests.
- Use synthetic placeholders such as `<repo>`, `<expected-login>`, and `<redacted>` for examples.
- Put personal or organization-specific scan markers in an untracked `.private-markers.local` file, not in repository source.

## Development Workflow

1. Create a focused branch.
2. Make the smallest coherent change.
3. Update examples or README text when user-facing guidance changes.
4. Add or adjust validation when a safety rule should be machine-checkable.
5. Run the validation commands before opening a pull request.

## Validation

From the repository root, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
git diff --check
```

If `pwsh` is available, it is also acceptable for the PowerShell scripts:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
```

On Git Bash, WSL, macOS, Linux, or any other POSIX shell with PowerShell 7
(`pwsh`) installed, use forward slashes:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

## Pull Request Expectations

- Explain the problem and the chosen fix.
- Include validation results.
- Call out any remaining unknowns.
- Keep security-sensitive findings summarized by file, line, finding type, and remediation only. Never repeat the matched secret value.

## Maintainer Notes

Prefer documentation and validation that prevent future unsafe agent behavior. Avoid adding broad dependencies or network-backed checks unless they are clearly necessary for public safety.
