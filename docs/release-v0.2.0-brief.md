# v0.2.0 release readiness brief

Status: draft for owner approval. This file is not an approval record, tag, GitHub Release, marketplace publication, or distribution action.

## Purpose

Prepare the first post-`0.1.0` release decision for `windows-github-auth-diagnosis` without performing any publication step.

The release remains blocked until the owner confirms the version number, target commit, publication timing, and release notes text.

## Proposed Version And Tag

- Proposed version: `v0.2.0`
- Proposed tag type: annotated Git tag
- Tag target: re-check `origin/main` immediately before release and use the approved `main` tip after all release-scoped pull requests are merged. Do not rely on any baseline commit recorded earlier in this document's history.

## Release Scope Since 0.1.0

- Added Claude Code install instructions while preserving the existing Codex-style skill path.
- Revised README Non-Goals so distribution is in scope, while credential storage and unsafe auth repair advice stay out of scope.
- Updated GitHub Actions validation to the immutable `actions/checkout`
  v7.0.1 commit with checkout credential persistence disabled, retained
  bounded `windows-latest` / Ubuntu jobs, and added a bounded standard
  `macos-latest` job for the native `setsid(2)` fallback. The moving labels
  remain intentionally unpinned because this repository depends only on
  `pwsh`, `git`, and native process primitives.
- Hardened private-marker scanning with additional synthetic secret-prefix
  coverage, redaction checks, and Git-semantic exact-root validation that
  tolerates macOS system aliases while rejecting subdirectories and Git
  metadata roots.
- Clarified the diagnosis procedure: retry a transiently failing proof command once before classifying, and recognize an environment-variable token source as a valid healthy state when the remaining proof checks pass.
- Recorded advisory review disposition so resolved local advisory docs are not reintroduced as active implementation tasks.

## Draft Release Notes

Use `docs/release-v0.2.0-notes-draft.md` as the source text for GitHub Release notes after owner review.

Before publishing, verify that the notes still match the final target commit and that no private local path, token, credential-bearing log, screenshot, or real customer data is present.

## Required Local Verification Before Tagging

Run from the repository root immediately before tagging:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
git diff --check
gitleaks detect --source . --redact --no-banner
```

Also confirm the GitHub `Validate` workflow is green for the final release commit.

## Human Approval Checklist

Do not tag or create a GitHub Release until all items are explicitly approved:

- Owner confirms `v0.2.0` as the release version.
- Owner confirms the exact target commit after this preparation branch is merged or rejected.
- Owner confirms the publication timing.
- Owner approves the final GitHub Release notes text.
- Owner confirms no marketplace/plugin publication is bundled into this GitHub Release unless separately scoped.

## Publication Commands After Approval Only

These commands are examples for the approved release moment; do not run them as part of this preparation task.

```powershell
git fetch origin --prune
git switch main
git pull --ff-only origin main
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
gh release create v0.2.0 --title "v0.2.0" --notes-file docs\release-v0.2.0-notes-draft.md
```

If the final release commit differs from the current checked-out `main`, tag the explicitly approved commit instead of relying on implicit `HEAD`.

## Out Of Scope

- Creating or pushing the tag.
- Creating, drafting, or publishing a GitHub Release.
- Publishing a Claude Code plugin, marketplace entry, package, or installer.
- Running OAuth/token entry, credential repair, or any command that prints secrets.
- Collecting real customer data, credential logs, screenshots, cookies, private repository names, or local absolute paths for release notes.
