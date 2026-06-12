# HANDOFF

最終更新: 2026/06/12 22:35:09 +09:00

## リポジトリの目的

Windows上のCodex/agent sandboxがWindows keyringを読めず、GitHub認証が壊れて見える偽陰性を安全に診断するためのCodex-style skillリポジトリ。`SKILL.md`、README、synthetic examples、private-marker scan、OSS readiness validationを含む。

## 現状サマリ

- `main` は `origin/main` と一致している。
- 未コミット変更は締め作業開始時点でなし。締め作業では `TASKS_BACKLOG.md` 更新と `HANDOFF.md` 作成のみを行う。
- `TASKS_BACKLOG.md` に doing は残っていない。
- open issue / open PR はどちらも0件。
- 未mergeブランチはなし。`docs/prepare-v0-1-0-release` はPR #2でmerge済み。
- main最新CIは `Validate` success（run `27345950504`、head `f5ee3d9`）。
- secret/token/OAuth値、実データ、ローカル絶対パスは引き継ぎ文書に記録していない。

## 完了タスクとcommit

| タスク | commit / PR |
| --- | --- |
| 初期 Windows GitHub auth diagnosis skill追加 | `8f4756f` |
| OSS readiness hardening | `97a83e2`, merge `e8d86a8` |
| v0.1.0 CHANGELOG整理 | `1bbe257`, PR #2 merge `9d4d105` |
| backlog棚卸し追加 | `405405a` |
| release PRタスク完了状態記録 | `0fde279`, `9db4d6b`, `f5ee3d9` |
| Codex締め・Claude Code引き継ぎ文書化 | この `HANDOFF.md` を追加するcommit |

## 未完了 / skip

- 未完了タスクなし。
- skipタスクなし。

## 既知の問題・残懸念

- 現時点の既知問題はなし。
- `gh run list --json` は空出力だったため、CI確認は表形式の `gh run list` 出力で確認した。
- 今後public issue/PRに診断ログを書く場合は、token、credential-bearing log、ローカル絶対パス、private repo名を含めないこと。

## 最終検証結果

2026/06/12 22:35 JSTに実行:

| コマンド | 結果 |
| --- | --- |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1` | pass |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1` | pass |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1` | pass |
| `git diff --check` | pass |
| `gh issue list --repo h8nc4y/windows-github-auth-diagnosis --limit 50 --json number,title,state,labels,updatedAt` | `[]` |
| `gh pr list --repo h8nc4y/windows-github-auth-diagnosis --state open --limit 50 --json number,title,state,url,headRefName,baseRefName,mergeStateStatus` | `[]` |
| `gh run list --repo h8nc4y/windows-github-auth-diagnosis --branch main --limit 3` | latest `Validate` success |

## セットアップ・検証コマンド

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
git diff --check
```

`pwsh` が使える環境ではREADME記載の `pwsh -NoProfile -File ...` 形式でも実行可能。

## ブランチ状況

- active branch: `main`
- upstream: `origin/main`
- 未mergeブランチ: なし
- open PR: なし

## 次にやるべき候補

1. Claude Code側で `TASKS_BACKLOG.md` とこの `HANDOFF.md` を読み、mainがcleanか確認する。
2. 新しい作業を始める場合は、別branchを切り、public-safe examplesとprivate-marker scanを維持する。
3. 次のrelease作業が必要になった時点で、GitHub ReleaseやMarketplace登録の要否を別途判断する。
