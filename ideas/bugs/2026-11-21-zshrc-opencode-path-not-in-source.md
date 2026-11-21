# ~/.zshrc の opencode の PATH の行がソースに無く、chezmoi apply で消える

## 見えたこと

PR #99 の取り込みの前に `chezmoi status` を読んだら `.zshrc` が `MM` だった。
`chezmoi diff ~/.zshrc` では、ホームの末尾にある `# opencode` と `export PATH=/home/yagu001/.opencode/bin:$PATH` の行がソースに無く、全体の `chezmoi apply` で消える側に出た。
同じ一覧に、apply で走るスクリプトとして `10_system-base.sh`（run_once）と `92_imozuru-serve.sh`（run_onchange）が `R` で出ていた。

## 見つけた場所

`~/.zshrc` と、本番のソース `~/.local/share/chezmoi/dot_zshrc.tmpl`。
