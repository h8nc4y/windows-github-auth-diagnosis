# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog conventions.

## Unreleased

### Added

- Claude Code install instructions for user-level and project-level skill paths.
- Draft v0.2.0 release readiness brief and GitHub Release notes for owner approval before tagging.
- `scripts/check-whitespace.ps1`: empty-tree `git diff --check` entry point (backported from the 019 project) so the CI whitespace step checks every committed line instead of the always-clean working-tree diff.
- POSIX-shell variants (`pwsh` with forward-slash paths) of the validation commands in README and CONTRIBUTING for Git Bash, WSL, macOS, and Linux users.

### Changed

- Clarify the diagnosis procedure: retry a transiently failing proof command once before classifying the result, and treat an environment-variable token source such as `GH_TOKEN` as a valid healthy state when the remaining proof checks pass.
- Upgrade the validation workflow to `actions/checkout@v5` (Node.js 24) to clear the Node.js 20 runner deprecation warning, and document why `windows-latest` is left unpinned.
- Private-marker scanner backports from the 2026-07-15 review ledger: the bearer-token rule now requires a token-shaped value (8+ token characters) after the header keyword instead of flagging any prose containing the bare keyword, and the email rule gained an allowlist for documentation placeholders (`example.*` domains, `noreply@`, `@users.noreply.github.com`); self-tests cover both false-positive fixes.
- Revise README Non-Goals so distribution (GitHub Releases, Codex and Claude Code installs, a future plugin or marketplace entry, packaging) is in scope, while credential-handling boundaries remain out of scope.

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
