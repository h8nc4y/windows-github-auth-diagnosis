# TASKS_BACKLOG

最終棚卸し: 2026/06/12 23:39:34 +09:00

## 情報源

| 情報源 | 結果 |
| --- | --- |
| `TASKS_BACKLOG.md` / `TODO.md` / `TASKS.md` | このファイルを正として維持。`TODO.md` / `TASKS.md` は該当なし。 |
| `HANDOFF.md` | CodexからClaude Codeへの引き継ぎ用に作成済み。 |
| `README.md` / `docs/` | `README.md` は検証手順を定義。`docs/` は該当なし。 |
| `AGENTS.md` / `.codex/` | ユーザー提示の `AGENTS.md` 指示を適用。リポジトリ内 `.codex/` は該当なし。 |
| コード内 `TODO` / `FIXME` | 該当なし。 |
| 失敗テスト / lint / 型チェック | 該当なし。2026/06/12 22:35 JST時点で `validate-oss-readiness.ps1`、`test-scan-private-markers.ps1`、`scan-private-markers.ps1`、`git diff --check` は通過。 |
| `git status` 未コミット変更 | 該当なし。 |
| 未マージ/WIPブランチ | 該当なし。`docs/prepare-v0-1-0-release` はPR #2でmerge済み、リモート/ローカルブランチ削除済み。 |
| GitHub open issues / PRs | 該当なし。`gh issue list` と `gh pr list --state open` はどちらも `[]`。 |

## タスク

| ID | タスク名 | 出典 | 優先度 | 規模 | 状態 | メモ |
| --- | --- | --- | --- | --- | --- | --- |
| T-001 | `docs/prepare-v0-1-0-release` の公開準備を完了する | 未マージ/WIPブランチ、open PRなし | 高 | S | done | PR #2を作成・検証・merge済み: https://github.com/h8nc4y/windows-github-auth-diagnosis/pull/2 |
| T-002 | Codex作業の締めとClaude Code向け引き継ぎを完了する | ユーザー依頼、HANDOFF作成 | 高 | S | done | `HANDOFF.md` 作成、doing解消確認、検証結果記録。締めcommit: `2441fbc`。 |
| T-003 | GitHub Actions runner / Node.js 20 deprecation注記を確認する | 最新Validate runのannotation | 中 | S | todo | CIはsuccess。`actions/checkout@v4` のNode.js 20非推奨と `windows-latest` リダイレクト予定が通知されたため、次回作業で対応要否を判断する。 |
