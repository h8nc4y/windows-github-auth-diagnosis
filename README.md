# windows-github-auth-diagnosis

[![Validate](https://github.com/h8nc4y/windows-github-auth-diagnosis/actions/workflows/validate.yml/badge.svg)](https://github.com/h8nc4y/windows-github-auth-diagnosis/actions/workflows/validate.yml)

A Codex-style skill for diagnosing Windows GitHub authentication false negatives caused by agent or tool sandboxes that cannot read the Windows keyring.

## What It Solves

On Windows, a sandboxed agent command can make GitHub authentication look broken even when GitHub CLI and Git are correctly authenticated in a normal terminal. This skill gives agents a conservative triage path so they do not immediately ask users to run `gh auth login`, enter OAuth, paste tokens, or reset credentials.

## Who It Is For

- Codex users and maintainers working on Windows.
- Agent developers whose tools run `gh` or `git` inside a restricted sandbox.
- Reviewers who need safe public summaries of GitHub authentication problems without exposing tokens, credentials, or real logs.

## Install

Clone the repository:

```bash
git clone https://github.com/h8nc4y/windows-github-auth-diagnosis.git
cd windows-github-auth-diagnosis
```

Manual Codex-style skill install on shells with POSIX syntax:

```bash
dest="${HOME}/.agents/skills/windows-github-auth-diagnosis"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
  exit 1
fi
mkdir -p "$dest"
cp SKILL.md "$dest/SKILL.md"
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

- No GitHub Release creation.
- No Marketplace registration.
- No package publishing.
- No credential storage or token management.
- No advice to rotate or reset credentials unless a real exposure or proven credential failure exists.

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

Also run a skill frontmatter validation tool when available, and run Git whitespace checks before publishing:

```bash
git diff --check
```

The GitHub Actions workflow runs the same local validation, scan self-test, private-marker scan, and whitespace check on pull requests and pushes to `main`.

## Contributing

Contributions are welcome when they make the diagnosis safer, clearer, or easier to verify. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

Keep all examples synthetic. Do not include tokens, credentials, auth cookies, private keys, OAuth codes, raw credential logs, customer data, private repository names, internal paths, or screenshots of credential stores.

For local-only private markers, create an untracked `.private-markers.local` file with one literal marker per line, or set `WINDOWS_GITHUB_AUTH_DIAGNOSIS_PRIVATE_MARKERS` with newline-separated markers. The scanner reads these values but does not print the matched marker.

## Security

This repository is about credential-sensitive behavior. If you find a vulnerability, unsafe guidance, or accidental secret exposure, follow [SECURITY.md](SECURITY.md) and use private reporting for sensitive details.

Public issues should summarize command classes, error classes, classification, and safe next steps only.

## License

MIT. See [LICENSE](LICENSE).
