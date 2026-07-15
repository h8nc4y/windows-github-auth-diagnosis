# TASKS_BACKLOG

最終更新: 2026/07/12 JST（Claude Fable5: docs 再編にあわせて台帳を圧縮）

本ファイルがタスク台帳の正本。運用ルール・ゲート・検証手順は `docs/AGENT_BRIEF.md`、現在地サマリは `HANDOFF.md` を参照。着手時は `git status` / `git log` / `gh pr list` / `gh issue list` の実状態を一次情報とする。

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
| T-011 | SKILL.md 明確化2点（transient retry / 環境変数 token 注記） | 中 | **review 待ち** | PR #18（open・CI pass）。要件再評価 §3 の改善候補を実装。レビュー後マージ |

## 履歴（要約）

各時点の詳細は git log と該当 PR 本文に残っている。ここでは1行ずつだけ保持する。

- 2026/06/06: v0.1.0 相当の初期公開（skill 本体・examples・scanner・CI）。
- 2026/06/20〜29: 配布解禁 docs（PR #3）、CI checkout v5（PR #4）、scanner hardening（PR #5）、advisory disposition（PR #7）、release readiness brief（PR #9）。
- 2026/06/30〜07/01: T-007 plugin 評価・T-008 配布チャネル調査を docs 化（PR #12 ほか）。open PR/issue 0件で Claude へ引き継ぎ。
- 2026/07/03: Claude Fable5 が要件再評価（PR #14）と T-009 評価（PR #15）。repo description/topics を検索導線強化のため更新。`.claude-plugin/plugin.json` 必須フィールドは `name` のみで root 直下 SKILL.md 構成のまま plugin 成立を確認。
- 2026/07/06: 運用ノート取り込み（PR #16）・post-Fable5 引き継ぎ文書（PR #17）。
- 2026/07/11〜12: SKILL.md 明確化2点を PR #18 化。旧エージェント間メッセージング経由のセカンドオピニオンはチャネル廃止により未受領クローズ。docs 再編（本 PR #19: HANDOFF/本台帳の圧縮、旧運用ブリーフ2本を `docs/AGENT_BRIEF.md` へ統合）。主担当を Codex へ移管。
