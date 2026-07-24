# TASKS_BACKLOG

最終更新: 2026/07/25 JST（Codex: T-012 PR #26 owner review 待ち）

本ファイルがタスク台帳の正本。運用ルール・ゲート・検証手順は `docs/AGENT_BRIEF.md`、現在地サマリは `HANDOFF.md` を参照。着手時は `git status` / `git log` / `gh pr list` / `gh issue list` / `gh release list` の実状態を一次情報とする。

## Goal

windows-github-auth-diagnosis を Codex と Claude Code の両エージェントで使える「配布可能なスキル」として正式リリースし、普及できる状態にする。安全制約（token 非表示・認証情報を保存/管理しない・public-safe examples 維持）は不変の前提。

## タスク

| ID | タスク名 | 優先度 | 状態 | メモ |
| --- | --- | --- | --- | --- |
| T-001 | v0.1.0 公開準備 | 高 | done | PR #2 |
| T-002 | Codex→Claude Code 引き継ぎ文書化 | 高 | done | `HANDOFF.md` 新設 |
| T-003 | GitHub Actions 非推奨対応 | 高 | done | PR #4: `actions/checkout@v5`。`windows-latest` は pwsh+git のみ依存のため据え置き（理由は workflow 内コメント） |
| T-004 | README Non-Goals 改訂・配布解禁 | 高 | done | PR #3。認証情報の保存/管理・根拠なき rotate/reset 助言の禁止は安全 Non-Goal として維持 |
| T-005 | Claude Code install 手順追加 | 高 | done | PR #3。frontmatter は両エージェント互換のため変更不要 |
| T-006 | 初の GitHub Release 発行（推奨 `v0.2.0`） | 中 | **todo・ゲート①** | brief / notes draft は準備済み（`docs/release-v0.2.0-brief.md` / `docs/release-v0.2.0-notes-draft.md`）。owner の4点承認（version / target commit / 公開タイミング / notes 本文）が揃うまで tag push / Release 作成をしない |
| T-007 | Claude Code plugin 化＋marketplace 配布の評価 | 中 | done（評価） | `docs/claude-plugin-marketplace-evaluation.md`。実装 PR（`.claude-plugin/plugin.json` ＋ `claude plugin validate --strict` の検証組み込み）は T-006 承認後。CI 変更を含むためマージはゲート① |
| T-008 | 配布チャネル拡張の調査 | 低 | done（調査） | PR #12、`docs/distribution-channel-research.md`。推奨順序: GitHub Release → README 導線 → plugin marketplace。npm は非推奨 |
| T-009 | skills.sh（`npx skills add`）掲載の評価 | 低 | done（評価） | PR #15、`docs/skills-sh-channel-evaluation.md`。submit 不要・現構成のまま機能する見込み。残る判断は Release 後の README 導線追加のみ（別 PR） |
| T-010 | 上流 issue への skill 紹介コメント投稿 | 低 | **blocked・ゲート③** | 外部発信のため owner 承認まで着手しない。対象候補は openai/codex #21821 / #17459 等 |
| T-011 | SKILL.md 明確化2点（transient retry / 環境変数 token 注記） | 中 | done | PR #18。2026-07-22 に最新 `main` との仮マージを両 PowerShell ランタイムで検証後に merge。main CI pass |
| T-012 | private-marker scanner の hermetic / bounded process hardening | 高 | **PR open・ゲート①・Class M** | PR #26。process/byte/redacted-diagnostic/AST-indirection/workflow-envelope の cross-runtime / security 検証と独立 review、commit、push は完了。workflow 変更 PR の merge は owner 承認待ち |

## 履歴（要約）

各時点の詳細は git log と該当 PR 本文に残っている。ここでは1行ずつだけ保持する。

- 2026/06/06: v0.1.0 相当の初期公開（skill 本体・examples・scanner・CI）。
- 2026/06/20〜29: 配布解禁 docs（PR #3）、CI checkout v5（PR #4）、scanner hardening（PR #5）、advisory disposition（PR #7）、release readiness brief（PR #9）。
- 2026/06/30〜07/01: T-007 plugin 評価・T-008 配布チャネル調査を docs 化（PR #12 ほか）。open PR/issue 0件で Claude へ引き継ぎ。
- 2026/07/03: Claude Fable5 が要件再評価（PR #14）と T-009 評価（PR #15）。repo description/topics を検索導線強化のため更新。`.claude-plugin/plugin.json` 必須フィールドは `name` のみで root 直下 SKILL.md 構成のまま plugin 成立を確認。
- 2026/07/06: 運用ノート取り込み（PR #16）・post-Fable5 引き継ぎ文書（PR #17）。
- 2026/07/11〜16: 廃止済み開発分掌の除去（PR #20）、docs 統合（PR #19）、外部レビュー台帳と scanner / whitespace 修正（PR #21・#22）、標準入口追加（PR #23）、Windows PowerShell 5.1 scanner 回帰修正（PR #24）。
- 2026/07/22: T-011（PR #18）をレビュー・検証・merge。open PR 0件、open issue 0件、GitHub Release 0件を確認。
- 2026/07/24: T-012 着手。`main` / `origin/main` `c664ecf`、open PR/issue 0件、Release 0件から branch を作成し、scanner process boundary と cross-runtime CI 回帰を統合中。
- 2026/07/25: T-012 の独立 review 修正、cross-runtime 検証、commit / push、PR #26 作成まで完了。GitHub hosted Windows の PS5 cold start は test-only probe の上限だけ30秒へ調整し、production timeout は維持。workflow owner gate のため merge は未実施。

## 外部レビュー指摘の台帳（2026-07-15 maxエフォート横断レビュー）

読取専用レビュー（実行検証なし）の指摘。採否と実装は次担当が判断する。完了時は行頭を [x] にし、対応PRを追記する。3件とも PR #22 で対応済み。

- [x] .github/workflows/validate.yml最終step — CIのクリーンcheckoutでgit diff --checkが恒常パス(無意味チェック)。019のcheck-whitespace.ps1方式(empty-tree比較)へ。confidence高（`scripts/check-whitespace.ps1` を新設し CI step を差し替え。validate-oss-readiness にも必須ファイル・CI 配線チェックを追加）
- [x] scan-private-markers.ps1:50 — bearer ruleがliteralな(Bearer+半角空白)で散文もFP。019/020方式のtoken形状必須regexへ。confidence高（token 8文字以上必須の regex へ変更。散文パス／token検出の自己テスト追加）
- [x] 同:52 — email allowlistなし(example.com等プレースホルダも即fail)。017/019/020方式のallowlist追加。confidence高（example.* / noreply@ / @users.noreply.github.com を allowlist 化。プレースホルダ許容／実アドレス検出の自己テスト追加）
