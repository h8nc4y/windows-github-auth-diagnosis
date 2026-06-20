# Changelog

All notable changes to this project are documented in this file.

The format follows Keep a Changelog conventions.

## Unreleased

### Added

- Claude Code install instructions for user-level and project-level skill paths.

### Changed

- Upgrade the validation workflow to `actions/checkout@v5` (Node.js 24) to clear the Node.js 20 runner deprecation warning, and document why `windows-latest` is left unpinned.
- Revise README Non-Goals so distribution (GitHub Releases, Codex and Claude Code installs, a future plugin or marketplace entry, packaging) is in scope, while credential-handling boundaries remain out of scope.

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
