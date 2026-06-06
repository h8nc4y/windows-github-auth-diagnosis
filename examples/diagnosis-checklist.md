# Diagnosis Checklist

Use this checklist for a synthetic or sanitized Windows GitHub authentication diagnosis. Replace placeholders with non-secret values only.

## Inputs

- Repository path placeholder: `<repo>`
- Expected GitHub login placeholder: `<expected-login>`
- Failing command class: `gh auth status`, `gh api`, `git fetch`, `git push`, or `git ls-remote`
- Sandbox symptom: HTTP 401, Bad credentials, invalid default token, missing credentials, or `SEC_E_NO_CREDENTIALS`

## Checks

1. Confirm remote wiring.

   ```bash
   git -C <repo> remote -v
   ```

   - [ ] `origin` exists.
   - [ ] `origin` points to the expected repository.
   - [ ] If `origin` is missing, classify as `NO_ORIGIN`.

2. Check credential helper configuration.

   ```bash
   git -C <repo> config --get-all credential.helper
   git -C <repo> config --get-all credential.https://github.com.helper
   ```

   - [ ] Helpers are present or the absence is understood.
   - [ ] No secret values are printed or copied.

3. Run keyring-capable proof commands.

   ```bash
   gh auth status -h github.com --json hosts
   gh api user --jq .login
   GIT_TERMINAL_PROMPT=0 git -C <repo> ls-remote origin HEAD
   ```

   - [ ] `gh auth status` reports `state=success`.
   - [ ] `gh auth status` reports `tokenSource=keyring` or the documented equivalent.
   - [ ] `gh api user --jq .login` returns `<expected-login>`.
   - [ ] `ls-remote origin HEAD` returns a ref, or the repository is intentionally empty and stderr plus exit status show auth succeeded.

4. Classify the result.

   - [ ] Sandbox false negative.
   - [ ] `NO_ORIGIN` or remote misconfiguration.
   - [ ] Empty remote repository edge case.
   - [ ] Branch protection.
   - [ ] Permission or scope shortage.
   - [ ] Network outage.
   - [ ] Agent approval-layer blocker.
   - [ ] Unresolved after keyring-capable proof.

## Do Not Include

- Token values.
- Secret-bearing logs.
- OAuth credentials.
- Auth cookies.
- Customer data.
- Real screenshots or network captures.
