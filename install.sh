#!/usr/bin/env bash

# 未定義な変数があったら途中で終了する
set -u

DOT_DIRECTORY="${HOME}/dotfiles"
DOT_TARBALL="https://github.com/haoblackj/dotfiles/tarball/master"
REMOTE_URL="git@github.com:haoblackj/dotfiles.git"
# ディレクトリがなければダウンロード（と解凍）する
if [ ! -d ${DOT_DIRECTORY} ]; then
  echo "Downloading dotfiles..."
  mkdir ${DOT_DIRECTORY}

  if type "git" > /dev/null 2>&1; then
    git clone --recursive "${REMOTE_URL}" "${DOT_DIRECTORY}"
  else
    curl -fsSLo ${HOME}/dotfiles.tar.gz ${DOT_TARBALL}
    tar -zxf ${HOME}/dotfiles.tar.gz --strip-components 1 -C ${DOT_DIRECTORY}
    rm -f ${HOME}/dotfiles.tar.gz
  fi

  echo $(tput setaf 2)Download dotfiles complete!. ✔︎$(tput sgr0)
fi

# 今のディレクトリ
# dotfilesディレクトリに移動する
BASEDIR=$(dirname $0)
cd $BASEDIR

# check-head(commit-id)
CID0=`git log --pretty=format:"%H"|head -n 1`
echo $CID0
CID1=`git ls-remote origin HEAD|awk '{print $1}'`
echo $CID1

if [ $CID0 = $CID1 ]; then
  echo "Already up-to-date";
else
  git pull
fi


mkdir -p ~/.config/gh

export GH_CONFIG_DIR=~/.config/gh

ln -snfv ${PWD}/config.yml ~/.config/gh/

# dotfilesディレクトリにある、ドットから始まり2文字以上の名前のファイルに対して
for f in .??*; do
    [ "$f" = ".git" ] && continue
    [ "$f" = ".gitconfig.local.template" ] && continue
    [ "$f" = ".gitmodules" ] && continue

    # シンボリックリンクを貼る
    ln -snfv ${PWD}/"$f" ~/
done


if [ -n "$(which wslpath)" ]; then
  # WSLでのみ実行する処理
  WINHOME="$(wslpath "$(wslvar USERPROFILE)")"
  cp -f .wslconfig $WINHOME/
  cp -f ${PWD}/config.yml "$WINHOME/Appdata/Roaming/GitHub CLI/config.yml"
fi