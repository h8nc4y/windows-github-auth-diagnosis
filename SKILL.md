---
name: windows-github-auth-diagnosis
description: Diagnose Windows Codex or agent sandbox GitHub authentication false negatives. Use when sandboxed `gh auth status`, `gh api`, `git fetch`, `git push`, or `git ls-remote` reports HTTP 401, Bad credentials, an invalid default token, `SEC_E_NO_CREDENTIALS`, missing credentials, or when an agent might ask for `gh auth login`, OAuth, or token input based only on a sandbox GitHub auth error.
---

# Windows GitHub Auth Diagnosis

Use this skill before declaring GitHub authentication broken on Windows when the failing command ran inside a Codex, agent, or tool sandbox.

## Core Rule

Treat sandbox-only GitHub authentication failures as false-negative candidates until a keyring-capable path proves otherwise. Some Windows agent sandboxes cannot read Credential Manager or another configured keyring even when GitHub CLI and Git are correctly authenticated in a normal terminal.

Do not run or suggest `gh auth login`, `gh auth logout`, or `gh auth refresh` based only on a sandbox HTTP 401, Bad credentials, invalid default token, or `SEC_E_NO_CREDENTIALS` result.

## Known False-Negative Symptoms

- `gh auth status -h github.com --json hosts` returns HTTP 401, Bad credentials, or an invalid default token from a sandboxed command.
- `gh api user --jq .login` returns `Requires authentication (HTTP 401)` from a sandboxed command.
- `git ls-remote`, `git fetch`, `git pull`, or `git push` over HTTPS fails with `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS` from a sandboxed command.

## Procedure

1. Confirm repository remote wiring:

   ```bash
   git -C <repo> remote -v
   ```

   If `origin` is missing, classify the problem as `NO_ORIGIN` or remote misconfiguration, not as GitHub authentication failure.

2. Check credential helper configuration:

   ```bash
   git -C <repo> config --get-all credential.helper
   git -C <repo> config --get-all credential.https://github.com.helper
   ```

3. Run the proof commands from a keyring-capable execution path without printing token values. In Codex, if sandboxed commands fail with the symptoms above, use the smallest available unsandboxed or approval-backed command path for only these proof commands:

   ```bash
   gh auth status -h github.com --json hosts
   gh api user --jq .login
   GIT_TERMINAL_PROMPT=0 git -C <repo> ls-remote origin HEAD
   ```

4. Treat GitHub authentication as healthy only when all of these are true:

   - `gh auth status` reports `state=success`.
   - `gh auth status` reports `tokenSource=keyring` or the documented keyring-backed source for the environment.
   - `gh api user --jq .login` returns the expected login.
   - `GIT_TERMINAL_PROMPT=0 git -C <repo> ls-remote origin HEAD` returns a ref, unless the remote is intentionally empty and stderr plus exit status show authentication succeeded.

5. If keyring proof succeeds, classify the sandbox 401, Bad credentials, invalid default token, or `SEC_E_NO_CREDENTIALS` result as a sandbox false negative. Continue push, PR, review, merge, or other GitHub work through the same keyring-capable execution path.

## Exceptions To Preserve

- `NO_ORIGIN`: missing or wrong `origin` is a remote configuration problem.
- Empty repository: `ls-remote origin HEAD` can return no ref for a truly empty remote; inspect stderr and exit status before calling it auth failure.
- Branch protection: push rejection from protected branches is not authentication failure.
- Permission or scope shortage: successful login with a failed operation can still indicate missing repository permission or token scope.
- Network outage: DNS, TLS, proxy, or GitHub availability problems are separate from credential health.
- Agent approval layer rejection: if a tool approval layer blocks `git push` or a GitHub command, classify it as an approval or permission-layer blocker, not GitHub auth failure.

## Prohibited Responses

- Do not print token values or run commands such as `gh auth token` or `gh auth status --show-token`.
- Do not ask for OAuth, token, secret, or credential entry based only on sandboxed failures.
- Do not run or suggest `gh auth login`, `gh auth logout`, or `gh auth refresh` until the keyring-capable proof path also fails and no exception explains the result.
- Do not wait in OAuth or token-entry loops.
- Do not paste real secrets, real authentication logs, cookies, screenshots, or customer data into public issues or chat reports.

## Reporting Template

When reporting the diagnosis, include only safe facts:

- sandbox symptom and command class, without tokens or secret-bearing logs
- remote wiring result
- credential helper result, with no secret values
- keyring-capable proof result: success or failure
- final classification: false negative, remote misconfiguration, permission/scope issue, branch protection, network issue, approval-layer blocker, or unresolved
- next command to continue, if safe
