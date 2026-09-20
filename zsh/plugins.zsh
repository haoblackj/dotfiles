# プラグインのインストールとロード
# zsh-completions は fpath を足すだけで、config.zsh の compinit より前に読む必要があるので同期で読む。
zinit light zsh-users/zsh-completions
# gh-fzf は $0 から自身のディレクトリを求めて ghf.bash を source する作りで、turbo モードでは
# $0 がプラグインのパスにならず落ちる（実測）。小さいので同期で読む。
zinit light atusy/gh-fzf

# 残りは turbo モード（wait）でプロンプト表示後に読む。起動時の待ちが減る代わりに、
# プロンプト直後の一瞬は色付けと候補表示が無く、読み込み完了時にまとめて付く。
# syntax-highlighting は他のウィジェットを定義した後に読む決まりなので末尾。
# autosuggestions は precmd に乗って起動するため、遅延読み込みでは atload で明示的に起動する。
zinit wait lucid for \
  atload'_zsh_autosuggest_start' zsh-users/zsh-autosuggestions \
  zsh-users/zsh-syntax-highlighting
