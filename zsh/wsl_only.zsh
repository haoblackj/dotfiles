# Path設定
export PATH="$HOME/.local/bin:$PATH"
# tfenv は未インストール（~/.tfenv が存在しない）。使い始めるときに戻す。
#export PATH="$HOME/.tfenv/bin:$PATH"
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
export DENO_INSTALL="/home/yagu001/.deno"
export PATH="$DENO_INSTALL/bin:$PATH"
export PATH=$HOME/bin:/usr/local/bin:$PATH
# 2行目と同じものを足していた重複。
#export PATH="$HOME/.local/bin:$PATH"


# Go実装のasdf用（v0.16.0 以降）
# asdf は未インストール（~/.asdf が存在しない）。使い始めるときに戻す。
#export PATH="$HOME/.asdf/bin:$PATH"

# ghq設定
# zle ウィジェットの中で cd してもプロンプトは描き直されないため、
# reset-prompt を呼んで表示中のカレントディレクトリを追従させる。
# $WIDGET はウィジェットとして呼ばれたときだけ定義される。関数として直接
# 実行したときに zle を呼ぶとエラーになるので、その場合は何もしない。
function ghq_peco {
  local dir="$( ghq list -p | peco )"
  if [ ! -z "$dir" ] ; then
    cd "$dir"
    code .
  fi
  (( ${+WIDGET} )) && zle reset-prompt
}

# ghq cd設定
function ghq_peco_cd {
  local dir="$( ghq list -p | peco )"
  if [ ! -z "$dir" ] ; then
    cd "$dir"
  fi
  (( ${+WIDGET} )) && zle reset-prompt
}

# # xsel設定
# export DISPLAY=localhost:0.0

zle -N ghq_peco
zle -N ghq_peco_cd
bindkey '^:' ghq_peco_cd
bindkey '^]' ghq_peco

~/fix_wayland.sh