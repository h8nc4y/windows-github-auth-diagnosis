# CODEX_START_HERE — 018_windows-github-auth-diagnosis

> 全リポジトリ共通の「Codex 引き継ぎの入口」ファイル(2026-07-15 標準化)。
> どのリポジトリでも本ファイルを読めば、正本の所在と着手手順が分かる。

## このリポジトリは何か

Windows sandboxのGitHub認証偽陰性を診断する公開OSSのagent skill。

## 読み順(正本)

1. `README.md` — 概要(公開導線)
2. `docs/AGENT_BRIEF.md` — 運用正本(ゲート・検証手順)
3. `HANDOFF.md` — 現在地サマリ
4. `TASKS_BACKLOG.md` — タスク台帳
5. `docs/requirements-reassessment-2026-07.md` — 要件・配布戦略

## 検証コマンド

docs/AGENT_BRIEF.md §5 の検証スイート(readiness/scanner self-test/marker scan/diff --check)

## 主要 gate(承認なしに越えない境界)

- credential保存・根拠なきrotate/reset助言は恒久Non-Goal
- Release/配布はスコープ内だが公開前スキャン必須

## 次の一手

上記読み順の「現況」資料(HANDOFF 等)の「次の一手」節が正本。本ファイルには時点情報を書かない。

---
運用注記: 開発領域の固定分掌は 2026-07-11 に廃止済み(開発の主軸は Codex、要件・設計・実装・検証・docs を end-to-end で担当)。本ファイルは薄い入口に保ち、現在地・タスクは正本側を更新する。
