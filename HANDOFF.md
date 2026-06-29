# HANDOFF

最終更新: 2026/06/29 22:19 JST

## リポジトリの目的

Windows上のCodex/agent sandboxがWindows keyringを読めず、GitHub認証が壊れて見える偽陰性を安全に診断するためのCodex-style skillリポジトリ。`SKILL.md`、README、synthetic examples、private-marker scan、OSS readiness validationを含む。

## 現状サマリ

- T-004（README Non-Goals改訂）とT-005（Claude Code install手順追加）は PR #3 で完了。
- scanner hardening は PR #5 で完了。`main` へ merge `c6bafc7` 済み。
- T-003（`actions/checkout@v5`への更新と`windows-latest`据え置きコメント）は PR #4 で完了。merge commit は `ff60b3e5829674342ca82bfb29e8fb285195387e`。
- 2026/06/29 22:17 JST時点で open PR / issue は0件。`main` は PR #9 merge `4ed8da3` まで `origin/main` と同期済み。
- GitHub認証はkeyring-capable経路で確認済み。token値やcredential-bearing logは記録していない。
- secret/token/OAuth値、実データ、ローカル絶対パスは引き継ぎ文書に記録していない。
- T-006 release readiness brief / notes draft は PR #9 で `main` に反映済み。tag push / GitHub Release作成 / version番号・target commit・公開タイミング・notes本文の最終承認は未実施。

## 完了タスクとcommit

| タスク | commit / PR |
| --- | --- |
| 初期 Windows GitHub auth diagnosis skill追加 | `8f4756f` |
| OSS readiness hardening | `97a83e2`, merge `e8d86a8` |
| v0.1.0 CHANGELOG整理 | `1bbe257`, PR #2 merge `9d4d105` |
| backlog棚卸し追加 | `405405a` |
| release PRタスク完了状態記録 | `0fde279`, `9db4d6b`, `f5ee3d9` |
| Codex締め・Claude Code引き継ぎ文書化 | `2441fbc` |
| T-004/T-005 docs整備 | PR #3 merge `48c26e9` |
| scanner hardening | PR #5 merge `c6bafc7` |
| T-003 CI checkout v5 | PR #4 merge `ff60b3e` |
| advisory review disposition | PR #7 merge `8b3897f` |
| T-006 release readiness brief / notes draft | PR #9 merge `4ed8da3` |

## 未完了 / 未実施

- T-006: 初のGitHub Release / tag。`docs/release-v0.2.0-brief.md` と `docs/release-v0.2.0-notes-draft.md` は PR #9 で `main` に反映済み。tag pushとrelease作成は未実施で、version番号・公開タイミング・最終target commitは未確認。
- T-007: Claude Codeプラグイン化とmarketplace配布の評価。評価は自走可。配布物構成の新設や実公開は、現行停止条件と公開前チェックを確認してから実施する。
- T-008: 配布チャネル拡張の調査。調査のみ自走可。

## 既知の問題・残懸念

- T-003 の `actions/checkout@v5` 更新は PR #4 で完了。`windows-latest` は現在の pwsh+git 依存では pin せず維持する。
- Release/tag は未実施。v0.2.0候補の確認、`docs/release-v0.2.0-brief.md` の承認チェック、公開前チェックが残る。
- public issue/PRに診断ログを書く場合は、token、credential-bearing log、ローカル絶対パス、private repo名を含めないこと。

## 最終検証結果

2026/06/29 22:19 JST、PR #9 merge後の `main` から本docs同期branchを切った状態で実行:

| コマンド | 結果 |
| --- | --- |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1` | pass |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1` | pass |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1` | pass |
| `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1` | pass |
| `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1` | pass |
| `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1` | pass |
| `git diff --check --cached` | pass |

## セットアップ・検証コマンド

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
git diff --check
```

`pwsh` が使える環境ではREADME記載の `pwsh -NoProfile -File ...` 形式でも実行可能。

## ブランチ状況

- `main`: PR #9 merge `4ed8da3` まで `origin/main` と同期済み。
- local backup branch: `backup/018-main-pre-align-20260629`（PR #4/#5統合前の同一tree履歴を保存）
- open PR / issue: 2026/06/29 22:17 JST時点でなし

## 次にやるべき候補

1. T-006のRelease notes/tag案は `docs/release-v0.2.0-brief.md` と `docs/release-v0.2.0-notes-draft.md` に PR #9 で準備済み。次はownerがversion番号・target commit・公開タイミング・notes本文を承認する。
2. T-007/T-008としてClaude Codeプラグイン化と配布チャネルを調査する。実公開や配布物構成の新設は公開前チェック後に扱う。

## 2026/06/29 Codex checkpoint

- PR #9 (`docs/t006-release-readiness-brief`)、PR #5 (`fix/scanner-hardening-split`) と PR #4 (`chore/ci-checkout-v5`) は `main` へmerge済み。
- local `main` は内容同一を確認後、`backup/018-main-pre-align-20260629` を作ってから `origin/main` へsoft align済み。
- ローカル advisory docs（`docs/CLAUDE_CODE_REVIEW_2026-06-21.md` / `docs/codex-task-scanner-hardening.md`）を再確認。T-003はPR #4、scanner hardeningはPR #5で解消済みのため原本は追跡しない判断をPR #7で記録済み。`.gitignore` で誤stageを防ぎ、残る公開作業はT-006のowner承認待ち、T-007/T-008の調査へ集約。
