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
  echo "動作環境はWSLです"
  # wsl.confに対して
  sudo ln -snfv ${PWD}/wsl.conf /etc/wsl.conf
  sudo sed -i.bak_$(date +%Y%m%d%H%M) -r 's!deb http://archive\S+!deb mirror://mirrors.ubuntu.com/mirrors.txt!' /etc/apt/sources.list
  WINHOME=/mnt/c/Users/$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')
  echo ${WINHOME}
  cp -f .wslconfig ${WINHOME}/
  cp -f .gitconfig ${WINHOME}/
  cp -f ${PWD}/config.yml "${WINHOME}/Appdata/Roaming/GitHub CLI/config.yml"
  
  

  type wslview >/dev/null 2>&1
  if [ $? = 0 ]; then
  echo "wsluインストール済み"
  else
  echo "wsluインストール"
  sudo add-apt-repository ppa:wslutilities/wslu -y
  sudo apt update
  sudo apt install wslu -y
  fi

  type curl >/dev/null 2>&1
  if [ $? = 0 ]; then
  echo "パッケージインストール済み"
  else
  echo "パッケージインストールします"
  sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common \
    git \
    make \
    tig \
    tree \
    zip unzip
  echo "パッケージインストール完了"
  fi

  #type node >/dev/null 2>&1
  #if [ $? = 0 ]; then
  #echo "nodejsインストール済み"
  #else
  #echo "nodejsインストールします"
  #curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.2/install.sh | bash
  #source ./.bashrc
  #echo "nodejsインストール完了"
  #fi

  type gh >/dev/null 2>&1

  if [ $? = 0 ]; then
  echo "ghはインストール済み"
  else
  echo "ghインストールします"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt update -y
  sudo apt install gh -y
  sudo apt-get install fzf -y
  #sudo apt install gh=2.21.0 -y

  echo "ghインストール完了"


  fi
  type docker >/dev/null 2>&1

  if [ $? = 0 ]; then
  echo "Dockerはインストール済み"
  else
  read -n1 -p "Dockerをインストールしますか? (y/N): " yn
if [[ $yn = [yY] ]]; then
sudo ln -snfv ${PWD}/my-settings.service /etc/systemd/system/my-settings.service
sudo ln -snfv ${PWD}/my-settings.sh /usr/local/bin/my-settings.sh
sudo systemctl enable my-settings.service
sudo apt install -y ca-certificates curl gnupg lsb-release
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-compose-plugin
sudo service docker start
sudo usermod -aG docker $USER
sudo systemctl enable docker
else
  echo abort
  sudo service docker start
  sudo systemctl enable docker
fi
fi
type zsh >/dev/null 2>&1
  if [ $? = 0 ]; then
  echo "zshはインストール済み"
  else
  sudo apt install zsh -y
  chsh -s /usr/bin/zsh
  fi
type peco >/dev/null 2>&1
  if [ $? = 0 ]; then
  echo "pecoはインストール済み"
  else
  sudo add-apt-repository ppa:longsleep/golang-backports -y
  sudo apt install golang-go -y
  cd ~
  wget https://github.com/peco/peco/releases/download/v0.5.7/peco_linux_386.tar.gz
  tar xzvf peco_linux_386.tar.gz
  cd peco_linux_386
  sudo cp peco /usr/local/bin
  go install github.com/x-motemen/ghq@latest
  fi

fi
