# Requirements reassessment 2026-07

確認日: 2026-07-03 JST
作成: Claude Fable5（要件再評価担当）。Web調査はサブエージェント調査（2026-07-03実施）、セカンドオピニオンはCodex GPT-5.5へ依頼済み（返信受領後に本docへ追記予定）。

## 位置づけ

既存資料（`README.md`, `SKILL.md`, `TASKS_BACKLOG.md`, `docs/release-v0.2.0-brief.md`, `docs/distribution-channel-research.md`, `docs/claude-plugin-marketplace-evaluation.md`）を出発点に、配布価値・ユーザー導線・誤診リスクを再評価した結果を記録する。本docは承認記録ではなく、T-006以降の判断材料である。

## 1. 目的・価値仮説（再確認）

- 課題: Windows上のagent sandboxはWindows keyring（Credential Manager）を読めないことがあり、`gh` / `git` over HTTPS が HTTP 401 / Bad credentials / `SEC_E_NO_CREDENTIALS` を返して認証破損に見える（偽陰性）。
- 被害仮説: agentがこの偽陰性を本物の認証失敗と誤認すると、(a) 不要な `gh auth login` / OAuth / token貼り付けをユーザーに要求する、(b) 不要なcredential rotate/resetへ誘導する、(c) token表示コマンドで秘密情報を露出させる、のいずれかが起きうる。本skillはこの3つを防ぐ保守的トリアージを提供する。
- 価値仮説の判定: **維持**。2026-07-03時点の調査で、需要シグナルは複数の上流リポジトリにOpen issueとして継続している（openai/codex #21821, #17459, #10695、anthropics/claude-code #67055 ほか。いずれもメンテナ未解決）。同種の「sandbox起因偽陰性の診断」に特化した競合skill/ツールは確認できなかった（anthropics/skills リポジトリ、awesome系リスト、GitHub/Web検索）。
- 正直な市場規模評価: 対象は Windows × agent CLI × sandbox × GitHub認証 の交差で母数は小さい。star数ではなく「エラーに遭遇した人へ届くこと」を成功と定義する public-good 型micro-OSSとして運用するのが妥当。維持コストはSKILL.md 1ファイル+検証スクリプトで十分小さく、価値/コスト比は成立する。

## 2. ユーザー導線（再評価）

到達導線の優先順位（推定確度が高い順）:

1. **エラーメッセージ検索**（最有力）: `SEC_E_NO_CREDENTIALS`, `gh auth status HTTP 401 sandbox`, `AcquireCredentialsHandle`, `Bad credentials` 等での検索流入。README/SKILL.mdは主要文字列を既に含む。
2. **GitHubリポジトリメタデータ**: 2026-07-03時点のdescriptionは「Codex skill for diagnosing Windows GitHub keyring false negatives」でClaude Code対応が読めず、topicsに `claude-code` / `agent-skills` / `github-cli` / `sandbox` がない。→ 改善提案（本doc §5）。
3. **skillエコシステム経由**: Claude Code plugin marketplace（T-007）に加え、2026-01公開の skills.sh（`npx skills add`、Codex/Claude Code両対応の共有skillディレクトリ）が新チャネルとして確認された。SKILL.md単体構成のまま追加変換なしで親和する。→ 新タスクT-009。
4. **上流issueからの誘導**: openai/codex等の該当issueへ本skillを紹介するコメントは最も転換率が高い導線だが、外部発信のためowner承認ゲート。→ 新タスクT-010（承認待ち）。

## 3. 誤診リスク（再評価）

- 「本物の認証失敗を偽陰性と誤分類」する方向: 手順4がkeyring-capable経路での証明成功を健全判定の必要条件にしているため、構造的にリスクは低い。証明経路自体が失敗すれば健全とは判定されない。
- 「偽陰性を本物の失敗と誤分類」する方向: skillは保守的側（修復助言をしない）に倒れるため被害は限定的。
- 調査で得た補足: anthropics/claude-code #67055 は keyring不可視性以外の要因（タイムアウト・一時的ネットワーク）でも「認証切れ」に見える事例を含む。SKILL.mdのExceptionsに「Network outage」は既にあるが、**一時的失敗は分類前に同一コマンドの再試行を1回挟む**旨の明文化は改善候補（release blockerではない）。
- 既知の軽微な曖昧さ: `tokenSource` がkeyringでなく環境変数由来で健全なケースは、手順4の「keyring-backed source」文言と噛み合わない。環境変数tokenが有効な場合の判定注記も改善候補（同上）。

## 4. 版数・成功指標

- **v0.2.0は妥当**: 0.1.0以降の変更（Claude Code install手順、Non-Goals改訂、CI checkout v5、scanner hardening）は追加的・非破壊で、pre-1.0のminor bumpが正直な表現。
- **成功指標（無料枠のみ・バックエンドなし制約下の最小計測）**:
  - GitHub Insights traffic（views/clones、owner閲覧可）
  - stars / issue・discussion流入（特に「使った」報告と誤診報告ゼロの維持）
  - 配布後: skills.sh / marketplace経由のinstall数（各プラットフォームの公開値がある場合のみ）
  - 目標値は置かず、四半期ごとに導線別の到達を棚卸しする運用を提案（public-good型）。

## 5. 配布戦略の更新（distribution-channel-research.md への差分）

2026-06-30調査からの差分と推奨順序の更新:

1. **T-006 GitHub Release v0.2.0**（owner承認ゲート、変更なし・最優先）。
2. **リポジトリメタデータ改善**（新・軽量）: description を Codex/Claude Code 両対応と主要エラー文字列を含む文へ更新し、topics に `claude-code`, `agent-skills`, `github-cli`, `sandbox`, `credential-manager` を追加する。可逆・低リスクでエラーメッセージ検索導線を直接強化する。
   - description案: `Agent skill for Codex and Claude Code that diagnoses Windows GitHub auth false negatives (HTTP 401, Bad credentials, SEC_E_NO_CREDENTIALS) caused by sandboxes that cannot read the Windows keyring.`
3. **T-007実装PR**: `.claude-plugin/plugin.json` は必須フィールドが `name` のみで、SKILL.mdをroot直下に置く単一skill構成のままpluginとして成立することを確認済み（Claude Code公式docs、2026-07-03）。`skills/` ディレクトリへの移行は不要。`claude plugin validate --strict` をCI/local検証に追加する。frontmatterの `name` が未指定だとバージョン文字列にフォールバックする仕様のため、現SKILL.mdの `name: windows-github-auth-diagnosis` 明示は維持する。
4. **T-009（新規）**: skills.sh（`npx skills add`）掲載の評価。SKILL.md互換のため変換コストゼロの見込み。掲載手順・登録要否・運用面（撤回可否）を調査してから判断する。
5. **npm**: 引き続き非推奨（変更なし）。

## 6. Ownerへの質問リスト

| # | 区分 | 質問 |
| --- | --- | --- |
| Q1 | 公開範囲/T-006 | v0.2.0 の4点承認（version番号 / target commit / 公開タイミング / notes本文 `docs/release-v0.2.0-notes-draft.md`）を行うか。 |
| Q2 | 公開範囲/T-010 | 上流issue（openai/codex #21821 等）へ本skillを紹介するコメント投稿を許可するか。最も転換率が高い導線だが外部発信に当たる。 |
| Q3 | 配布構成 | marketplace対応は自repo内 `.claude-plugin/` のみとするか、将来の複数skill配布を見越して別marketplace repoを立てるか。 |
| Q4 | 成功指標 | 目標値なしのpublic-good運用（四半期棚卸しのみ）でよいか。 |
| Q5 | 費用上限 | 全チャネル無料枠のみで確定か（有料の配布・宣伝手段は非採用でよいか）。 |

## 7. 非目標（変更なし）

- credentialの保存・管理をしない。実露出や証明済みcredential失敗がない限りrotate/reset助言をしない。
- token値の表示・記録をしない。実データ・credential-bearing logを公開物へ含めない。

## 未実施

- GitHub Release / tag push（T-006、owner承認待ち）
- `.claude-plugin/` 作成、`claude plugin validate --strict` 実行（T-007実装PR）
- skills.sh 掲載手順の実施（T-009、調査から）
- 上流issueへのコメント投稿（T-010、owner承認待ち）
- Codex GPT-5.5セカンドオピニオンの反映（agmsg返信待ち）
