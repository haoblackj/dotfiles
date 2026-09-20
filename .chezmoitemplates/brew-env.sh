# shellcheck shell=bash
# run_once スクリプトの冒頭で {{ template "brew-env.sh" }} として差し込む共通部。
# 非インタラクティブシェルでは .profile が読まれないため brew を PATH に追加
if [ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

export HOMEBREW_NO_AUTO_UPDATE=1
# Homebrew 7 以降は依存を伴う brew install が TTY 上で [y/n] を聞く（ask モード）。止める
export HOMEBREW_NO_ASK=1
