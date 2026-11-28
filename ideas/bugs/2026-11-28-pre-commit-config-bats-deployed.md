# chezmoi status がリポジトリ直下の pre-commit-config.bats を配る対象として出す

## 見えたこと

2026-11-28 に本番の作業コピーを main（6f54936）へ進めたあと `chezmoi status` を打つと、` A pre-commit-config.bats` が出た（ホームの `~/pre-commit-config.bats` として配られる対象）。
同じ出力に ` M .config/tsuzuri/words.tsv` もあった（ソースと配置先の中身が違う）。どちらも外から取ってくるスキルの作業とは関係が無いので、全体の `chezmoi apply` は流さず、作業のファイルだけを名指しで配った。

## 見つけた場所

- リポジトリ直下の `pre-commit-config.bats` と `.chezmoiignore`
- `~/.config/tsuzuri/words.tsv` と `dot_config/tsuzuri/words.tsv`
