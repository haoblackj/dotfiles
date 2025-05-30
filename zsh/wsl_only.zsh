# Path設定
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.tfenv/bin:$PATH"
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
export DENO_INSTALL="/home/yagu001/.deno"
export PATH="$DENO_INSTALL/bin:$PATH"
export PATH=$HOME/bin:/usr/local/bin:$PATH
export PATH="$HOME/.local/bin:$PATH"


# Go実装のasdf用（v0.16.0 以降）
export PATH="$HOME/.asdf/bin:$PATH"

# ghq設定
function ghq_peco {
  local dir="$( ghq list -p | peco )"
  if [ ! -z "$dir" ] ; then
    cd "$dir"
    code .
  fi
}

# ghq cd設定
function ghq_peco_cd {
  local dir="$( ghq list -p | peco )"
  if [ ! -z "$dir" ] ; then
    cd "$dir"
  fi
}

# chezmoi設定
function chezmoi_edit {
    chezmoi edit
}
function chezmoi_apply {
    chezmoi apply
    echo "Chezmoi Apply Done!"
   echo "\n"

  zle reset-prompt
  return 0
}

# # xsel設定
# export DISPLAY=localhost:0.0

zle -N ghq_peco
zle -N ghq_peco_cd
zle -N chezmoi_edit
zle -N chezmoi_apply
bindkey '^:' ghq_peco_cd
bindkey '^]' ghq_peco
bindkey '^[' chezmoi_edit
bindkey '^\' chezmoi_apply

~/fix_wayland.sh