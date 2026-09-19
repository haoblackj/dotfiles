# run_once の lookPath 分岐でツール導入後に毎回「実行待ち」が出る

## 見えたこと

WSL 再構築の完走後、再起動して zsh に入ると、chezmoi のドリフトチェックが
`R 60_languages.sh`（実行待ち、ドリフトではない）を出した。

`run_once_60_languages.sh.tmpl` はテンプレートで `lookPath "go"` / `lookPath "deno"` を見て
「install する版」と「済を echo する版」に分岐している。ブートストラップ時と導入後で
レンダリング結果（＝内容ハッシュ）が変わるため、ツール導入後に一度だけ run_once が
「未実行」と判定されて実行待ちに出る。中身は「済」を echo するだけの no-op なので
`chezmoi apply` で無害に消えるが、毎回の新規構築でこの pending が出るのが煩わしい。

## 見つけた場所

- `run_once_30_linuxbrew.sh.tmpl`（`lookPath "brew"`）
- `run_once_40_python-env.sh.tmpl`（`lookPath "pyenv"`）
- `run_once_60_languages.sh.tmpl`（`lookPath "go"` / `lookPath "deno"`）
- `run_once_70_editors-containers.sh.tmpl`（`lookPath "nvim"` / `lookPath "docker"`）

対して `run_once_50_node-env.sh.tmpl` はスクリプト内の実行時チェック
（`[ -s "$HOME/.nvm/nvm.sh" ]`）でやっていてハッシュが安定し、pending を出さない。
30/40/60/70 も同様に実行時 `command -v` 判定へ寄せれば pending は消えるはず（未検証）。
