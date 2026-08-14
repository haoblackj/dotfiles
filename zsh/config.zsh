setopt no_beep

# fzf を Esc で閉じると選択結果が空になる。そのまま gh へ渡すとエラーになるので黙って戻る。
function ghclone(){
  local repo
  repo=$(gh repo list $1 --json nameWithOwner -q '.[].nameWithOwner' | fzf) || return
  [[ -n $repo ]] || return
  gh repo clone $repo
}

function ghview(){
  local repo
  repo=$(gh repo list $1 --json nameWithOwner -q '.[].nameWithOwner' | fzf) || return
  [[ -n $repo ]] || return
  gh repo view --web $repo
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
#  コマンド履歴
# --------------------------------------------------

HISTFILE=~/.zsh_history
HISTSIZE=100000            # メモリ上に保持する件数
SAVEHIST=100000            # ファイルへ保存する件数

setopt inc_append_history  # 実行のたびに追記する（閉じ忘れても失われない）
setopt extended_history    # 実行時刻と所要時間も記録する
setopt hist_ignore_dups    # 直前と同じコマンドは記録しない
setopt hist_ignore_space   # 先頭が空白のコマンドは記録しない
setopt hist_reduce_blanks  # 余分な空白を詰めて記録する
setopt hist_verify         # 履歴展開の結果を実行前に確認できる

# --------------------------------------------------
#  コマンド入力補完
# --------------------------------------------------

# 自前で生成した補完定義の置き場。生成物なので chezmoi の管理下には置かない。
_zsh_comp_dir=~/zsh/completions
[[ -d $_zsh_comp_dir ]] || mkdir -p $_zsh_comp_dir
fpath=($_zsh_comp_dir $fpath)

# chezmoi は補完定義を配布していないので、初回だけ生成してキャッシュする
if [[ ! -f $_zsh_comp_dir/_chezmoi ]] && (( $+commands[chezmoi] )); then
  chezmoi completion zsh > $_zsh_comp_dir/_chezmoi
fi

# 補完機能を有効にする。plugins.zsh より後で1回だけ走らせること。
# ダンプが24時間以内なら compaudit を省いて起動を早める（実測 207ms -> 12ms）。
zmodload -F zsh/stat b:zstat
zmodload zsh/datetime
autoload -Uz compinit
_zcompdump=${ZDOTDIR:-$HOME}/.zcompdump
if zstat -A _zc +mtime $_zcompdump 2>/dev/null && (( EPOCHSECONDS - _zc[1] < 86400 )); then
  compinit -C -d $_zcompdump
else
  compinit -d $_zcompdump
fi
unset _zc _zcompdump _zsh_comp_dir

# zi 自身の補完（_comps は compinit の後でないと存在しない）
(( ${+_comps} )) && _comps[zi]=_zi

# pyenv は compctl 形式の補完を同梱しており、fpath 経由では読み込めない
if [[ -n $HOMEBREW_PREFIX && -r $HOMEBREW_PREFIX/opt/pyenv/completions/pyenv.zsh ]]; then
  source $HOMEBREW_PREFIX/opt/pyenv/completions/pyenv.zsh
fi

# 補完候補に色つける。
# dircolors を通さないと LS_COLORS が空のままで、下の list-colors が何も効かない。
autoload -U colors
colors
if [[ -z $LS_COLORS ]] && (( $+commands[dircolors] )); then
  eval "$(dircolors -b)"
fi
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
# $RED や $GREEN は zsh の colors が定義しない変数で、以前は空文字に展開されて
# 色がついていなかった。プロンプト展開の %F{...} を使う。
SPROMPT="correct: %F{red}%R%f -> %F{green}%r%f ? [Yes/No/Abort/Edit] => "

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

# ssh-agent設定(Bitwarden Desktop SSH Agent -> npiperelay/socat経由)
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/bitwarden-ssh-agent.sock"

# Homebrew一括アップデート関数
brewup() {
  # エラーが発生したらそこで中断する。
  # zsh の `set -e` は関数を抜けてもシェル全体に残り、以降コマンドが1つ失敗しただけで
  # 対話シェルが終了してしまう。localoptions を付けると関数を出た時点で元に戻る。
  setopt localoptions errexit
  echo "== brew update =="
  brew update
  echo ""

  echo "== brew upgrade (formula) =="
  brew upgrade
  echo ""

  echo "== brew upgrade (cask, greedy) =="
  brew upgrade --cask --greedy
  echo ""

  echo "== brew cleanup =="
  brew cleanup
  echo ""

  echo "== brew autoremove =="
  brew autoremove
  echo ""

  echo "✅ brew update all done"
}