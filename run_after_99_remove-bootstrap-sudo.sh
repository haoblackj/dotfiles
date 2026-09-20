#!/bin/sh
# run_once_10 が置いたブートストラップ用の NOPASSWD ドロップインを、apply のたびに末尾で撤去する。
# run_once_99 の末尾に置いていた頃は、10 を編集して再実行されるとドロップインが復活する一方、
# 内容の変わらない 99 は走らず、構築済みマシンに無認証 sudo が残った。
# 毎回走る run_after にすると、途中で中断した apply の後も次に完走した apply で消える。
# ドロップインが有効な間は sudo が無認証なので、ここでパスワードを聞かれることはない。
DROPIN=/etc/sudoers.d/00-chezmoi-bootstrap
[ -f "$DROPIN" ] || exit 0
sudo rm -f "$DROPIN"
