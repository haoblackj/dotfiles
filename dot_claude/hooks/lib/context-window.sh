# shellcheck shell=bash
# コンテキストの警告閾値の判定。source して使う共有ライブラリ。
# userpromptsubmit-compact-prep-reminder.sh から読む。
# 実行はしないため shebang も実行権限も持たせない。呼び出し元は #!/bin/bash なので、
# shebangの代わりにこのディレクティブで対象shellを明示する。
#
# 窓幅は statusline-context-window.sh が Claude Code 本体の context_window_size を
# マーカーに書いたものを使う。モデル名から窓幅を推測する表（claude-opus-5 → 200K 等）は
# 2026-09-12 に撤去した。推測は /model の切替や新モデルで外れ、外れると
# 使用率の分母が違う警告を出す。読む側が無くなった sessionstart-context-window.sh も同時に撤去。

default_threshold_for_window() { # $1 = context window tokens
  # 60%は元記事の値。1M context前提なら60%到達時点でもまだ約400Kトークンの余力があり、
  # 区切りまで作業を続ける余裕が十分にある。200K系では60%だと余力が少なすぎるため85%にする。
  if [ "$1" -ge 1000000 ]; then
    echo 60
  else
    echo 85
  fi
}
