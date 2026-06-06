# Final Report Template

Use this template after a sanitized diagnosis. Keep it short and do not paste raw credential output.

```text
YYYY/MM/DD HH:MM:SS

Completed checks:
- Remote wiring: <origin-present | NO_ORIGIN | misconfigured>
- Credential helper: <present | absent | mixed | not checked>
- Keyring-capable gh auth status: <success | failed | blocked>
- Keyring-capable gh api user: <expected login returned | failed | blocked>
- Keyring-capable git ls-remote: <ref returned | empty remote | failed | blocked>

Classification:
<sandbox false negative | NO_ORIGIN | permission/scope issue | branch protection | network issue | approval-layer blocker | unresolved>

Safe next step:
<next command or action, without secrets>

Unknowns:
<items not checked>

Residual risk:
<remaining auth, permission, or network uncertainty>
```

## Redaction Rules

- Summarize error classes instead of copying full logs.
- Never include tokens, auth cookies, private keys, or OAuth credentials.
- Avoid real repository names in public issues unless the repository is already public and relevant.
- If a secret might have been exposed, report the file, line, finding type, and remediation only. Do not repeat the matched value.
