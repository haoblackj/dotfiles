#!/usr/bin/env bash

# 未定義な変数があったら途中で終了する
set -u

sudo nvm install --lts
node --version
npm --version
npm install --global yarn
yarn --version