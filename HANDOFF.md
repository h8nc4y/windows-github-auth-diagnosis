# HANDOFF

最終更新: 2026/06/20 23:34:39 +09:00

## リポジトリの目的

Windows上のCodex/agent sandboxがWindows keyringを読めず、GitHub認証が壊れて見える偽陰性を安全に診断するためのCodex-style skillリポジトリ。`SKILL.md`、README、synthetic examples、private-marker scan、OSS readiness validationを含む。

## 現状サマリ

- `chore/distribution-readiness` のWIPは、docs変更とGitHub Actions変更が混在していたため、briefの§15に従って分離した。
- T-004（README Non-Goals改訂）とT-005（Claude Code install手順追加）はdocs変更として完了扱い。`README.md`、`CHANGELOG.md`、`TASKS_BACKLOG.md`に反映済み。
- T-003（`actions/checkout@v5`への更新と`windows-latest`据え置きコメント）はゲート①に該当するため、このdocs変更から外して別PRで扱う。
- open issue / open PR は着手時点でどちらも0件。mainの直近Validateはsuccess。
- GitHub認証はkeyring-capable経路で確認済み。`gh auth status` は `state=success` / `tokenSource=keyring`、`gh api user` は想定アカウント、`git ls-remote origin HEAD` はrefを返した。
- secret/token/OAuth値、実データ、ローカル絶対パスは引き継ぎ文書に記録していない。

## 完了タスクとcommit

| タスク | commit / PR |
| --- | --- |
| 初期 Windows GitHub auth diagnosis skill追加 | `8f4756f` |
| OSS readiness hardening | `97a83e2`, merge `e8d86a8` |
| v0.1.0 CHANGELOG整理 | `1bbe257`, PR #2 merge `9d4d105` |
| backlog棚卸し追加 | `405405a` |
| release PRタスク完了状態記録 | `0fde279`, `9db4d6b`, `f5ee3d9` |
| Codex締め・Claude Code引き継ぎ文書化 | `2441fbc`（初回HANDOFF追加）。以降のhandoff metadata更新は `git log --oneline` 参照。 |
| T-004/T-005 docs整備 | このhandoff更新と同じdocs PRで完了予定。 |

## 未完了 / 承認待ち

- T-003: GitHub Actions変更。`.github/workflows/validate.yml` を変更するため、PR作成までは自走可だがmerge直前で人間承認が必要。
- T-006: 初のGitHub Release / tag。Release notesとtag案の準備は可能だが、tag pushとrelease作成は人間承認後に行う。
- T-007: Claude Codeプラグイン化とmarketplace配布の評価。評価は自走可、配布物構成の新設や実公開はゲート判断が必要。
- T-008: 配布チャネル拡張の調査。調査のみ自走可。

## 既知の問題・残懸念

- `actions/checkout@v4` のNode.js 20非推奨annotationに対応するため、T-003の別PRが必要。
- Release作成はゲート①のため、T-003 merge後も人間承認なしには実行しない。
- public issue/PRに診断ログを書く場合は、token、credential-bearing log、ローカル絶対パス、private repo名を含めないこと。

## 最終検証結果

2026/06/20 23:34 JSTに実行:

| コマンド | 結果 |
| --- | --- |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1` | pass |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1` | pass |
| `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1` | pass |
| `git diff --check` | pass |

## セットアップ・検証コマンド

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
git diff --check
```

`pwsh` が使える環境ではREADME記載の `pwsh -NoProfile -File ...` 形式でも実行可能。

## ブランチ状況

- docs branch: `chore/distribution-readiness`
- next gated branch: `chore/ci-checkout-v5`
- upstream: `origin/main`
- open PR: 着手時点ではなし

## 次にやるべき候補

1. docs変更の `check:all` 相当を通し、PRを作成して自走mergeする。
2. `main` から `chore/ci-checkout-v5` を切り、T-003のGitHub Actions変更と対応するCHANGELOG行を入れてPRを作成する。
3. T-003 PRは、人間のゲート①承認を得てからmergeする。
4. T-003 merge後、T-006のRelease notesとtag案を用意し、Release/tag実行前に人間承認を得る。
