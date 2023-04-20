#!/usr/bin/env bash

# 未定義な変数があったら途中で終了する
set -u

sh -c "$(curl -fsLS get.chezmoi.io)"
chezmoi init --apply haoblackj