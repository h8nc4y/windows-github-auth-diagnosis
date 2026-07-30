# TASKS_BACKLOG

最終更新: 2026/07/31 JST（Codex: T-015 release packet 後の GitHub 実状態を同期）

本ファイルがタスク台帳の正本。運用ルール・ゲート・検証手順は `docs/AGENT_BRIEF.md`、現在地サマリは `HANDOFF.md` を参照。着手時は `git status` / `git log` / `gh pr list` / `gh issue list` / `gh release list` の実状態を一次情報とする。

## Goal

windows-github-auth-diagnosis を Codex と Claude Code の両エージェントで使える「配布可能なスキル」として正式リリースし、普及できる状態にする。安全制約（token 非表示・認証情報を保存/管理しない・public-safe examples 維持）は不変の前提。

## タスク

| ID | タスク名 | 優先度 | 状態 | メモ |
| --- | --- | --- | --- | --- |
| T-001 | v0.1.0 公開準備 | 高 | done | PR #2 |
| T-002 | Codex→Claude Code 引き継ぎ文書化 | 高 | done | `HANDOFF.md` 新設 |
| T-003 | GitHub Actions 非推奨対応 | 高 | done | PR #4で当時の`actions/checkout@v5`へ更新。T-014 / PR #30でimmutable v7.0.1へsupersededし、checkout credentialは非永続化済み。runner方針は現行workflowコメントを参照 |
| T-004 | README Non-Goals 改訂・配布解禁 | 高 | done | PR #3。認証情報の保存/管理・根拠なき rotate/reset 助言の禁止は安全 Non-Goal として維持 |
| T-005 | Claude Code install 手順追加 | 高 | done | PR #3。frontmatter は両エージェント互換のため変更不要 |
| T-006 | 初の GitHub Release 発行（推奨 `v0.2.0`） | 中 | **todo・ゲート①** | brief / notes draft は準備済み（`docs/release-v0.2.0-brief.md` / `docs/release-v0.2.0-notes-draft.md`）。owner の4点承認（version / exact target commit / 公開タイミング / notes 本文）が揃うまで tag push / Release 作成をしない。candidate HEAD `71cddcb`は2026/07/31再確認時の観測値であり、承認済みrelease targetではない。承認時はその時点の`origin/main` exact SHAを再取得する |
| T-007 | Claude Code plugin 化＋marketplace 配布の評価 | 中 | done（評価） | `docs/claude-plugin-marketplace-evaluation.md`。実装 PR（`.claude-plugin/plugin.json` ＋ `claude plugin validate --strict` の検証組み込み）は T-006 承認後。workflow を変更する場合も通常 PR として review / current-head CI 後に merge できるが、tag / GitHub Release / marketplace 公開は各ゲートを維持する |
| T-008 | 配布チャネル拡張の調査 | 低 | done（調査） | PR #12、`docs/distribution-channel-research.md`。推奨順序: GitHub Release → README 導線 → plugin marketplace。npm は非推奨 |
| T-009 | skills.sh（`npx skills add`）掲載の評価 | 低 | done（評価） | PR #15、`docs/skills-sh-channel-evaluation.md`。submit 不要・現構成のまま機能する見込み。残る判断は Release 後の README 導線追加のみ（別 PR） |
| T-010 | 上流 issue への skill 紹介コメント投稿 | 低 | **blocked・ゲート③** | 外部発信のため owner 承認まで着手しない。対象候補は openai/codex #21821 / #17459 等 |
| T-011 | SKILL.md 明確化2点（transient retry / 環境変数 token 注記） | 中 | done | PR #18。2026-07-22 に最新 `main` との仮マージを両 PowerShell ランタイムで検証後に merge。main CI pass |
| T-012 | private-marker scanner の hermetic / bounded process hardening | 高 | **done・Class M** | PR #26、merge commit `6ffb095`。PS5.1限定retry、POSIX PID+nonce provenance、primary/cleanup aggregation、resume/release直前を含むsingle deadline、native ownership、returned/throw両経路のscan-wide child timeout分類、conditional state dominance、case-insensitiveなdynamic Type/member/`::new()`/`New-Object` reflective activation拒否を統合。PR current-head / main push の Windows・Ubuntu CI と post-main cross-runtime 検証を通過 |
| T-013 | native macOS process-group 検証の評価 | 中 | **done・Class M** | PR #28、merge commit `c5d5da9`。standard public `macos-latest` job と exact-envelope validatorを追加。macOS system aliasをGitのstrict `--is-inside-work-tree=true`＋empty `--show-prefix`で許容し、bare metadata root＋別`core.worktree`のfalse-clean回帰を拒否。PR current-head / main pushのWindows・Ubuntu・macOS CIとローカルcross-runtime full suiteを通過。paid/private larger runner、tag、Releaseとは独立 |
| T-014 | `actions/checkout` v7.0.1 immutable pin＋credential非永続化 | 中 | **done・Class M** | PR #30、merge commit `46c6e5c`。公式verified commitとNode 24 runtimeを照合し、3 jobをfull SHA＋`persist-credentials: false`へ更新。active `with`親を追跡するexact validator、release draft、PS7 / PS5.1 full suite、PR / mainの3OS CIを通過。tag / GitHub Release / marketplace公開とは独立 |
| T-015 | scanner self-test の並列host temp分離 | 中 | **done・Class M** | PR #33、merge commit `cebe64d`。self-test invocation固有のtemp rootへscanner subprocessとcleanup監査を限定し、別hostの同一prefix rootを誤検出・削除しないsynthetic回帰を追加。PS7 / PS5.1同時self-test、両hostのreadiness / marker scan、PR / mainの3OS CIを通過。scanner判定本体は変更していない。closeout文書はPR #34、release packetはPR #35で同期済み |

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
- 2026/07/25: T-012 の独立 review 修正、cross-runtime 検証、commit / push、PR #26 作成まで完了。GitHub hosted Windows の PS5 cold start は test-only probe の上限だけ30秒へ調整し、production timeout は維持。当時の運用正本にあった workflow owner gate に従い merge は保留した。
- 2026/07/27: PR #26 の fresh CI / process-boundary reviewを再実施し、Windows PS5.1のhealthy cold-startだけの1回retry、POSIX PID+nonce ready provenance、all-resource cleanup、primary failure保持、single deadline、native ownership、scan-wide child timeout分類、conditional state dominance、reflective class activation拒否を修正。独立review P0〜P3=0、PR current-head CI、merge commit `6ffb095` の main push CI、post-main の Windows両runtime / Linux network-none検証を通過した。現行方針に合わせ、workflow変更PRは通常のreview / current-head CI後にmerge可、tag / GitHub Releaseはゲート①のままと運用正本を同期した。
- 2026/07/28: T-014（PR #30）で`actions/checkout` v7.0.1のverified immutable commitへ更新し、3OS jobのcredential persistenceを無効化。active parentを追跡するexact validatorとmutation回帰を追加し、独立review、PR / main 3OS CI、post-main cross-runtime full suiteを通過した。tag / GitHub Release / marketplace公開のowner gateは未変更。
- 2026/07/29: T-014 post-main self-testをPS7 / PS5.1で並列実行した際、system temp全体の同一prefix差分を各hostが自分の残骸と誤認するtest harness欠陥を確認。T-015 / PR #33でinvocation固有tempと所有root限定cleanup監査へ修正し、両host同時self-test・readiness・marker scan、PR / mainの3OS CIを通過した。production scanner判定・timeout・公開gateは変更していない。
- 2026/07/30〜31: T-015 closeout文書をPR #34、release packetをPR #35でmergeした。2026/07/31の実測では`main == origin/main == 71cddcb`、main push Validate run 30517452697はWindows / Ubuntu / macOSがsuccess、open PR / issue / GitHub Release / tagは0件。`71cddcb`はcandidate HEADの観測値にとどまり、T-006の4点承認、tag / Release禁止、T-010外部発信ゲート、履歴保全用backup branchの保持は変更していない。

## 外部レビュー指摘の台帳（2026-07-15 maxエフォート横断レビュー）

読取専用レビュー（実行検証なし）の指摘。採否と実装は次担当が判断する。完了時は行頭を [x] にし、対応PRを追記する。3件とも PR #22 で対応済み。

- [x] .github/workflows/validate.yml最終step — CIのクリーンcheckoutでgit diff --checkが恒常パス(無意味チェック)。019のcheck-whitespace.ps1方式(empty-tree比較)へ。confidence高（`scripts/check-whitespace.ps1` を新設し CI step を差し替え。validate-oss-readiness にも必須ファイル・CI 配線チェックを追加）
- [x] scan-private-markers.ps1:50 — bearer ruleがliteralな(Bearer+半角空白)で散文もFP。019/020方式のtoken形状必須regexへ。confidence高（token 8文字以上必須の regex へ変更。散文パス／token検出の自己テスト追加）
- [x] 同:52 — email allowlistなし(example.com等プレースホルダも即fail)。017/019/020方式のallowlist追加。confidence高（example.* / noreply@ / @users.noreply.github.com を allowlist 化。プレースホルダ許容／実アドレス検出の自己テスト追加）
