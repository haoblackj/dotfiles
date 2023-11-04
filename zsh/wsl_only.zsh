# Path設定
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.tfenv/bin:$PATH"
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
export DENO_INSTALL="/home/yagu001/.deno"
export PATH="$DENO_INSTALL/bin:$PATH"
export PATH=$HOME/bin:/usr/local/bin:$PATH

# asdf Path設定
. "$HOME/.asdf/asdf.sh"

# ghq設定
function ghq_peco {
  local dir="$( ghq list -p | peco )"
  if [ ! -z "$dir" ] ; then
    cd "$dir"
    code .
  fi
}
zle -N ghq_peco
bindkey '^]' ghq_peco
