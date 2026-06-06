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

## Response Expectations

Maintainers should acknowledge actionable security reports when available, remove or redact unsafe public material, and prefer guidance that reduces credential exposure risk. If real exposure is possible, rotate the affected secret outside this public repository and document only the remediation status.
