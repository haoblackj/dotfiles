# コンテキストウィンドウ幅と警告閾値の判定。source して使う共有ライブラリ。
# sessionstart-context-window.sh と userpromptsubmit-compact-prep-reminder.sh の両方から読む。
# 実行はしないため shebang も実行権限も持たせない。
#
# モデル名から標準ウィンドウ幅を判定する:
#   claude-haiku-4-5* / claude-opus-5*                               → 200,000 tokens
#   claude-fable-5* / mythos-5* / opus-4-* / sonnet-5* / sonnet-4-6* → 1,000,000 tokens
#   未知のモデル文字列（旧世代等）                                     → 200,000 tokens（保守的デフォルト）
#
# 1Mベータを有効にしたセッションではモデル名に [1m] サフィックスが付く
# （実測値: claude-opus-5[1m]）。この場合は上の表より優先して 1,000,000 とする。

model_context_window() { # $1 = model name
  case "$1" in
    claude-haiku-4-5*|claude-opus-5*) echo 200000 ;;
    claude-fable-5*|claude-mythos-5*|claude-opus-4-*|claude-sonnet-5*|claude-sonnet-4-6*) echo 1000000 ;;
    *) echo 200000 ;;
  esac
}

context_window_for_model() { # $1 = model name
  case "$1" in
    *'[1m]'*) echo 1000000 ;;
    *) model_context_window "$1" ;;
  esac
}

default_threshold_for_window() { # $1 = context window tokens
  # 60%は元記事の値。1M context前提なら60%到達時点でもまだ約400Kトークンの余力があり、
  # 区切りまで作業を続ける余裕が十分にある。200K系では60%だと余力が少なすぎるため85%にする。
  if [ "$1" -ge 1000000 ]; then
    echo 60
  else
    echo 85
  fi
}
