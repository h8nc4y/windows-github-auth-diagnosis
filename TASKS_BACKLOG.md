# TASKS_BACKLOG

最終棚卸し: 2026/06/12 23:39:34 +09:00（Codex）
更新: 2026/06/13 12:43:19 +09:00（Claude Code: 配布・普及フェーズへ移行）
更新: 2026/06/20 23:04:00 +09:00（Codex: docs PRをゲート変更から分離し、T-004/T-005を完了）
更新: 2026/06/29 09:43 JST（Codex: PR #4/#5 merge後の状態へ同期）
更新: 2026/06/29 16:16 JST（Codex: PR #7 advisory disposition後の状態へ同期）
更新: 2026/06/29 22:19 JST（Codex: PR #9 release readiness brief後の状態へ同期）

## Goal

windows-github-auth-diagnosis を Codex と Claude Code の両エージェントで使える「配布可能なスキル」として正式リリースし、普及できる状態にする。安全制約（トークン非表示・認証情報を保存/管理しない・public-safe examples 維持）は不変の前提として継続する。

## 情報源

| 情報源 | 結果 |
| --- | --- |
| `TASKS_BACKLOG.md` / `TODO.md` / `TASKS.md` | このファイルを正として維持。`TODO.md` / `TASKS.md` は該当なし。 |
| `HANDOFF.md` | CodexからClaude Codeへの引き継ぎ用に作成済み。2026/06/29にPR #9 release readiness brief後の状態へ更新。 |
| `README.md` / `docs/` | `README.md` は検証手順を定義。`docs/release-v0.2.0-brief.md` / `docs/release-v0.2.0-notes-draft.md` はPR #9で準備済み。未追跡advisory docsは別タスク扱い。 |
| `AGENTS.md` / `.codex/` | ユーザー提示の `AGENTS.md` 指示を適用。リポジトリ内 `.codex/` は該当なし。 |
| コード内 `TODO` / `FIXME` | 該当なし。 |
| 失敗テスト / lint / 型チェック | 該当なし。2026/06/29 22:19 JST時点でWindows PowerShell 5.1 / pwsh の3本検証、`git diff --check`、Gitleaks は通過。 |
| `git status` 未コミット変更 | `HANDOFF.md` / `TASKS_BACKLOG.md` は本PR #9後状態同期で更新。未追跡advisory docsは `.gitignore` 対象として原本非採用。 |
| 未マージ/WIPブランチ | PR #4/#5 はmerge済み。local backup `backup/018-main-pre-align-20260629` は履歴保全用。 |
| GitHub open issues / PRs | 2026/06/29 22:17 JST時点で open PR / issue は0件。PR #9 はmerge済み。 |

## タスク

| ID | タスク名 | 出典 | 優先度 | 規模 | 状態 | メモ |
| --- | --- | --- | --- | --- | --- | --- |
| T-001 | `docs/prepare-v0-1-0-release` の公開準備を完了する | 未マージ/WIPブランチ、open PRなし | 高 | S | done | PR #2を作成・検証・merge済み: https://github.com/h8nc4y/windows-github-auth-diagnosis/pull/2 |
| T-002 | Codex作業の締めとClaude Code向け引き継ぎを完了する | ユーザー依頼、HANDOFF作成 | 高 | S | done | `HANDOFF.md` 作成、doing解消確認、検証結果記録。締めcommit: `2441fbc`。 |
| T-003 | GitHub Actions の非推奨対応（Node.js 20 / windows-latest） | 最新Validate runのannotation | 高 | S | done | PR #4でmerge済み: `actions/checkout@v4`→`@v5`（Node24）。`windows-latest` は pwsh+git のみ依存のためpinせず据え置き、理由をworkflowに明記。 |
| T-004 | README Non-Goals を改訂し配布を解禁 | ユーザー依頼（Non-Goals全面見直し） | 高 | S | done | GitHub Release作成・Claude Code/marketplace配布・パッケージ配布を「許可」へ。認証情報の保存/管理・rotate/reset助言の禁止は安全Non-Goalとして維持。 |
| T-005 | Claude Code 対応（install手順追加） | ユーザー依頼（Codex/Claude Code両対応） | 高 | M | done | READMEに user/project 両方の install 手順を追加。frontmatterは現状で両対応互換のため変更不要。project配置のrepo同梱は配布物構成変更を避けるため行わない。 |
| T-006 | 初の GitHub Release 発行 | 配布・普及フェーズ | 中 | S | todo | 推奨 `v0.2.0`。`docs/release-v0.2.0-brief.md` と `docs/release-v0.2.0-notes-draft.md` はPR #9で準備済み。tag push / GitHub Release作成 / バージョン番号・target commit・実施時期の最終決定は未承認。 |
| T-007 | Claude Code プラグイン化＋marketplace配布の評価 | 次フェーズ | 中 | M | todo | `.claude-plugin/plugin.json` + `skills/` 構成と `claude plugin validate` を評価。 |
| T-008 | 配布チャネル拡張の調査 | 次フェーズ | 低 | S | todo | パッケージ公開等の手段を調査のみ（実装は別途）。 |

- 📌 2026-06-21 Claude Code 再レビュー: ローカル advisory docs は2026/06/29に再確認。T-003はPR #4、scanner hardeningはPR #5で解消済みのため原本は追跡しない。以後は本backlogとtracked docsを正とする。

- 🔧 2026-06-21 Claude Code 実装: scanner hardening は PR #5 としてmerge済み（merge `c6bafc7`）。未追跡advisory docsの原本は `.gitignore` で誤stage防止し、必要な事実はこの台帳へ圧縮済み。

## 2026/06/29 Codex checkpoint

- PR #9 release readiness brief、PR #7 advisory review disposition、PR #5 scanner hardening、PR #4 checkout v5 は `main` へmerge済み。local `main` は `origin/main` に同期済み。T-006 release readiness brief/notes draft は準備済みで、release/tag実行はowner承認待ち。
- PR #4は最新 `origin/main` に一時mergeして、Windows PowerShell 5.1 / pwsh の readiness・scanner self-test・git-tracked scan と `git diff --check --cached` を確認済み。
- ローカル advisory docs はPR #7で原本非採用・`.gitignore` 対象として記録済み。PR #4/#5で解消済みの指摘を再タスク化せず、残タスクはT-006/T-007/T-008へ集約。
