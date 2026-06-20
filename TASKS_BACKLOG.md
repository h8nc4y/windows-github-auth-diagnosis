# TASKS_BACKLOG

最終棚卸し: 2026/06/12 23:39:34 +09:00（Codex）
更新: 2026/06/13 12:43:19 +09:00（Claude Code: 配布・普及フェーズへ移行）
更新: 2026/06/20 23:04:00 +09:00（Codex: docs PRをゲート変更から分離し、T-004/T-005を完了）

## Goal

windows-github-auth-diagnosis を Codex と Claude Code の両エージェントで使える「配布可能なスキル」として正式リリースし、普及できる状態にする。安全制約（トークン非表示・認証情報を保存/管理しない・public-safe examples 維持）は不変の前提として継続する。

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
| T-003 | GitHub Actions の非推奨対応（Node.js 20 / windows-latest） | 最新Validate runのannotation | 高 | S | doing | `actions/checkout@v4`→`@v5`（Node24）でNode.js 20非推奨を解消。`windows-latest` は pwsh+git のみ依存のため対応不要と判断（pinせず据え置き、理由をworkflowに明記）。ゲート①のためdocs PRから分離し、別PRで人間承認後にmergeする。 |
| T-004 | README Non-Goals を改訂し配布を解禁 | ユーザー依頼（Non-Goals全面見直し） | 高 | S | done | GitHub Release作成・Claude Code/marketplace配布・パッケージ配布を「許可」へ。認証情報の保存/管理・rotate/reset助言の禁止は安全Non-Goalとして維持。 |
| T-005 | Claude Code 対応（install手順追加） | ユーザー依頼（Codex/Claude Code両対応） | 高 | M | done | READMEに user/project 両方の install 手順を追加。frontmatterは現状で両対応互換のため変更不要。project配置のrepo同梱は配布物構成変更を避けるため行わない。 |
| T-006 | 初の GitHub Release 発行 | 配布・普及フェーズ | 中 | S | todo | 推奨 `v0.2.0`。tag・release notes・README badge整備。T-003 merge後に実施。バージョン番号・実施時期は要確認。 |
| T-007 | Claude Code プラグイン化＋marketplace配布の評価 | 次フェーズ | 中 | M | todo | `.claude-plugin/plugin.json` + `skills/` 構成と `claude plugin validate` を評価。 |
| T-008 | 配布チャネル拡張の調査 | 次フェーズ | 低 | S | todo | パッケージ公開等の手段を調査のみ（実装は別途）。 |
