# v0.2.0 release notes draft

Status: draft. Review and approve before using this text in a GitHub Release.

## Summary

`v0.2.0` prepares `windows-github-auth-diagnosis` for broader Codex and Claude Code use while preserving the original safety boundary: sandbox-only GitHub authentication failures must not trigger premature OAuth/token entry, credential resets, or public exposure of sensitive logs.

## Added

- Claude Code install instructions for both user-level and project-level skill placement.
- Release-readiness documentation for the first post-`0.1.0` GitHub Release.

## Changed

- The diagnosis procedure now retries a transiently failing proof command once before classifying the result, so temporary network or GitHub availability problems are not misclassified.
- The healthy-state criteria now recognize an environment-variable token source such as `GH_TOKEN` or `GITHUB_TOKEN` as valid when the remaining proof checks pass, because it does not depend on keyring visibility.
- README distribution guidance now allows GitHub Releases, Codex/Claude Code install paths, future plugin or marketplace packaging, and other distribution work when the safety boundaries are preserved.
- GitHub Actions validation now uses `actions/checkout@v5` and bounded Windows,
  Ubuntu, and standard macOS jobs. `windows-latest` and `macos-latest` remain
  intentionally unpinned because the workflow only depends on `pwsh`, `git`,
  and native process primitives; macOS verifies the native `setsid(2)`
  fallback used when no external `setsid` executable is available.
- Exact Git worktree-root validation now requires Git's strict
  inside-work-tree `true` record and empty relative prefix, rejecting
  subdirectories and Git metadata roots without treating macOS system aliases
  for the same physical temporary directory as different roots.
- Handoff and backlog state now reflect that T-003, scanner hardening, and advisory disposition have been merged.

## Security And Safety

- Private-marker scanning has broader synthetic coverage for common secret prefixes and path-like private markers.
- Scanner tests preserve redaction expectations so raw marker values are not replayed in findings.
- Public documentation continues to prohibit token printing, OAuth entry loops, credential-bearing logs, screenshots of credential stores, customer data, and private repository details.

## Validation Before Release

The final release commit should pass:

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1`
- `git diff --check`
- `gitleaks detect --source . --redact --no-banner`
- GitHub Actions `Validate` workflow on the final commit

## Known Limits

- The skill diagnoses Windows GitHub authentication false negatives; it does not repair expired, revoked, or missing credentials.
- It does not bypass branch protection, missing repository permissions, missing token scopes, network outages, or agent approval-layer blocks.
- Marketplace/plugin publication remains a separate task and is not included in this release notes draft unless separately approved.
