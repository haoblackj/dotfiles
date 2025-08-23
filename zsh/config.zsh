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

# pyenv設定
export PYENV_ROOT="${HOME}/.pyenv"
if [ -d "${PYENV_ROOT}" ]; then
    export PATH=${PYENV_ROOT}/bin:$PATH
    eval "$(pyenv init -)"
    eval "$(pyenv virtualenv-init -)"
fi

# gh設定
export GH_CONFIG_DIR=~/.config/gh

# tfenv設定
export PATH="$HOME/.tfenv/bin:$PATH"

# ssh-agent設定
agent_file="$HOME/.ssh/agent.env"

# 既存の ssh-agent が動いていれば再利用
if [ -f "$agent_file" ]; then
    source "$agent_file" > /dev/null
    if ! kill -0 "$SSH_AGENT_PID" 2>/dev/null; then
        eval "$(ssh-agent -s)" > "$agent_file"
    fi
else
    eval "$(ssh-agent -s)" > "$agent_file"
fi
