# TASKS_BACKLOG

最終棚卸し: 2026/06/12 23:39:34 +09:00（Codex）
更新: 2026/06/13 12:43:19 +09:00（Claude Code: 配布・普及フェーズへ移行）
更新: 2026/06/20 23:04:00 +09:00（Codex: docs PRをゲート変更から分離し、T-004/T-005を完了）
更新: 2026/06/29 09:43 JST（Codex: PR #4/#5 merge後の状態へ同期）
更新: 2026/06/29 16:16 JST（Codex: PR #7 advisory disposition後の状態へ同期）
更新: 2026/06/29 22:19 JST（Codex: PR #9 release readiness brief後の状態へ同期）
更新: 2026/06/30 02:14 JST（Codex: T-007 Claude Code plugin marketplace評価をdocs化）
更新: 2026/06/30 02:30 JST（Codex: T-008 配布チャネル調査をdocs化）
更新: 2026/07/01 12:22 JST（Codex: PR #12後のcurrent-stateを同期）
更新: 2026/07/03 JST（Claude Fable5: 要件再評価をdocs化、T-009/T-010を追加）

## Goal

windows-github-auth-diagnosis を Codex と Claude Code の両エージェントで使える「配布可能なスキル」として正式リリースし、普及できる状態にする。安全制約（トークン非表示・認証情報を保存/管理しない・public-safe examples 維持）は不変の前提として継続する。

## 情報源

| 情報源 | 結果 |
| --- | --- |
| `TASKS_BACKLOG.md` / `TODO.md` / `TASKS.md` | このファイルを正として維持。`TODO.md` / `TASKS.md` は該当なし。 |
| `HANDOFF.md` | CodexからClaude Codeへの引き継ぎ用に作成済み。2026/07/01にPR #12後のcurrent-stateへ更新。 |
| `README.md` / `docs/` | `README.md` は検証手順と配布計画docsへの導線を定義。`docs/release-v0.2.0-brief.md` / `docs/release-v0.2.0-notes-draft.md` はPR #9で準備済み。`docs/claude-plugin-marketplace-evaluation.md` でT-007、`docs/distribution-channel-research.md` でT-008を記録。未追跡advisory docsは別タスク扱い。 |
| `AGENTS.md` / `.codex/` | ユーザー提示の `AGENTS.md` 指示を適用。リポジトリ内 `.codex/` は該当なし。 |
| コード内 `TODO` / `FIXME` | 該当なし。 |
| 失敗テスト / lint / 型チェック | 該当なし。2026/06/30 02:33 JST時点で `powershell` / `pwsh` の readiness・scanner self-test・git-tracked scan、`git diff --check --cached`、`gitleaks git --staged --redact` は通過。2026/07/01の本current-state syncでは `powershell` / `pwsh` の readiness・scanner self-test・git-tracked scan を再実行し通過。 |
| `git status` 未コミット変更 | 作業開始時点の `main...origin/main` はclean。本current-state syncでは `HANDOFF.md` / `TASKS_BACKLOG.md` のみ更新。未追跡advisory docsは `.gitignore` 対象として原本非採用。 |
| 未マージ/WIPブランチ | PR #4/#5 はmerge済み。local backup `backup/018-main-pre-align-20260629` は履歴保全用。 |
| GitHub open issues / PRs | 2026/07/01 12:20 JST時点で open issue / open PR は0件。PR #12 `docs/t008-distribution-channel-research` は merge commit `ef17dbf` で反映済み。 |

## タスク

| ID | タスク名 | 出典 | 優先度 | 規模 | 状態 | メモ |
| --- | --- | --- | --- | --- | --- | --- |
| T-001 | `docs/prepare-v0-1-0-release` の公開準備を完了する | 未マージ/WIPブランチ、open PRなし | 高 | S | done | PR #2を作成・検証・merge済み: https://github.com/h8nc4y/windows-github-auth-diagnosis/pull/2 |
| T-002 | Codex作業の締めとClaude Code向け引き継ぎを完了する | ユーザー依頼、HANDOFF作成 | 高 | S | done | `HANDOFF.md` 作成、doing解消確認、検証結果記録。締めcommit: `2441fbc`。 |
| T-003 | GitHub Actions の非推奨対応（Node.js 20 / windows-latest） | 最新Validate runのannotation | 高 | S | done | PR #4でmerge済み: `actions/checkout@v4`→`@v5`（Node24）。`windows-latest` は pwsh+git のみ依存のためpinせず据え置き、理由をworkflowに明記。 |
| T-004 | README Non-Goals を改訂し配布を解禁 | ユーザー依頼（Non-Goals全面見直し） | 高 | S | done | GitHub Release作成・Claude Code/marketplace配布・パッケージ配布を「許可」へ。認証情報の保存/管理・rotate/reset助言の禁止は安全Non-Goalとして維持。 |
| T-005 | Claude Code 対応（install手順追加） | ユーザー依頼（Codex/Claude Code両対応） | 高 | M | done | READMEに user/project 両方の install 手順を追加。frontmatterは現状で両対応互換のため変更不要。project配置のrepo同梱は配布物構成変更を避けるため行わない。 |
| T-006 | 初の GitHub Release 発行 | 配布・普及フェーズ | 中 | S | todo | 推奨 `v0.2.0`。`docs/release-v0.2.0-brief.md` と `docs/release-v0.2.0-notes-draft.md` はPR #9で準備済み。tag push / GitHub Release作成 / バージョン番号・target commit・実施時期の最終決定は未承認。 |
| T-007 | Claude Code プラグイン化＋marketplace配布の評価 | 次フェーズ | 中 | M | done | `docs/claude-plugin-marketplace-evaluation.md` で公式docsとローカルCLI helpを確認。`.claude-plugin/` 作成、`claude plugin tag`、marketplace add/install、GitHub Release は未実施。 |
| T-008 | 配布チャネル拡張の調査 | 次フェーズ | 低 | S | done | PR #12 merge `ef17dbf`。`docs/distribution-channel-research.md` でGitHub Release、manual install、Claude plugin marketplace、npm package等を比較。実publish / install smoke / package metadata作成は未実施。 |
| T-009 | skills.sh（`npx skills add`）掲載の評価 | 要件再評価 2026-07 | 低 | S | todo | `docs/requirements-reassessment-2026-07.md` §5。SKILL.md互換で変換コストゼロ見込み。掲載手順・登録要否・撤回可否を調査してから判断。実掲載は未実施。 |
| T-010 | 上流issueへのskill紹介コメント投稿 | 要件再評価 2026-07 | 低 | S | blocked | owner承認ゲート（外部発信）。対象候補は openai/codex #21821 / #17459 等。承認前は投稿しない。 |

- 📌 2026-06-21 Claude Code 再レビュー: ローカル advisory docs は2026/06/29に再確認。T-003はPR #4、scanner hardeningはPR #5で解消済みのため原本は追跡しない。以後は本backlogとtracked docsを正とする。

- 🔧 2026-06-21 Claude Code 実装: scanner hardening は PR #5 としてmerge済み（merge `c6bafc7`）。未追跡advisory docsの原本は `.gitignore` で誤stage防止し、必要な事実はこの台帳へ圧縮済み。

## 2026/06/29 Codex checkpoint

- PR #9 release readiness brief、PR #7 advisory review disposition、PR #5 scanner hardening、PR #4 checkout v5 は `main` へmerge済み。local `main` は `origin/main` に同期済み。T-006 release readiness brief/notes draft は準備済みで、release/tag実行はowner承認待ち。
- PR #4は最新 `origin/main` に一時mergeして、Windows PowerShell 5.1 / pwsh の readiness・scanner self-test・git-tracked scan と `git diff --check --cached` を確認済み。
- ローカル advisory docs はPR #7で原本非採用・`.gitignore` 対象として記録済み。PR #4/#5で解消済みの指摘を再タスク化せず、残タスクはT-006/T-007/T-008へ集約。

## 2026/06/30 Codex checkpoint

- PR #10 のdocs同期後、T-007として Claude Code plugin marketplace 配布を評価。公式docsと `claude plugin` の非対話helpを確認した。
- 評価結論は `docs/claude-plugin-marketplace-evaluation.md` に記録。現時点では `.claude-plugin/` を作らず、T-006 release/tag 承認後に別PRで配布構成を決める方針。
- 残タスクは T-006 のowner承認待ち release/tag と、T-008 の配布チャネル調査。
- T-008は PR #12 merge `ef17dbf` で `docs/distribution-channel-research.md` に反映済み。推奨順序は GitHub Release を正本にし、Release承認後にClaude plugin marketplace構成を別PRで追加、npm packageは現時点で非推奨。

## 2026/07/01 Codex checkpoint

- PR #12 merge `ef17dbf` 後の `main...origin/main` clean と、GitHub open issue / open PR 0件を確認。
- 残タスクはT-006 owner承認待ちのGitHub Release/tag。承認前のtag push、GitHub Release作成、Claude plugin marketplace add/install、npm publish、外部配布smokeは未実施。

## 2026/07/03 Claude Fable5 checkpoint

- Fable5が引き継ぎ、配布価値・ユーザー導線・誤診リスクを再評価して `docs/requirements-reassessment-2026-07.md` に記録。価値仮説は維持（需要issueは上流repoに複数Open、競合skill不在）。
- Web調査差分: `.claude-plugin/plugin.json` の必須フィールドは `name` のみで、SKILL.md root直下の単一skill構成のままpluginとして成立する。skills.sh（`npx skills add`）が新配布チャネルとして確認されたためT-009を追加。上流issueへの紹介コメントはT-010としてowner承認ゲートに置いた。
- SKILL.md改善候補（release blockerではない）: 一時的失敗の分類前リトライ明文化、環境変数由来tokenが有効な場合の判定注記。
- ローカルのagent-orchestration handoff drafts（`docs/CLAUDECODE_FABLE5_*.md`）はPR #7の前例に従い `.gitignore` 対象として原本非採用。
- 残ゲートはT-006（owner 4点承認: version / target commit / 公開タイミング / notes本文）。承認前のtag push / Release作成 / marketplace add/install / npm publish / 外部発信は未実施。
