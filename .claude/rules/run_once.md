---
paths:
  - "run_once_*.sh.tmpl"
---

# run_once スクリプトの制約

- ファイル名: `run_once_NN_<name>.sh.tmpl`（NN は実行順の2桁数字）
- `.tmpl` テンプレート構文（`{{ .chezmoi.os }}` など）が使用可能
- **冪等に書くこと** — chezmoi はスクリプトの内容ハッシュが変わらない限り再実行しない
- **インタラクティブプロンプト禁止** — `-y` / `--non-interactive` / `DEBIAN_FRONTEND=noninteractive` を使う
- WSL判定: `{{ if eq .chezmoi.os "linux" }}` の中で `/proc/version` に `microsoft` が含まれるか確認する
