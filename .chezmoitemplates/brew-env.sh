# shellcheck shell=bash
# run_once スクリプトの冒頭から template 関数で差し込む共通部。このファイル自身も
# テンプレートとして展開されるので、ここに二重波括弧の構文を書くと自己参照で再帰する。
# 非インタラクティブシェルでは .profile が読まれないため brew を PATH に追加
if [ -x "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

export HOMEBREW_NO_AUTO_UPDATE=1
# Homebrew 7 以降は依存を伴う brew install が TTY 上で [y/n] を聞く（ask モード）。止める
export HOMEBREW_NO_ASK=1
