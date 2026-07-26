# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog conventions.

## Unreleased

### Added

- Claude Code install instructions for user-level and project-level skill paths.
- Draft v0.2.0 release readiness brief and GitHub Release notes for owner approval before tagging.
- `scripts/check-whitespace.ps1`: empty-tree `git diff --check` entry point (backported from the 019 project) so the CI whitespace step checks every committed line instead of the always-clean working-tree diff.
- POSIX-shell variants (`pwsh` with forward-slash paths) of the validation commands in README and CONTRIBUTING for Git Bash, WSL, macOS, and Linux users.
- A shared binary-safe `scripts/private-marker-process.ps1` boundary and
  adversarial scanner fixtures for Windows native process lifecycle, POSIX
  process-group cleanup, exact standard streams, hostile Git environments,
  index/worktree drift, filesystem boundaries, and resource limits.

### Changed

- Clarify the diagnosis procedure: retry a transiently failing proof command once before classifying the result, and treat an environment-variable token source such as `GH_TOKEN` as a valid healthy state when the remaining proof checks pass.
- Upgrade the validation workflow to `actions/checkout@v5` (Node.js 24) to clear the Node.js 20 runner deprecation warning, and document why `windows-latest` is left unpinned.
- Private-marker scanner backports from the 2026-07-15 review ledger: the bearer-token rule now requires a token-shaped value (8+ token characters) after the header keyword instead of flagging any prose containing the bare keyword, and the email rule gained an allowlist for documentation placeholders (`example.*` domains, `noreply@`, `@users.noreply.github.com`); self-tests cover both false-positive fixes.
- Revise README Non-Goals so distribution (GitHub Releases, Codex and Claude Code installs, a future plugin or marketplace entry, packaging) is in scope, while credential-handling boundaries remain out of scope.
- Harden private-marker maintenance with a scan-wide deadline, bounded
  diagnostics, finite Git children built from a fixed minimal environment
  allowlist, index/worktree union coverage, exact start/end index verification,
  strict UTF-8 handling, and fail-closed repository/path checks while
  preserving this repository's bearer and email documentation allowlists.
- Make corrupt root/ancestor `.git` metadata fail with a fixed path-free
  `integrity: git-probe` diagnostic and exit code 2, with directory, gitfile,
  ancestor, missing-Git, and nested-exclusion regressions.
- Verify the Windows containment path with the first-call binary fixture and a
  native Git batch byte fixture, including BOM-less PowerShell 5.1 stdin and
  exact caller console-input encoding restoration.
- Make Windows direct-process lifecycle cleanup explicit: assignment/resume
  launch failures retain the original failure while requiring termination and
  a bounded PID-disappearance check, and successful parents close their Job
  before finite stream drain so descendants cannot retain inherited pipes.
  A failed Job close retains handle ownership through Stop/Dispose retries,
  terminates the Job as a fallback, and launch cleanup still directly
  terminates the suspended process when its assigned Job cannot be closed.
  Cleanup now attempts every stream and native resource, retains the primary
  failure in an aggregate, and clears native-handle ownership only after a
  successful close.
- Close the POSIX pre-session race by making both external `setsid` and the
  native fallback atomically report a strict ASCII direct-PID/launch-nonce
  record through a ready gate; require byte-exact provenance and verify the
  direct `PID == PGID` before releasing the target. Keep external invocation
  to the option-free operand form shared by BusyBox and util-linux.
- Apply one monotonic target deadline to environment preparation, launch,
  POSIX gating, and process polling. Fixed poll intervals are capped to the
  remaining budget, and Windows resume / POSIX release recheck that same clock
  immediately before target execution. Finite process-tree and stream cleanup
  grace stays separate.
- Exercise the forced native POSIX session gate with a byte-exact Unicode
  argument fixture, and self-test the AST first-call validator against
  deferred scriptblocks, nested calls, `.Invoke*()` execution,
  scope/module-qualified wrappers, target shadows, built-in aliases,
  `Get-Command` and function-provider references, class constructor/member
  execution, static initialization, reflective activation through direct,
  dynamic-Type, dynamic-member, case-variant, runtime-Type `::new()`, and
  `New-Object` forms. Source-order variable and alias state now treats
  conditional writes as unknown instead of executed safe overwrites,
  stored/generated ScriptBlock
  `.Invoke*()` and command-sink data flow, provider mutation, bootstrap
  variable replacement, expression/pipeline invocation, and other dynamic
  calls that cannot be proven safe.
- Validate scan-deadline input inside the scanner so invalid types or
  out-of-range values use one path-free `integrity: scan-deadline` diagnostic
  and exit code 2 instead of host-specific parameter-binding output. Runtime
  expiry and Git child timeouts bounded by the scan-wide remaining budget use
  the same fixed diagnostic whether the helper returns a timeout result or a
  POSIX gate-startup exception. The unchanged Git-specific 15-second timeout
  and startup failures before the scan deadline remain process-boundary
  failures.
- Retry the Windows PowerShell 5.1 hermetic environment probe once only when
  the first attempt is a fully contained, output-free timeout with no other
  failure signal. PowerShell 7 and POSIX hosts never retry. Its test-only
  30-second budget and the production 15-second Git timeout remain
  independently locked by readiness mutations.
- Collapse missing/failing process helpers, unhealthy bounded children, and
  Git isolation creation/cleanup failures into one fixed, path-free
  `integrity: process-boundary` diagnostic with exit code 2.
- Pin checkout to the reviewed v5 commit, add finite Windows and Ubuntu 24.04
  job timeouts, run the scanner self-test under PowerShell 7 and Windows
  PowerShell 5.1, and validate every workflow job/step/key against its owning
  job block. Quoted or flow-style extra jobs, quoted top-level keys, and
  active lines at unconsumed indentation are rejected.

### Fixed

- `scripts/scan-private-markers.ps1` and `scripts/test-scan-private-markers.ps1` no longer crash under Windows PowerShell 5.1 when git writes to stderr (for example when scanning a non-git path): native stderr combined with stream redirection and `$ErrorActionPreference = 'Stop'` became a terminating NativeCommandError, which broke the documented `powershell`-based self-test on hosts without `pwsh`. The git probe and the child-scanner invocation now scope `$ErrorActionPreference` to `Continue` and rely on exit codes.
- README install snippets no longer call `exit 1`, which terminated the user's interactive shell when a copy-pasted install block hit an existing target; the guard now prints the message and skips the copy instead.

## 0.1.0 - 2026-06-06

### Added

- Initial Windows GitHub authentication false-negative diagnosis skill.
- Synthetic checklist, final report template, and issue-safe summary examples.
- Private-marker scan for common secret prefixes, private paths, and non-allowlisted GitHub repository URLs.
- OSS readiness validation script for required public project files and skill frontmatter.
- Private-marker scan self-test and local marker support through `.private-markers.local` or an environment variable.
- GitHub Actions workflow for validation, private-marker scanning, and whitespace checks.
- Issue and pull request templates with secret-safe reporting guidance.
- Contributor, security, code of conduct, editor, and Git attribute documentation.
