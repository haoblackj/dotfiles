---
paths:
  - "run_once_*.sh.tmpl"
  - "run_onchange_*.sh.tmpl"
  - "run_after_*.sh"
---

# run_once スクリプトの制約

- ファイル名: `run_once_NN_<name>.sh.tmpl`（NN は実行順の2桁数字）
- `.tmpl` テンプレート構文（`{{ .chezmoi.os }}` など）が使用可能
- **冪等に書くこと** — chezmoi はスクリプトの内容ハッシュが変わらない限り再実行しない
- **インタラクティブプロンプト禁止** — `-y` / `--non-interactive` / `DEBIAN_FRONTEND=noninteractive` を使う
- 導入済みの判定はテンプレート（`lookPath` 等）でなく、スクリプト内の実行時判定（`command -v`）で行う。
  テンプレートで分岐すると導入前後で内容ハッシュが変わり、導入後に一度「実行待ち」が出る
- WSL 判定はスクリプト内に書かない。ルート直下の `*.sh` は `.chezmoiignore` が
  `.isWSL` / `.isDevcontainer`（`.chezmoi.toml.tmpl` の data）で一括して除外する
- brew を使うスクリプトは冒頭に `{{ template "brew-env.sh" }}` を置く（`.chezmoitemplates/brew-env.sh`）
