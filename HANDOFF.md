# HANDOFF

最終更新: 2026/07/22 JST（Codex: PR #18 レビュー・マージ後の実状態へ同期）

運用ルール・ゲート・検証手順の正本は `docs/AGENT_BRIEF.md`、タスク台帳の正本は `TASKS_BACKLOG.md`。本書は「現在地」だけを持つ。文書と実状態が食い違ったら `git log` / `gh pr list` / `gh issue list` / `gh release list` を一次情報とする。

## リポジトリの目的

Windows 上の agent/tool sandbox が Windows keyring を読めず GitHub 認証が壊れて見える偽陰性を、安全に診断する agent skill（`SKILL.md` が本体）。配布・普及フェーズ。

## 現在地（2026-07-22）

- `main` は PR #18 の merge commit `30fa7ca` を含み、同 commit の Validate workflow も pass。
- open PR 0件、open issue 0件、GitHub Release 0件。
- T-001〜T-005・T-007〜T-009・T-011 は完了。T-011（PR #18）は、一時的失敗の1回再試行と環境変数由来 token source の健全判定注記を追加した。
- 直近の基盤整備は完了済み: docs 統合（PR #19）、外部レビュー台帳（PR #21）、scanner / whitespace 修正（PR #22）、`CODEX_START_HERE.md`（PR #23）、Windows PowerShell 5.1 の scanner 回帰修正（PR #24）。

## 次の一手とゲート

1. **T-006 GitHub Release v0.2.0**（ゲート①）: owner の4点承認（version 番号 / target commit / 公開タイミング / notes 本文 `docs/release-v0.2.0-notes-draft.md`）が揃うまで tag push / Release 作成をしない。質問リストは `docs/requirements-reassessment-2026-07.md` §6。
2. **T-006 承認後**: `.claude-plugin/plugin.json` PR と `claude plugin validate --strict` の検証追加を進める。CI 変更を含む PR のマージはゲート①。Release 後に README へ `npx skills add` 導線を追加する。
3. **T-010 上流 issue への紹介コメント**（ゲート③・外部発信）: owner 承認まで着手しない。

現時点で、自走可能な未完了タスクはない。承認待ちの間に廃止済み integration や旧エージェント間メッセージングを復活させない。

## 検証

2026-07-22 に PR #18 と最新 `main` の仮マージ結果で、readiness / scanner self-test / private-marker scan / whitespace check を `pwsh` と Windows PowerShell 5.1 の両方で pass。merge commit `30fa7ca` の main CI Validate も pass。

## ブランチ状況

- remote の open task branch / open PR はなし。
- local backup `backup/018-main-pre-align-20260629` は履歴保全用のため削除しない。
