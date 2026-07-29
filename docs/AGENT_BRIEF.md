# Agent operations brief — windows-github-auth-diagnosis

最終更新: 2026/07/27 JST

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

次のいずれかに触れる操作は、**対応する実行/マージ/公開の直前で停止して owner の承認を得る**:

- **① リリース**: git tag の作成/push、GitHub Release の作成、および承認対象の Release に束ねる外部公開。
- **② 課金**: 有料 API・課金サービスの利用。
- **③ secret・外部発信**: token・認証情報・実ログ・実データの外部送信、上流 issue へのコメント、marketplace 登録等の外部発信（T-010 系）。
- **④ 契約変更**: `SKILL.md` の Core Rule / Procedure / Prohibited Responses / Exceptions To Preserve、および README の Non-Goals が定めるスコープ・約束の変更。文面の明確化・誤記修正・既定方針内の追記は④に当たらない。

`.github/workflows/**` の変更自体はゲート①ではない。ローカル検証、敵対的セルフレビューまたは独立レビュー、PR の current-head CI が揃えば通常の CI 変更 PR として merge できる。workflow の変更が tag / GitHub Release / 外部公開を実行する場合は、その実行部分に対応するゲートを維持する。

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
Windows job は scanner self-test を PowerShell 7 と Windows PowerShell 5.1
の両方で実行し、Ubuntu 24.04 job は external `setsid` を含む POSIX
process-group 経路、macOS job は native `setsid(2)` fallback を検証する。
全 job は有限 timeout を持ち、checkout action は reviewed commit に固定する。
checkout credentialは後続stepへ永続化せず、exact validatorが
`persist-credentials: false`を3 jobすべてで要求する。
workflow envelope は trigger / permission / job ID / active indentation を
exact 検証し、quoted key や flow mapping で追加jobを隠す変更も拒否する。
scanner self-test は invocation 固有の `TEMP` / `TMP` / `TMPDIR` を
scanner subprocessへ渡し、cleanup監査をその所有root内だけに限定する。
PS7 / PS5.1など別hostが同時に作る同一prefixのrootは、残骸として
誤検出も削除もしない。

`scan-private-markers.ps1` の制約（スキャン対象は git-tracked ファイル。staged を含む）:

- 許可される GitHub repo URL は `https://github.com/h8nc4y/windows-github-auth-diagnosis`（`.git` 付き clone 形式含む）のみ。外部 issue/repo は「owner/repo #番号」の URL なし表記で書く。docs.github.com 等の別ホストは通る。
- token 接頭辞・秘密鍵ブロック・認可ヘッダ形式の token（ルール名 bearer-token-header）・メールアドレス・Windows 絶対パスを検出すると fail（マッチ値は redact される）。
- 運用文書に検出カテゴリを書くときは、この行のように日本語名かルール名で書き、実際にマッチしうるリテラル形式（token 接頭辞の実文字列や、認可ヘッダの英語慣用句＋半角空白の並び）を直書きしない。ローカルで pass しても実行環境差で CI が fail しうる。
- 個人環境固有のマーカーは追跡しない `.private-markers.local` か環境変数 `WINDOWS_GITHUB_AUTH_DIAGNOSIS_PRIVATE_MARKERS` に置く。
- Git/index/file 境界、strict UTF-8、resource limit、child process cleanup
  を検証できない場合は fail closed。Git-backed mode は通常 stage-0
  index blob と tracked worktree の和集合を検査し、開始時・終了時の
  index/flags drift も拒否する。exact worktree root はhost path文字列では
  なくGitのstrict inside-work-tree `true`＋empty `--show-prefix`で判定し、
  system aliasを許容してもsubdirectoryとmetadata rootは拒否する。
- `scripts/private-marker-process.ps1` は binary-safe stream、有限 timeout、
  Windows Job / POSIX process group cleanup、isolated Git environment の
  共通境界。scanner/test の双方で同じ helper を使い、個別の直接実行へ
  戻さない。Git child の環境は親の clone ではなく固定 allowlist から作り、
  非Git名の credential / marker / loader / agent 変数も継承しない。
  Windows は direct target を suspended で作成し、Job 割当後に
  resume する。assign/resume failure は有限 wait まで cleanup を確認し、
  正常終了した親の Job は stream drain より先に close する。close failure
  では handle ownership を Stop/Dispose の再試行まで保持し、Job termination
  fallback を失わない。cleanup は先頭例外で打ち切らず全stream/native
  resourceを試行し、primary failureをaggregateへ保持する。native handleは
  close成功後だけownershipを手放す。environment準備・launch・POSIX gate・
  target pollは単一monotonic deadlineを共有し、Windows resume / POSIX
  release直前にも同じclockを再確認する。有限cleanup猶予だけを別枠にする。
  POSIX は child が `setsid` 後に direct launcher PID + launch nonce の
  strict ASCII recordをatomic通知し、親がbyte-exact provenanceと
  direct PID=PGIDを確認してから target を release する。
  helper / bounded result / isolation setup-cleanup の
  failure は固定 `integrity: process-boundary` + exit 2 だけを出す。
- first-call AST gate は target function/alias shadow、scope/module-qualified
  command、built-in alias、function-provider、保存/生成 ScriptBlock の
  `.Invoke*()` / command sink、provider write、processBoundary 上書き、
  class constructor/member/static initialization、expression/pipeline
  indirection、dynamic Type/member、member名の大小文字差、runtime Type
  receiver の `::new()`、`New-Object`を含むreflective activationを raw
  binary fixture より前で拒否する。条件分岐内のvariable / alias state writeは
  実行済みsafe overwriteとみなさずUnknownへ閉じる。不正値・runtime期限超過と、scan-wide残時間で
  capされたGit child timeoutはreturned result / POSIX gate exceptionの
  どちらも固定 `integrity: scan-deadline` + exit 2 だけを出す。Git固有15秒
  timeoutと期限前startup failureの`process-boundary`分類は変更しない。

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
