# Issue-Safe Summary

Use this for public issue comments when a sandboxed Windows GitHub command appears to fail authentication.

```text
A sandboxed Windows agent command reported a GitHub authentication error, but this may be a keyring visibility false negative.

Observed symptom class:
- <HTTP 401 | Bad credentials | invalid default token | SEC_E_NO_CREDENTIALS | missing credentials>

Sanitized checks performed:
- Remote wiring checked: <yes | no>
- Credential helper checked: <yes | no>
- Keyring-capable gh auth proof: <success | failed | blocked | not available>
- Keyring-capable git remote proof: <success | failed | empty remote | blocked | not available>

Current classification:
- <sandbox false negative | remote misconfiguration | permission/scope issue | branch protection | network issue | approval-layer blocker | unresolved>

Safe next step:
- <continue with keyring-capable path | fix remote | request repo permission | retry after network recovery | resolve approval-layer block | investigate further>
```

## Do Not Post

- Raw `gh auth` JSON if it contains environment-specific account details you do not intend to publish.
- Token values or token display command output.
- Auth cookies, OAuth credentials, private keys, or customer data.
- Screenshots of credential stores or browser sessions.
- Real logs that contain hostnames, private repository names, internal paths, or personal data.
