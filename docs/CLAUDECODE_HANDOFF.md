# 開発引き継ぎ — windows-github-auth-diagnosis

> **2026-07-11 方針更新**: 開発領域の固定分掌は廃止済み。このファイル名は既存リンクとの
> 互換性のため残す。開発の主軸は Codex で、依頼範囲を end-to-end で担当する。
> 廃止済みの `codex` / `codex-deep` MCP bridge と `agmsg` は復活させない。

作成日時: 2026/07/06 JST

本リポジトリは **public** repository。この文書を含め、`docs/` 配下の運用文書には
ローカル絶対パス、他リポジトリの内部情報、個人環境の詳細、token値・credential-bearing log
を書かない。

## 開発体制

- Codex が要件整理、PowerShell実装、検証、文書化までを一貫して進める。
- Claude Code、subagent、外部レビューは必要時の実行手段であり、固定担当ではない。

## repo 固有の現況

- 目的: Windows 上の Codex/agent/tool sandbox が Windows keyring を読めず GitHub 認証が
  壊れて見える偽陰性を、安全に診断するための Codex-style skill。`SKILL.md` が本体。
- 公開リポジトリ（OSS, MIT）。配布・普及フェーズに移行済み。
- 主要ファイル（reading order）:
  1. `README.md` — 概要、install 手順（Codex / Claude Code 双方）
  2. `HANDOFF.md` — Codex 側の現状サマリ、完了/未完了タスク、検証コマンド結果
  3. `TASKS_BACKLOG.md` — タスク一覧の正本（T-001〜T-010 他）
  4. `docs/CODEX_BRIEF_018_windows-github-auth-diagnosis.md` — Codex 向け自走運用ブリーフ
     （役割・権限・ゲート§10・自己検証手順の詳細）
  5. `docs/requirements-reassessment-2026-07.md` — 直近の要件再評価
  6. `docs/distribution-channel-research.md` / `docs/claude-plugin-marketplace-evaluation.md`
     / `docs/skills-sh-channel-evaluation.md` — 配布チャネル調査
  7. `SKILL.md` / `examples/` — スキル本体と synthetic examples
- 既存資料は現状把握の材料であり、要件定義の最終正本ではない。着手時は必ず
  `git status` / `git log` / `TASKS_BACKLOG.md` を一次情報として再確認すること。
  `HANDOFF.md` は更新が遅れやすいので齟齬があれば実際の git 状態を優先する。

## 次アクション候補（引き継ぎ時点）

1. **T-006（GitHub Release 発行）**: release brief/notes は準備済みだが、tag push・
   GitHub Release 作成・version 番号/target commit/公開タイミング/notes 本文の最終承認は
   owner 承認ゲート待ち（下記 Stop only when を参照）。
2. T-006 承認後: `.claude-plugin/plugin.json` 実装 PR（`claude plugin validate --strict` を
   CI/local 検証へ追加）と、README への配布導線追加 PR へ進む想定。
3. T-010（上流 issue への skill 紹介コメント投稿）は owner 承認ゲートとして blocked のまま。
   承認前に外部発信しない。
4. 着手前に `TASKS_BACKLOG.md` の最新状態と open PR/issue を再確認し、doing のタスクが
   あれば先に片付ける。

## Stop only when（費用・外部リスクの境界）

グローバル CLAUDE.md の Stop 条件に加え、本 repo 固有の境界:

- token 値・credential-bearing log を絶対に出力・保存・記録しない。診断は
  「keyring-capable 経路が生きているか」を確認するだけで、`gh auth login` /
  OAuth / トークン貼り付け / 認証情報リセットを安易に促さない（`SKILL.md` Core Rule）。
- GitHub Release 作成・tag push・plugin marketplace add/install・npm publish・
  上流 issue への外部発信は、version/target commit/公開タイミング/notes 本文の
  owner 承認が揃うまで実行しない（T-006/T-007/T-010 のゲート）。
- `.github/workflows/**` の変更はゲート対象（4ゲートの一つ）。マージ直前で停止し
  人間承認を取る。

## 委譲時の注意

委譲する場合は self-contained spec（対象ファイル・受け入れ条件・検証コマンド・書き込み許可範囲）
を渡し、成果物の実在と検証結果を主担当が確認する。本 repo は public のため、委譲プロンプト、
PR 本文、issue 本文に token 値、credential-bearing log、ローカル絶対パス、個人環境の詳細を含めない。

自己検証（`check:all` 相当）はこの repo では npm スクリプトではなく PowerShell 検証一式:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
git diff --check
```

`scan-private-markers.ps1` は作業ツリー全体（`.gitignore` 無視）を走査するため、
秘密値やローカル絶対パスを含むファイルは作業ツリーに置かないこと。
