# TASKS_BACKLOG

最終棚卸し: 2026/06/11 21:10:57 +09:00

## 情報源

| 情報源 | 結果 |
| --- | --- |
| `TASKS_BACKLOG.md` / `TODO.md` / `TASKS.md` | このファイルを正として維持。`TODO.md` / `TASKS.md` は該当なし。 |
| `README.md` / `docs/` | `README.md` は検証手順を定義。`docs/` は該当なし。 |
| `AGENTS.md` / `.codex/` | ユーザー提示の `AGENTS.md` 指示を適用。リポジトリ内 `.codex/` は該当なし。 |
| コード内 `TODO` / `FIXME` | 該当なし。 |
| 失敗テスト / lint / 型チェック | 該当なし。`validate-oss-readiness.ps1`、`test-scan-private-markers.ps1`、`scan-private-markers.ps1`、`git diff --check` は通過。 |
| `git status` 未コミット変更 | 該当なし。 |
| 未マージ/WIPブランチ | 該当なし。`docs/prepare-v0-1-0-release` はPR #2でmerge済み、リモート/ローカルブランチ削除済み。 |
| GitHub open issues | 該当なし。`gh issue list` は `[]`。 |

## タスク

| ID | タスク名 | 出典 | 優先度 | 規模 | 状態 | メモ |
| --- | --- | --- | --- | --- | --- | --- |
| T-001 | `docs/prepare-v0-1-0-release` の公開準備を完了する | 未マージ/WIPブランチ、open PRなし | 高 | S | done | PR #2を作成・検証・merge済み: https://github.com/h8nc4y/windows-github-auth-diagnosis/pull/2 |
