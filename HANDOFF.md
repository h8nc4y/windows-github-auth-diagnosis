# HANDOFF

最終更新: 2026/07/12 JST（Claude Fable5 → Codex 引き継ぎ）

運用ルール・ゲート・検証手順の正本は `docs/AGENT_BRIEF.md`、タスク台帳の正本は `TASKS_BACKLOG.md`。本書は「現在地」だけを持つ。文書と実状態が食い違ったら `git log` / `gh pr list` を一次情報とする。

## リポジトリの目的

Windows 上の agent/tool sandbox が Windows keyring を読めず GitHub 認証が壊れて見える偽陰性を、安全に診断する agent skill（`SKILL.md` が本体）。配布・普及フェーズ。

## 現在地（2026-07-12）

- `main` は PR #17 merge まで `origin/main` と同期。GitHub Release は未発行（0件）。open issue 0件。
- open PR 2件（いずれも CI Validate pass 済み・レビュー後マージ待ち）:
  - **PR #18**: SKILL.md 明確化2点（一時的失敗は分類前に同一コマンドを1回再試行／環境変数由来 token source の健全判定注記）＋ CHANGELOG ＋ release notes draft 反映。
  - **PR #19**（本書を含む docs 再編 PR）: HANDOFF / TASKS_BACKLOG の圧縮、旧運用ブリーフ2本を `docs/AGENT_BRIEF.md` へ統合、README・release brief の導線更新。
- T-001〜T-005・T-007〜T-009 は完了（詳細と成果物パスは `TASKS_BACKLOG.md`）。
- PR #19（本 docs 統合）は 2026-07-15 の横断監査でレビュー・マージ済み。**PR #18 のレビュー・マージが次の最初のタスク**。
- 旧エージェント間メッセージング経由のセカンドオピニオン依頼（2026-07-03）は、チャネル廃止により未受領のままクローズ。以後の異見は `docs/requirements-reassessment-2026-07.md` へ直接追記する。

## 残タスクとゲート

1. **PR #18 のレビューとマージ**(非ゲート・自走可)。レビュー観点: SKILL.md 手順4の健全判定条件（state=success ＋ expected login ＋ ls-remote ref の全成立）が緩んでいないこと。
2. **T-006 GitHub Release v0.2.0**（ゲート①）: owner の4点承認（version 番号 / target commit / 公開タイミング / notes 本文 `docs/release-v0.2.0-notes-draft.md`）が揃うまで tag push / Release 作成をしない。owner 向け質問リストは `docs/requirements-reassessment-2026-07.md` §6。
3. **T-006 承認後の実装キュー**: `.claude-plugin/plugin.json` PR（`claude plugin validate --strict` を検証へ追加。CI 変更を含むためマージはゲート①）と、README への `npx skills add` 導線追加 PR。
4. **T-010 上流 issue への紹介コメント**（ゲート③・外部発信）: owner 承認まで着手しない。

## 検証

PR 前に `docs/AGENT_BRIEF.md` §5 の検証スイート（readiness / scanner self-test / private-marker scan / `git diff --check`）を全部緑にする。直近の全 pass 実績: 2026-07-15（本 PR ブランチ、readiness / scanner self-test / private-marker scan / diff --check）。CI Validate も両 PR で pass。

## ブランチ状況

- open: `fix/skill-transient-retry-and-env-token`（PR #18）、`docs/handoff-2026-07-11`（PR #19）
- local backup: `backup/018-main-pre-align-20260629`（履歴保全用。削除しない）
