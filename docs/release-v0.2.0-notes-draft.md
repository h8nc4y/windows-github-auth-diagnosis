# v0.2.0 release notes draft

Status: draft. Review and approve before using this text in a GitHub Release.

## Summary

`v0.2.0` prepares `windows-github-auth-diagnosis` for broader Codex and Claude Code use while preserving the original safety boundary: sandbox-only GitHub authentication failures must not trigger premature OAuth/token entry, credential resets, or public exposure of sensitive logs.

## Added

- Claude Code install instructions for both user-level and project-level skill placement.
- Release-readiness documentation for the first post-`0.1.0` GitHub Release.

## Changed

- README distribution guidance now allows GitHub Releases, Codex/Claude Code install paths, future plugin or marketplace packaging, and other distribution work when the safety boundaries are preserved.
- GitHub Actions validation now uses `actions/checkout@v5`; `windows-latest` remains intentionally unpinned because the workflow only depends on `pwsh` and `git`.
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