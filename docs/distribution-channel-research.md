# Distribution channel research

確認日: 2026-06-30 JST

## 結論

このリポジトリの配布順序は、まず GitHub Release を正本にし、その後に Claude Code plugin marketplace 対応を別PRで追加するのが安全である。npm などの package registry 配布は、現時点では優先しない。`SKILL.md` が単体で成立する skill repository であり、package registry は login、token、2FA、package ownership、公開後の撤回制約など、T-006の承認待ちより大きい運用面を増やすためである。

本調査では release 作成、tag push、npm publish、package metadata 作成、Claude plugin install、marketplace add、外部配布 smoke は実行していない。

## 確認した情報源

| 情報源 | 確認内容 |
| --- | --- |
| GitHub Docs: Managing releases in a repository (`https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository`) | GitHub Release は tag と release notes / assets を紐づける公開単位として使える |
| Claude Code plugin docs (`https://code.claude.com/docs/en/plugins`) | Claude Code plugin / marketplace は `.claude-plugin/` manifest と `claude plugin validate` / install 導線で扱う |
| npm Docs: Creating and publishing scoped public packages (`https://docs.npmjs.com/creating-and-publishing-scoped-public-packages`) | public package publication には package metadata、account / auth、publish 操作が関わる |
| 既存repo docs | `README.md` の Codex / Claude Code manual install と、`docs/release-v0.2.0-brief.md` / `docs/release-v0.2.0-notes-draft.md` の v0.2.0 release準備 |

## チャネル比較

| チャネル | 役割 | 現状 | 次に必要なこと | 実行可否 |
| --- | --- | --- | --- | --- |
| GitHub Release | v0.2.0 の正本。tag、release notes、source archive をまとめる | `docs/release-v0.2.0-brief.md` と draft notes は準備済み | owner が version、target commit、公開タイミング、notes本文を承認する | 承認まで未実行 |
| Git clone / manual skill install | Codex / Claude Code user/project skill として今すぐ読める配布形態 | README に install 手順あり | Release 後に README の推奨 version / tag 参照を必要なら更新する | docs更新のみ可、実配布はRelease後 |
| Claude Code plugin marketplace | Claude Code利用者向けの discoverable な配布面 | T-007評価済み。`.claude-plugin/` は未作成 | Release承認後に manifest / marketplace metadata を別PRで追加し、`claude plugin validate --strict` をgateにする | 構成新設と実installは未実行 |
| npm package | package manager 経由の配布 | 現repoはNode packageではなく単体 skill docs/scripts repo | package設計、publish方針、auth/2FA/token運用、secret除外、package ownershipを別途決める | 現時点では非推奨 |
| Template / copied repository | forkやtemplateで導入しやすくする補助導線 | READMEのclone/installで足りている | 必要になったら GitHub template 化や examples強化を検討 | 低優先 |

## 推奨ロードマップ

1. T-006: owner承認後に GitHub Release / tag を作成する。
2. Release 後: README の install手順に推奨 release tag 参照を追加するか判断する。
3. T-007実装PR: `.claude-plugin/plugin.json` と必要なら `.claude-plugin/marketplace.json` を追加し、`claude plugin validate --strict` を検証に入れる。
4. Marketplace smoke: owner承認後に `claude plugin marketplace add` / `claude plugin install` を最小scopeで確認する。
5. Package registry: CLIや配布用packageが必要になった場合だけ再検討する。現状の `SKILL.md` 配布ではnpm publishを急がない。

## 未実施

- GitHub Release作成
- tag push
- release asset upload
- `.claude-plugin/` 作成
- `claude plugin validate --strict` の実manifest検証
- `claude plugin marketplace add`
- `claude plugin install`
- `npm init` / package metadata作成
- `npm publish`
- package registry account / token / 2FA 操作
- 外部配布先への smoke test
