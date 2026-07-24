# HANDOFF

最終更新: 2026/07/25 JST（Codex: T-012 scanner process boundary hardening 再レビュー修正済み）

運用ルール・ゲート・検証手順の正本は `docs/AGENT_BRIEF.md`、タスク台帳の正本は `TASKS_BACKLOG.md`。本書は「現在地」だけを持つ。文書と実状態が食い違ったら `git log` / `gh pr list` / `gh issue list` / `gh release list` を一次情報とする。

## リポジトリの目的

Windows 上の agent/tool sandbox が Windows keyring を読めず GitHub 認証が壊れて見える偽陰性を、安全に診断する agent skill（`SKILL.md` が本体）。配布・普及フェーズ。

## 現在地（2026-07-24）

- 着手時の `main` / `origin/main` は merge commit `c664ecf`。open PR 0件、open issue 0件、GitHub Release 0件。
- T-001〜T-005・T-007〜T-009・T-011 は完了。T-011（PR #18）は、一時的失敗の1回再試行と環境変数由来 token source の健全判定注記を追加した。
- 直近の基盤整備は完了済み: docs 統合（PR #19）、外部レビュー台帳（PR #21）、scanner / whitespace 修正（PR #22）、`CODEX_START_HERE.md`（PR #23）、Windows PowerShell 5.1 の scanner 回帰修正（PR #24）。
- **T-012（Class M）freeze準備完了**: `fix/hermetic-private-marker-scan` で scanner を共通の bounded process helper へ移行し、Git/index/worktree/path/resource 境界、Windows Job / POSIX process-group cleanup、strict byte transport、redacted process-boundary / deadline 診断、AST early-call indirection、workflow exact envelope の回帰を追加した。独立reviewで検出したambient非Git環境の継承、POSIX pre-session race、BusyBox非互換optionを修正し、再reviewはfinding 0。

## 次の一手とゲート

1. **T-012**: 検証済み tree を freeze し、独立 P1/P2/P3 review、PR 作成まで進める。`.github/workflows/validate.yml` を変更するため、PR merge はゲート①で停止する。
2. **T-006 GitHub Release v0.2.0**（ゲート①）: owner の4点承認（version 番号 / target commit / 公開タイミング / notes 本文 `docs/release-v0.2.0-notes-draft.md`）が揃うまで tag push / Release 作成をしない。質問リストは `docs/requirements-reassessment-2026-07.md` §6。
3. **T-006 承認後**: `.claude-plugin/plugin.json` PR と `claude plugin validate --strict` の検証追加を進める。CI 変更を含む PR のマージはゲート①。Release 後に README へ `npx skills add` 導線を追加する。
4. **T-010 上流 issue への紹介コメント**（ゲート③・外部発信）: owner 承認まで着手しない。

承認待ちの間に廃止済み integration や旧エージェント間メッセージングを復活させない。

## 検証

2026-07-25 の T-012 作業ツリーで以下を実測:

- PowerShell 7 / Windows PowerShell 5.1: scanner self-test、readiness、repo scan は pass。self-test は共有temp isolationの競合を避けて逐次実行する。
- 公式 `mcr.microsoft.com/powershell:7.5-ubuntu-24.04` container: Git を一時導入後、scanner self-test、readiness、repo scan は pass。
- AST parse、`git diff --check`、Gitleaks 8.30.1（leak 0）は pass。Semgrep final diff は実行前にexecution policyで拒否されたため `未確認`。
- AST gate は target shadow、scope/module-qualified wrapper、built-in alias、`Get-Command` / function-provider 参照、保存/生成 ScriptBlock の `.Invoke*()` / `ForEach-Object` / `Where-Object` / `Invoke-Command`、provider mutation、`processBoundary` 上書き、class constructor/member/static initialization、expression/pipeline、dynamic call を fail closed。
- 不正な `ScanDeadlineMilliseconds` は host parameter binder の raw 出力へ落とさず、固定 path-free `integrity: scan-deadline` + exit 2 へ統一。
- helper欠落/例外、unhealthy child、isolation作成/削除を固定 path-free `integrity: process-boundary` + exit 2 へ統一。Windows Job close は handle を先行破棄せず Stop/Dispose で再試行し、Job / direct process termination fallback を保持。
- workflow gate は quoted/flow extra mapping と未消費 active indentation を拒否。

## ブランチ状況

- local task branch は `fix/hermetic-private-marker-scan`。独立review済みtreeをstageまでfreezeし、workflow owner gateのため commit / push / PR / merge は未実施。
- local backup `backup/018-main-pre-align-20260629` は履歴保全用のため削除しない。
