# skills.sh channel evaluation (T-009)

確認日: 2026-07-03 JST
作成: Claude Fable5（Web調査はサブエージェント、2026-07-03実施）

## 結論

skills.sh（vercel-labs/skills、`npx skills add`）は、本リポジトリの現構成（root直下 `SKILL.md`）のまま登録作業ゼロで機能する配布チャネルである。`npx skills add h8nc4y/windows-github-auth-diagnosis` は owner/repo 短縮形の直接installとして掲載前でも動作する見込みで、ディレクトリ/リーダーボードへの掲載はユーザーのinstall実績（CLI匿名テレメトリ）経由で自動反映される。明示的なsubmit手順は存在しない。

推奨: T-006 GitHub Release 承認・実施後に、README のinstall手順へ `npx skills add` コマンドを追記する（別PR）。install数バッジの追加は任意。本評価では掲載・install・バッジ追加のいずれも実行していない。

## 確認した情報源

| 情報源 | 確認内容 |
| --- | --- |
| skills.sh docs (`https://www.skills.sh/docs`) | submit不要・テレメトリ経由の自動掲載、install数バッジ、レビュー責任はユーザー側の原則 |
| vercel-labs/skills README（GitHub、URLはscanner許可リスト外のため省略） | owner/repo短縮形・フルURL・パス指定でのinstall、root直下SKILL.mdの認識、`--list` プレビュー、`update` / `remove` サブコマンド |

## 評価結果

- 掲載の仕組み: submit（PR/フォーム/CLI登録）は不要。公開GitHub repoに `SKILL.md` があれば、ユーザーが `npx skills add` した実績がテレメトリ経由でディレクトリに反映される。初回反映までの遅延や最低install数の閾値は未確認。
- 構成要件: root直下 `SKILL.md` は探索対象として明記されており、`skills/` ディレクトリへの移行は不要。現構成のままでよい。
- インストール: `npx skills add h8nc4y/windows-github-auth-diagnosis` で Claude Code / Codex を含む複数エージェント向けにinstallできる。`--list` で事前プレビュー可能。
- 更新: git-based。ユーザー側の `npx skills update` がrepo最新を再取得する。リリース版の固定はrepo側のtag運用に依存するため、GitHub Release（T-006）を正本とする方針と整合する。
- メトリクス: リーダーボードでinstall数が公開される。READMEにinstall数バッジ（`https://skills.sh/b/<owner>/<repo>` 形式）を貼れる。
- 撤回: `npx skills remove` はユーザー側のアンインストールであり、ディレクトリ掲載自体の撤回・削除手順は確認できなかった（未確認）。repo削除で新規installは止まるが、掲載エントリの扱いは不明。
- 規約・モデレーション: 明確な掲載規約・ライセンス要件は確認できず、「installする前にskillをレビューせよ」というユーザー責任原則のみ。悪用時のdelistingポリシー詳細、テレメトリの正確な収集内容は未確認。
- 名前空間: `owner/repo` ベースのため名前衝突リスクは実質ない。

## リスク評価と判断

- 本リポジトリは配布物が公開済みMarkdown+検証スクリプトのみで、掲載により新たに露出する情報はない。撤回手段が不明な点が唯一の留意点だが、公開済みOSSの性質上、実害シナリオは限定的。
- 登録操作が存在しないため「掲載する/しない」の能動的判断は不要で、実質的な意思決定は **READMEに `npx skills add` 導線を載せるかどうか** に集約される。これはRelease後のREADME更新PR（軽量・可逆）として扱う。

## 未実施

- `npx skills add` の実行（install smoke）
- README への install コマンド・バッジ追加
- skills.sh 上の掲載確認・リーダーボード確認
- テレメトリ内容の実測
