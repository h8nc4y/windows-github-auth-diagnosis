# HANDOFF

最終更新: 2026/07/27 JST（Codex: T-012 merge・post-main 検証済み）

運用ルール・ゲート・検証手順の正本は `docs/AGENT_BRIEF.md`、タスク台帳の正本は `TASKS_BACKLOG.md`。文書と実状態が食い違う場合は Git / GitHub の実状態を優先する。

## 現在地

- Windows keyring を読めない sandbox 内の GitHub 認証偽陰性を、安全に診断する agent skill。配布・普及フェーズ。
- **T-012（Class M）は完了**。PR #26 を source commit `0066c6c`、merge commit `6ffb095` で merge した。open PR / issue / GitHub Release は確認時点で0件。
- scanner は bounded process helper、Git/index/worktree/path/resource 境界、Windows Job / POSIX process-group cleanup、strict byte transport、固定診断、AST early-call gate、workflow exact envelope を共有する。
- fresh review で、PS5.1 healthy cold-start限定retry、direct PID + nonce provenance、全resource cleanupとprimary保持、単一deadline、native ownership、scan-wide timeout分類、conditional state dominance、reflective class activation拒否まで統合した。production Git timeout 15秒は不変。
- workflow 変更 PR はゲート①ではない。通常のローカル検証・review・current-head CI 後に merge できる。tag / GitHub Release / marketplace 公開の各ゲートは維持する。

## 次の一手

1. **T-013（Class M）**: native macOS process-group 検証の実現性を一次情報と bounded CI で評価する。macOS native は現在 `未確認`。
2. **T-006 GitHub Release v0.2.0（ゲート①）**: owner の4点承認（version / target commit / 公開タイミング / notes本文）が揃うまで tag push / Release 作成をしない。
3. **T-006 承認後**: `.claude-plugin/plugin.json` と `claude plugin validate --strict` を別PRで追加する。実装PRは通常review/CIでmergeできるが、marketplace公開はゲート③。
4. **T-010（ゲート③）**: 上流 issue への紹介コメントは owner 承認まで行わない。

廃止済み integration や旧エージェント間メッセージングを復活させない。

## 検証

- freeze hash `2d524a9d09d2c40925dd5e5cd5ae9fec1d8b0e4f` の独立reviewは P0〜P3=0。PR current-head CI run 30222283213 と main push CI run 30222508500 は Windows / Ubuntu とも success。
- post-main: PowerShell 7 / Windows PowerShell 5.1 の full self-test・readiness・repo scan、Linux PowerShell 7.5 の network-none / read-only full self-test・readiness・repo scan・whitespaceを実測し pass。
- `git diff --check` pass。Gitleaks 8.30.1 は約632 KB・0 findings、Semgrep 1.165.0 は39 rules / 32 tracked files・0 findings。
- local / remote の T-012 task branch は削除済み。履歴保全用 `backup/018-main-pre-align-20260629` は削除しない。
