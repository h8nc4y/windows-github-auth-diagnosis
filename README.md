# windows-github-auth-diagnosis

[![Validate](https://github.com/h8nc4y/windows-github-auth-diagnosis/actions/workflows/validate.yml/badge.svg)](https://github.com/h8nc4y/windows-github-auth-diagnosis/actions/workflows/validate.yml)

An agent skill for Codex and Claude Code that diagnoses Windows GitHub authentication false negatives caused by agent or tool sandboxes that cannot read the Windows keyring.

## What It Solves

On Windows, a sandboxed agent command can make GitHub authentication look broken even when GitHub CLI and Git are correctly authenticated in a normal terminal. This skill gives agents a conservative triage path so they do not immediately ask users to run `gh auth login`, enter OAuth, paste tokens, or reset credentials.

## Who It Is For

- Codex and Claude Code users and maintainers working on Windows.
- Agent developers whose tools run `gh` or `git` inside a restricted sandbox.
- Reviewers who need safe public summaries of GitHub authentication problems without exposing tokens, credentials, or real logs.

## Install

Clone the repository:

```bash
git clone https://github.com/h8nc4y/windows-github-auth-diagnosis.git
cd windows-github-auth-diagnosis
```

### Codex (agent skills)

Manual Codex-style skill install on shells with POSIX syntax:

```bash
dest="${HOME}/.agents/skills/windows-github-auth-diagnosis"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Manual Codex-style skill install from PowerShell:

```powershell
$dest = Join-Path $HOME '.agents\skills\windows-github-auth-diagnosis'
if (Test-Path -LiteralPath $dest) {
  throw "Install target already exists: $dest"
}
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
```

The guard is intentional: do not overwrite an existing installed skill without reviewing the local copy first.

### Claude Code

The same `SKILL.md` works in Claude Code; its `name` and `description` frontmatter are compatible, so no edits are needed. Claude Code auto-invokes the skill when a task matches the description.

Install for your user account on shells with POSIX syntax:

```bash
dest="${HOME}/.claude/skills/windows-github-auth-diagnosis"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Install for your user account from PowerShell:

```powershell
$dest = Join-Path $HOME '.claude\skills\windows-github-auth-diagnosis'
if (Test-Path -LiteralPath $dest) {
  throw "Install target already exists: $dest"
}
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
```

To scope the skill to a single project instead, copy `SKILL.md` to `.claude/skills/windows-github-auth-diagnosis/SKILL.md` inside that project's repository.

## Manual Use

Use the skill when a sandboxed GitHub command reports one of these symptoms:

- HTTP 401 or Bad credentials from `gh auth status` or `gh api`.
- An invalid default token reported by `gh`.
- `SEC_E_NO_CREDENTIALS` from Git over HTTPS.
- A push, fetch, pull, or `ls-remote` failure that appears to be credential-related only inside the sandbox.

Follow the procedure in [SKILL.md](SKILL.md): confirm remote wiring, check credential helpers, then run keyring-capable proof commands without printing tokens.

## Synthetic Examples

- [Diagnosis checklist](examples/diagnosis-checklist.md)
- [Final report template](examples/final-report-template.md)
- [Issue-safe summary](examples/issue-safe-summary.md)

The examples use placeholders only. Do not replace them with secret values, raw auth logs, or customer data in public issues.

## Distribution Planning

- [Release v0.2.0 brief](docs/release-v0.2.0-brief.md)
- [Release v0.2.0 notes draft](docs/release-v0.2.0-notes-draft.md)
- [Requirements reassessment 2026-07](docs/requirements-reassessment-2026-07.md)
- [Distribution channel research](docs/distribution-channel-research.md)
- [Claude Code plugin marketplace evaluation](docs/claude-plugin-marketplace-evaluation.md)
- [skills.sh channel evaluation](docs/skills-sh-channel-evaluation.md)

Do not publish releases, packages, plugin marketplaces, or external smoke tests until the version, target commit, public text, and channel-specific safety gates are confirmed.

## Safety Notes

- Never print token values.
- Do not use token display commands as part of diagnosis.
- Do not enter OAuth or token-input loops based only on sandbox failures.
- Do not post real authentication logs, credentials, cookies, screenshots, or customer data in public issues.
- Treat each environment's cost, secret, OAuth, and data-handling policy as authoritative.

## Limitations

- This skill does not repair expired, revoked, or missing GitHub credentials.
- It does not bypass branch protection, missing repository permission, missing token scopes, network outages, or agent approval-layer blocks.
- It assumes a keyring-capable proof path exists. If every available path is sandboxed or blocked, report that limitation explicitly.
- It focuses on GitHub CLI and Git over HTTPS on Windows. SSH-specific failures need separate diagnosis.

## Non-Goals

These are permanent safety boundaries and stay out of scope:

- No credential storage or token management.
- No advice to rotate or reset credentials unless a real exposure or proven credential failure exists.

Distribution is now in scope. Publishing GitHub Releases, offering Codex and Claude Code install paths, a future plugin or marketplace entry, and packaging for distribution are explicitly allowed, provided the safety boundaries above and the [Safety Notes](#safety-notes) are preserved.

## Validation

Run the full local validation from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
```

If `pwsh` is available, the same checks can be run with:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
```

On Git Bash, WSL, macOS, Linux, or any other POSIX shell with PowerShell 7
(`pwsh`) installed, use forward slashes (backslash paths are mangled by POSIX
word splitting):

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

Also run a skill frontmatter validation tool when available, and run Git whitespace checks before publishing:

```bash
git diff --check
```

The GitHub Actions workflow runs the readiness check, scanner self-test,
private-marker scan, and whitespace check on pull requests and pushes to
`main`. Windows runs the scanner self-test under both PowerShell 7 and Windows
PowerShell 5.1; a separate Ubuntu 24.04 job verifies the PowerShell 7 / POSIX
process path. Both jobs have finite timeouts, and `actions/checkout` is pinned
to a reviewed commit.

The scanner uses `scripts/private-marker-process.ps1` as a bounded,
binary-safe child-process boundary. It scans the union of regular stage-0
index blobs and tracked worktree files, rejects unsafe Git/index/path state,
and fails closed when a repository boundary cannot be verified. Entry, byte,
line, finding, diagnostic-output, child-process, and scan-wide limits prevent
unbounded maintenance checks. On Windows, the direct target starts suspended,
enters a kill-on-close Job before resume, and is removed with a bounded wait
when assignment or resume fails. After the direct parent exits, the Job closes
before finite stream draining so a descendant cannot keep inherited pipes
alive. Job-close failures retain the owned handle across bounded Stop/Dispose
retries and terminate the contained Job as a fallback; launch cleanup also
retains direct-process termination when an assigned Job cannot be closed.
Git children receive a fixed minimal environment allowlist rather than the
parent process environment, so unrelated credential, marker, loader, and agent
variables do not cross the process boundary.
Missing or failing helpers and Git-isolation setup/cleanup failures return only
the fixed, path-free `integrity: process-boundary` diagnostic with exit code 2.
Invalid scan-deadline input likewise returns only the fixed, path-free
`integrity: scan-deadline` diagnostic with exit code 2.
POSIX hosts use a separately bounded process-group boundary: the child reports
its session-leader PID only after `setsid`, and the parent verifies that PID as
the process-group ID before releasing the target. These
integrity controls make failure safer; they do not turn the curated marker
rules into proof that a repository has no secrets.

## Contributing

Contributions are welcome when they make the diagnosis safer, clearer, or easier to verify. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

Keep all examples synthetic. Do not include tokens, credentials, auth cookies, private keys, OAuth codes, raw credential logs, customer data, private repository names, internal paths, or screenshots of credential stores.

For local-only private markers, create an untracked `.private-markers.local` file with one literal marker per line, or set `WINDOWS_GITHUB_AUTH_DIAGNOSIS_PRIVATE_MARKERS` with newline-separated markers. The scanner reads these values but does not print the matched marker.

## Security

This repository is about credential-sensitive behavior. If you find a vulnerability, unsafe guidance, or accidental secret exposure, follow [SECURITY.md](SECURITY.md) and use private reporting for sensitive details.

Public issues should summarize command classes, error classes, classification, and safe next steps only.

## License

MIT. See [LICENSE](LICENSE).
