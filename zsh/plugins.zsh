sh -c "$(curl -fsSL git.io/get-zi)" --

zinit light zsh-users/zsh-syntax-highlighting

zinit light zsh-users/zsh-autosuggestions

zinit light zsh-users/zsh-completions

zinit load atusy/gh-fzf

# Load the pure theme, with zsh-async library that's bundled with it.
#zinit ice pick"async.zsh" src"pure.zsh"
#zinit light sindresorhus/pure