setopt no_beep

function ghclone(){
  gh repo clone $(gh repo list $1 --json nameWithOwner -q '.[].nameWithOwner' | fzf)
}

function ghview(){
  gh repo view --web $(gh repo list $1 --json nameWithOwner -q '.[].nameWithOwner' | fzf)
}

## --------------------------------------------------
##  カレントディレクトリ表示（左）
## --------------------------------------------------

#PROMPT='
#%F{green}%(5~,%-1~/.../%2~,%~)%f
#%F{green}%B●%b%f'

## --------------------------------------------------
##  git branch状態を表示（右）
## --------------------------------------------------

#autoload -Uz vcs_info
#setopt prompt_subst

# --------------------------------------------------
#  コマンド入力補完
# --------------------------------------------------

# 補完機能有効にする
autoload -U compinit
compinit -u

# 補完候補に色つける
autoload -U colors
colors
zstyle ':completion:*' list-colors "${LS_COLORS}"

# 単語の入力途中でもTab補完を有効化
setopt complete_in_word
# 補完候補をハイライト
zstyle ':completion:*:default' menu select=1
# キャッシュの利用による補完の高速化
zstyle ':completion::complete:*' use-cache true
# 大文字、小文字を区別せず補完する
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'
# 補完リストの表示間隔を狭くする
setopt list_packed

# コマンドの打ち間違いを指摘してくれる
setopt correct
SPROMPT="correct: $RED%R$DEFAULT -> $GREEN%r$DEFAULT ? [Yes/No/Abort/Edit] => "

# Go Path設定
#export GOPATH=$HOME
#export PATH=$PATH:$GOPATH/bin
# export PATH=$PATH:/usr/local/go/bin

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
