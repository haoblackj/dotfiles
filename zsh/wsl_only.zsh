# Path設定
export PATH="$HOME/.local/bin:$PATH"

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

function bw_set_session {
  local session_key
  session_key="$(bw unlock --raw)"
  export BW_SESSION="$session_key"
  echo "Session key set."
}

function bw_get_item {
  if [[ -z "$BW_SESSION" ]]; then
    echo "No session key found. Running bw_set_session..."
    bw_set_session
  fi

  local item_name="$1"
  local item_field="$2"
  local item_value
  item_value="$(bw get $item_field $item_name --session $BW_SESSION)"
  echo "$item_value"
}
