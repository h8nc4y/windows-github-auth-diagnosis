# HANDOFF

最終更新: 2026/07/29 JST（Codex: T-015 scanner self-test 並列分離を完了）

運用ルール・ゲート・検証手順の正本は `docs/AGENT_BRIEF.md`、タスク台帳の正本は `TASKS_BACKLOG.md`。文書と実状態が食い違う場合は Git / GitHub の実状態を優先する。

## 現在地

- Windows keyring を読めない sandbox 内の GitHub 認証偽陰性を、安全に診断する agent skill。配布・普及フェーズ。
- **T-012（Class M）は完了**。PR #26 を source commit `0066c6c`、merge commit `6ffb095` で merge した。open PR / issue / GitHub Release は確認時点で0件。
- scanner は bounded process helper、Git/index/worktree/path/resource 境界、Windows Job / POSIX process-group cleanup、strict byte transport、固定診断、AST early-call gate、workflow exact envelope を共有する。
- fresh review で、PS5.1 healthy cold-start限定retry、direct PID + nonce provenance、全resource cleanupとprimary保持、単一deadline、native ownership、scan-wide timeout分類、conditional state dominance、reflective class activation拒否まで統合した。production Git timeout 15秒は不変。
- workflow 変更 PR はゲート①ではない。通常のローカル検証・review・current-head CI 後に merge できる。tag / GitHub Release / marketplace 公開の各ゲートは維持する。
- **T-013（Class M）は完了**。PR #28をsource commit `e78de08`、merge commit `c5d5da9`でmergeした。standard public `macos-latest`でnative `setsid(2)` fallbackを実測し、Gitのstrict inside-work-tree `true`＋empty prefixでmacOS system aliasを許容した。bare metadata root＋別`core.worktree`のfalse-cleanは回帰fixtureで拒否する。paid/private larger runnerは使用していない。
- **T-014（Class M）は完了**。PR #30をsource commit `357ce63`、merge commit `46c6e5c`でmergeした。公式確認済み`actions/checkout` v7.0.1 immutable commitへ更新し、3 jobすべてでcheckout credential persistenceを無効化した。exact validatorはactiveな`with`親だけを受理し、不正ネストや無空白suffixを拒否する。
- **T-015（Class M）は完了**。PR #33をsource commit `ef51a1b`、merge commit `cebe64d`でmergeした。scanner self-testがsystem temp全体の同一prefixを前後比較し、並列hostのisolation rootを自分の残骸と誤認するtest harness欠陥を、invocation固有tempと所有root限定cleanup監査で修正した。別host rootのsynthetic共存回帰を追加し、scanner判定本体は変更していない。

## 次の一手

1. **T-006 GitHub Release v0.2.0（ゲート①）**: owner の4点承認（version / target commit / 公開タイミング / notes本文）が揃うまで tag push / Release 作成をしない。
2. **T-006 承認後**: `.claude-plugin/plugin.json` と `claude plugin validate --strict` を別PRで追加する。実装PRは通常review/CIでmergeできるが、marketplace公開はゲート③。
3. **T-010（ゲート③）**: 上流 issue への紹介コメントは owner 承認まで行わない。

廃止済み integration や旧エージェント間メッセージングを復活させない。

## 検証

- freeze hash `2d524a9d09d2c40925dd5e5cd5ae9fec1d8b0e4f` の独立reviewは P0〜P3=0。PR current-head CI run 30222283213 と main push CI run 30222508500 は Windows / Ubuntu とも success。
- post-main: PowerShell 7 / Windows PowerShell 5.1 の full self-test・readiness・repo scan、Linux PowerShell 7.5 の network-none / read-only full self-test・readiness・repo scan・whitespaceを実測し pass。
- `git diff --check` pass。Gitleaks 8.30.1 は約632 KB・0 findings、Semgrep 1.165.0 は39 rules / 32 tracked files・0 findings。
- local / remote の T-012 task branch は削除済み。履歴保全用 `backup/018-main-pre-align-20260629` は削除しない。
- T-013: exact freeze `ccfac133`の独立reviewはP0〜P3=0。PR current-head run 30226964805はWindows / Ubuntu / macOSがsuccess。main push run 30227236800は初回Windows PS5.1のhealthy cold-start probe timeout後、failed-job attempt 2で3OSすべてsuccess。修正後のローカルcross-runtime full suiteとnative macOS `setsid(2)` fallbackを実測しpass。
- T-014: exact freeze tree `42f25e6a` / binary diff `a2c0a188`の独立reviewはP0〜P3=0。PR current-head run 30334673818とmerge commit `46c6e5c`のmain push run 30335030526はWindows / Ubuntu / macOSがすべてsuccess。post-mainはPowerShell 7とWindows PowerShell 5.1を直列実行し、readiness・scanner self-test・tracked scanをすべてpass。並列試行では同時self-testの隔離rootを相互検出したため、source failureと混同しない。
- T-015: exact freeze binary diff `097c2ca8` / raw diff `5a074b14`の独立reviewはP0〜P3=0。PowerShell 7 / Windows PowerShell 5.1のself-testを同時実行し、各221.2秒 / 150.4秒でpass。相互root誤検出なし、終了後の対象processは0。両hostのreadiness・tracked marker scan・whitespaceと`git diff --check`もpass。PR current-head run 30426480779とmerge commit `cebe64d`のmain push run 30426879546はWindows / Ubuntu / macOSがすべてsuccess。
