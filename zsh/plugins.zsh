# プラグインのインストールとロード
zinit light zsh-users/zsh-syntax-highlighting
zinit light zsh-users/zsh-autosuggestions
zinit light zsh-users/zsh-completions
zinit light atusy/gh-fzf
# powerlevel10k は .zshrc 側で `zinit ice depth=1` 付きで読み込んでいるため、ここは重複。
#zinit light romkatv/powerlevel10k