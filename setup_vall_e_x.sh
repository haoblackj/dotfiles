#!/bin/bash

# スクリプトの失敗時に停止するための設定
set -e

sudo apt -y install --no-install-recommends make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm libncurses5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
cd /tmp
curl https://pyenv.run | bash

# CUDAの最新安定版のインストール
echo "CUDAのインストールを開始します..."
wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get -y install cuda-toolkit-12-3

# NVIDIA Container Toolkitのインストール
echo "NVIDIA Container Toolkitのインストールを開始します..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
sudo apt install -y nvidia-container-toolkit

# Dockerデーモンの再起動
sudo systemctl restart docker

# ffmpegのインストール
echo "ffmpegのインストールを開始します..."
sudo apt-get install -y ffmpeg

echo "動作環境のインストールが完了しました。"

echo "vall-e-xのインストールを開始します..."
# vall-e-xのインストール
cd ~
git clone https://github.com/Plachtaa/VALL-E-X.git
cd VALL-E-X
# pyenvを使用してPython 3.10.11をインストール
echo "Python 3.10.11をインストールします..."
pyenv install 3.10.11

# ローカルディレクトリでPythonのバージョンを設定
echo "ローカルディレクトリでPython 3.10.11を使用するよう設定します..."
pyenv local 3.10.11
pip install -r requirements.txt
