# Claude Code plugin marketplace evaluation

確認日: 2026-06-30 JST

## 結論

このリポジトリは現状の `SKILL.md` 配布だけで Claude Code の user/project skill として利用できる。Claude Code plugin marketplace 配布へ進むには `.claude-plugin/` 配下の manifest と marketplace metadata を追加する必要があり、これは配布物構成の新設に当たるため、T-006 の release 承認後に別PRで扱う。

本評価では `.claude-plugin/`、tag、GitHub Release、marketplace 登録、plugin install/update は作成・実行していない。

## 確認した情報源

| 情報源 | 確認内容 |
| --- | --- |
| Claude Code plugin docs (`https://code.claude.com/docs/en/plugins`) | plugin / marketplace の基本構成、manifest、install/update 導線 |
| `claude --version` | ローカル CLI は `2.1.193 (Claude Code)` |
| `claude plugin --help` | `init`, `install`, `list`, `marketplace`, `tag`, `validate`, `update` などの非対話 help を確認 |
| `claude plugin marketplace --help` | marketplace の `add`, `list`, `remove`, `update` を確認 |
| `claude plugin validate --help` | `--strict` で warning を error にできることを確認 |
| `claude plugin init --help` | scaffold 先は user skill directory 側であり、repo内 `.claude-plugin/` 作成には別設計が必要なことを確認 |
| `claude plugin marketplace add --help` | `--scope user/project/local` と `--sparse` を確認 |

## 評価結果

- Plugin marketplace として配布する場合、Git repository 側に `.claude-plugin/marketplace.json` が必要になる。
- 個別 plugin は `.claude-plugin/plugin.json` で `name`, `version`, `description`, `author`, `homepage` などの metadata を宣言する必要がある。
- Plugin は `skills/` などの component を同梱できるが、この repo は現在 `SKILL.md` を root に置く Codex/Claude Code skill repository として成立している。
- そのまま `.claude-plugin/` を追加すると、既存の skill repository に新しい配布面が増える。release notes / tag 承認前に混ぜると、T-006 の公開判断と T-007 の配布構成判断が分離しにくくなる。
- `claude plugin validate --strict <path>` は、将来 `.claude-plugin/` を追加したときの deterministic gate として CI / local validation に組み込める。
- `claude plugin tag [path]` は release tag 作成に関係するため、T-006 の version / target commit 承認前には実行しない。
- `claude plugin marketplace add` / `install` / `update` は user/project/local の設定変更や外部 repository 取得を伴うため、この評価PRでは実行しない。

## 推奨方針

1. T-006 を先に完了し、`v0.2.0` の version、target commit、公開タイミング、release notes 本文を owner が承認する。
2. その後、T-007 実装PRとして `.claude-plugin/plugin.json` と必要なら `.claude-plugin/marketplace.json` を追加する。
3. 実装PRでは `claude plugin validate --strict .` または manifest path 指定を検証コマンドに追加する。
4. Marketplace を同一 repo に持たせるか、将来の複数 plugin 配布を見越して別 marketplace repo に分けるかを PR 内で明示する。
5. `claude plugin tag`、GitHub Release、marketplace add/install smoke は、version / target commit / 公開タイミングの承認後にだけ実行する。

## 未実施

- `.claude-plugin/` 作成
- `claude plugin init` 実行
- `claude plugin validate --strict` の実 plugin/marketplace 対象実行
- `claude plugin tag`
- `claude plugin marketplace add`
- `claude plugin install`
- GitHub Release / tag push
- Marketplace 公開または第三者への配布 smoke
