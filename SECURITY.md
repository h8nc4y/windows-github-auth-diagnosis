# Security Policy

This repository documents a credential-sensitive workflow. Security reports are welcome, but public reports must stay sanitized.

## Supported Versions

The `main` branch is the supported version until tagged releases exist.

## Reporting A Vulnerability

Use GitHub private vulnerability reporting for:

- A real secret or credential accidentally committed to this repository.
- Guidance that could cause agents to print tokens, request OAuth credentials unnecessarily, or leak private logs.
- A validation gap that allows unsafe public examples.

Do not open a public issue containing tokens, auth cookies, private keys, OAuth credentials, customer data, raw credential logs, or screenshots of credential stores.

## Public Issue Safety

Public issues may include:

- Command class, such as `gh auth status` or `git push`.
- Error class, such as HTTP 401 or `SEC_E_NO_CREDENTIALS`.
- Sanitized classification and safe next step.
- Placeholder repository and login values.

Public issues must not include:

- Token values or token display command output.
- Raw auth JSON that exposes account details you do not intend to publish.
- Private repository names, internal paths, hostnames, customer data, or credential screenshots.

## Scanner Coverage

The private-marker scanner (`scripts/scan-private-markers.ps1`) is a
best-effort detection safety net, not a guarantee. It scans the union of
regular stage-0 Git index blobs and tracked worktree text files for a curated
set of secret prefixes (GitHub, OpenAI, AWS, GCP, Slack, Stripe, PEM key
blocks, and similar) plus configured local markers. Matched values are always
redacted.

The scanner fails closed when its Git process boundary, index snapshot,
explicit repository root, file type, symlink/reparse state, stable read, UTF-8
decode, or resource limit cannot be verified. Git children run through a
bounded binary-safe helper with a fixed minimal environment allowlist,
isolated Git configuration, and process-tree cleanup. Non-Git credential,
marker, loader, and agent variables from the parent are not inherited. On
Windows, a direct child starts suspended and resumes only after
kill-on-close Job assignment; assignment/resume failures require termination
plus a bounded process-table wait, and a normally exited parent has its Job
closed before finite stream draining. Failed Job closure retains ownership for
bounded Stop/Dispose retries and uses Job termination as a process-tree
fallback; assigned-launch cleanup separately retains direct-process
termination. On POSIX, the child reports its session-leader PID after `setsid`;
the parent verifies that PID as the process-group ID before target release.
Missing/failing helpers, unhealthy process results, and Git
isolation setup/cleanup failures emit only the fixed, path-free
`integrity: process-boundary` diagnostic with exit code 2. Non-Git fallback is
permitted only when
no `.git` marker exists in the explicit root or its ancestors; nested `.git`
entries remain excluded from content scanning. Ambiguous root or ancestor
metadata returns only the fixed, path-free `integrity: git-probe` diagnostic
with exit code 2.

Entry, byte, line, match, finding, diagnostic-output, child-process, and
scan-wide deadline limits keep the check finite. These integrity controls do
not detect every possible secret format and are no substitute for keeping
real credentials out of the repository. Treat a passing scan as "no known
marker found," not "definitely safe."

Invalid scan-deadline values fail with the fixed, path-free
`integrity: scan-deadline` diagnostic and exit code 2. Do not expose
parameter-binding diagnostics or local paths when validating this boundary.

## Response Expectations

Maintainers should acknowledge actionable security reports when available, remove or redact unsafe public material, and prefer guidance that reduces credential exposure risk. If real exposure is possible, rotate the affected secret outside this public repository and document only the remediation status.
