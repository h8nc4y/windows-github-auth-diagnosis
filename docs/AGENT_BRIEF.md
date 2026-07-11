# Agent operations brief — windows-github-auth-diagnosis

最終更新: 2026/07/12 JST

本書は、このリポジトリを主担当する開発エージェント（Codex / Claude Code いずれでも）向けの運用正本である。旧 `docs/CODEX_BRIEF_018_windows-github-auth-diagnosis.md` と旧 `docs/CLAUDECODE_HANDOFF.md` を統合し、陳腐化したスナップショット・廃止済みの役割分担記述を除去した（2026-07-12）。

本リポジトリは public。本書を含む追跡ファイルに、token値・credential-bearing log・ローカル絶対パス・個人環境の詳細を書かないこと。

## 1. リポジトリ概要

- 目的: Windows 上の agent/tool sandbox が Windows keyring（Credential Manager 等）を読めないことで GitHub 認証が壊れて見える**偽陰性**を、安全に診断する agent skill。`SKILL.md` が本体。
- 構成: root 直下 `SKILL.md` ＋ README ＋ synthetic examples ＋ PowerShell 検証スクリプト ＋ OSS 一式 ＋ CI（`.github/workflows/validate.yml`）。npm / Node アプリではない。
- フェーズ: 配布・普及（GitHub Release / Codex・Claude Code install / plugin・marketplace / packaging は許可スコープ。ただし認証情報の保存・管理と根拠なき rotate/reset 助言は恒久 Non-Goal）。

## 2. 情報源と読む順序

1. `TASKS_BACKLOG.md` — タスク台帳の正本
2. `HANDOFF.md` — 現在地サマリ
3. 本書 — 運用ルール・ゲート・検証手順
4. `docs/requirements-reassessment-2026-07.md` — 要件・配布戦略の判断材料
5. `docs/release-v0.2.0-brief.md` / `docs/release-v0.2.0-notes-draft.md` — T-006 リリース準備
6. 配布チャネル調査: `docs/distribution-channel-research.md` / `docs/claude-plugin-marketplace-evaluation.md` / `docs/skills-sh-channel-evaluation.md`

文書は更新が遅れうる。着手時は必ず `git status` / `git log` / `gh pr list` / `gh issue list` の実状態を一次情報とし、齟齬があれば実状態を優先して文書側を直す。

## 3. 自律範囲と停止ゲート

自走してよい: タスク選定、実装、検証、ブランチ作成、コミット、push、PR 作成、非ゲート PR のマージ、マージ済みブランチ削除、docs 更新。

次のいずれかに触れる操作は、**実行/マージの直前で停止して owner の承認を得る**:

- **① リリース・CI**: git tag の作成/push、GitHub Release の作成、あらゆるデプロイ、`.github/workflows/**` を変更する PR のマージ。
- **② 課金**: 有料 API・課金サービスの利用。
- **③ secret・外部発信**: token・認証情報・実ログ・実データの外部送信、上流 issue へのコメント等の外部発信（T-010 系）。
- **④ 契約変更**: `SKILL.md` の Core Rule / Procedure / Prohibited Responses / Exceptions To Preserve、および README の Non-Goals が定めるスコープ・約束の変更。文面の明確化・誤記修正・既定方針内の追記は④に当たらない。

承認依頼は「対象操作 / 該当ゲート / 判断材料 / 承認後の実行コマンド」を明記して owner に出す。承認待ちの間は他の非ゲートタスクを進めてよく、待機のために停止しない。

## 4. 不変の安全制約

- token 値を表示・出力・記録しない。`gh auth token` / `gh auth status --show-token` 等を使わない。
- 認証情報を保存・管理しない。実露出か証明済み credential 失敗がない限り rotate/reset を助言しない。
- sandbox 内の認証失敗だけを根拠に `gh auth login/logout/refresh` や OAuth/token 入力を実行・提案しない。
- `examples/` は synthetic placeholder のみ。public な成果物に実 token・実認証ログ・cookie・秘密鍵・顧客データ・private repo 名・内部パスを入れない。
- **自己参照**: 作業中に自分の `gh`/`git` が 401 / Bad credentials / `SEC_E_NO_CREDENTIALS` を返したら、結論前に本リポジトリの `SKILL.md` の手順で偽陰性判定すること。

## 5. 検証スイート（PR 前に全部緑にする）

リポジトリルートで実行（`pwsh` がなければ `powershell -NoProfile -ExecutionPolicy Bypass -File` 形式でも可）:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
git diff --check
```

CI（Validate workflow）は PR と `main` への push で同じ検査を実行する。

`scan-private-markers.ps1` の制約（スキャン対象は git-tracked ファイル。staged を含む）:

- 許可される GitHub repo URL は `https://github.com/h8nc4y/windows-github-auth-diagnosis`（`.git` 付き clone 形式含む）のみ。外部 issue/repo は「owner/repo #番号」の URL なし表記で書く。docs.github.com 等の別ホストは通る。
- token 接頭辞・秘密鍵ブロック・認可ヘッダ形式の token（ルール名 bearer-token-header）・メールアドレス・Windows 絶対パスを検出すると fail（マッチ値は redact される）。
- 運用文書に検出カテゴリを書くときは、この行のように日本語名かルール名で書き、実際にマッチしうるリテラル形式（token 接頭辞の実文字列や、認可ヘッダの英語慣用句＋半角空白の並び）を直書きしない。ローカルで pass しても実行環境差で CI が fail しうる。
- 個人環境固有のマーカーは追跡しない `.private-markers.local` か環境変数 `WINDOWS_GITHUB_AUTH_DIAGNOSIS_PRIVATE_MARKERS` に置く。

## 6. ブランチ・コミット・PR 規約

- タスク単位の focused branch（`fix/`, `docs/`, `chore/` ＋ short-kebab）。`main` へ直接コミットしない。
- コミット件名は英語 conventional prefix ＋ 英語要約。本文に日本語の補足（なぜ・検証結果）を書いてよい。
- PR 本文は日本語で Summary / Changes / Tests / Review notes / Risks / Unknowns を記載。ゲート①〜④に該当する内容を含む場合は自己申告する。
- マージ前に敵対的セルフレビュー（正しさ / 安全 / 回帰 / 明確さの観点で自分の差分を批判し、見つけた問題を直す）を行い、結果を PR 本文に書く。
- 自分が作成した PR をレビューなしで即マージする運用は避け、可能なら別セッション/別エージェントのレビューを挟む。

## 7. セッション報告

各セッションの最後に、日本語で以下を含む報告を出す（日付は JST の絶対日付。secret・実データ・ローカル絶対パスを書かない）:

- やったこと（タスク ID・commit・PR 番号）
- 検証結果（§5 の pass 状況）
- 学び・詰まり・解決
- 残課題と次の一手

あわせて `HANDOFF.md`（現在地）と `TASKS_BACKLOG.md`（台帳）を最新化する。
