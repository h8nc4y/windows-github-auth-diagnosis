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

Scanner and workflow changes must preserve the bounded process helper, the
PowerShell 7 / Windows PowerShell 5.1 / Ubuntu / macOS execution matrix, exact
pinned checkout revision, finite job timeouts, and fail-closed Git/index/path
boundary. On Windows, preserve suspended direct launch, Job assignment before
resume, bounded launch-failure cleanup, and parent-first Job close before
stream drain. A failed Job close must retain handle ownership for bounded
Stop/Dispose retries and process-tree termination fallback. Process-helper and
Git-isolation failures must emit only the fixed path-free integrity diagnostic.
The first-call AST gate must reject target shadows, aliases, module-qualified
lookup, function-provider references, stored/generated ScriptBlock
`.Invoke*()` calls and command sinks, provider writes, process-boundary
bootstrap replacement, invoked class members/static initialization, and
expression or pipeline indirection before the binary fixture. Invalid
scan-deadline input must keep the fixed path-free exit-2 contract. Workflow
validation must reject
extra triggers, permissions,
jobs, quoted/flow aliases of those mappings, and active lines outside the
canonical indentation. Keep fixtures synthetic and verify native cleanup
failures without printing environment values.
Exact Git-root validation must require Git's strict inside-work-tree `true`
record and empty relative prefix rather than host path string identity; this
keeps subdirectories and metadata roots rejected without treating macOS system
aliases as different physical roots.

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

The GitHub workflow repeats these checks on `windows-latest`, Ubuntu 24.04,
and `macos-latest`. On Windows it also runs the scanner self-test with Windows
PowerShell 5.1; macOS exercises the native `setsid(2)` fallback.
Before committing, run `git diff --check`; the CI whitespace script compares
the committed tree with Git's empty tree so a clean checkout is not a vacuous
pass.

## Pull Request Expectations

- Explain the problem and the chosen fix.
- Include validation results.
- Call out any remaining unknowns.
- Keep security-sensitive findings summarized by file, line, finding type, and remediation only. Never repeat the matched secret value.

## Maintainer Notes

Prefer documentation and validation that prevent future unsafe agent behavior. Avoid adding broad dependencies or network-backed checks unless they are clearly necessary for public safety.
