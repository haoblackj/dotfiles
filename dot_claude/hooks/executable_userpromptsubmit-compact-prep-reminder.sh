#!/bin/bash
# UserPromptSubmit hook: threshold producer. transcript_path の直近usage+modelからcontext使用率を自前計算し、
# 閾値超過なら claude-compact-warn マーカファイルを書き込む（cooldown付き, one-shot的に1サイクル1回）。
# compact-plus プラグインの reminder hook が claude-compact-warn を消費し、ユーザーに通知する。
#
# VSCode拡張は statusLine コマンドを未サポートのため、statusLine には依存せず
# hook入力の transcript_path だけで完結させる設計にしている。
#
# コンテキストウィンドウ/警告閾値はモデル名から自動判定する:
#   claude-haiku-4-5*                                                → 200,000 tokens window
#   claude-fable-5* / mythos-5* / opus-4-* / sonnet-5* / sonnet-4-6* → 1,000,000 tokens window（標準1M、ベータ不要）
#   未知のモデル文字列（旧世代等）                                     → 200,000 tokens window（保守的デフォルト）
#   ウィンドウ >= 1,000,000 → 警告閾値60%、それ未満 → 85%
#     （60%は元記事の値。1M context前提なら60%到達時点でもまだ約400Kトークンの余力があり、
#      区切りまで作業を続ける余裕が十分にある。200K系では60%だと余力が少なすぎるため85%にする）
#
# overhead: cooldown中は marker file の test -f 1回で即 exit。
# fail-open (常に exit 0)

set -uo pipefail

model_context_window() { # $1 = model name
  case "$1" in
    claude-haiku-4-5*) echo 200000 ;;
    claude-fable-5*|claude-mythos-5*|claude-opus-4-*|claude-sonnet-5*|claude-sonnet-4-6*) echo 1000000 ;;
    *) echo 200000 ;;
  esac
}

default_threshold_for_window() { # $1 = context window tokens
  if [ "$1" -ge 1000000 ]; then
    echo 60
  else
    echo 85
  fi
}

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
# session_id は英数字・ドット・アンダースコア・ハイフンのみ許可(パストラバーサル対策)。
[[ -z "$SESSION_ID" || ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ || -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

# cooldown: compact-plus プラグインの reminder hook が書き込んだ claude-compact-warned を読む。
WARNED_MARKER="${TMPDIR:-/tmp}/claude-compact-warned/$SESSION_ID"
[[ -f "$WARNED_MARKER" ]] && exit 0

# 末尾から usage を含む最初の行を1件だけ取得(cache_read_input_tokensは累積値のため
# 直近1件がその時点のcontext使用量の近似値になる)。同じ行に model も乗っている。
USAGE_LINE=$(tac "$TRANSCRIPT" 2>/dev/null | grep -m1 '"usage"')
[[ -z "$USAGE_LINE" ]] && exit 0

MODEL_NAME=$(printf '%s' "$USAGE_LINE" | jq -r '.message.model // empty' 2>/dev/null)
DEFAULT_WINDOW=$(model_context_window "$MODEL_NAME")
CONTEXT_WINDOW="${CLAUDE_CONTEXT_WINDOW_TOKENS:-$DEFAULT_WINDOW}"
# 非数値・先頭ゼロ(桁数2以上、8進誤解釈の原因)の override は自動判定値にフォールバックする
# (fail-open。set -u 下での算術式クラッシュ・8進誤パース防止)。
# CONTEXT_WINDOW はさらに 0 も除外する(除数として使うためゼロ除算防止)。
[[ "$CONTEXT_WINDOW" =~ ^(0|[1-9][0-9]*)$ ]] || CONTEXT_WINDOW="$DEFAULT_WINDOW"
[[ "$CONTEXT_WINDOW" == "0" ]] && CONTEXT_WINDOW="$DEFAULT_WINDOW"
DEFAULT_THRESHOLD=$(default_threshold_for_window "$CONTEXT_WINDOW")
THRESHOLD="${CLAUDE_COMPACT_WARN_THRESHOLD:-$DEFAULT_THRESHOLD}"
[[ "$THRESHOLD" =~ ^(0|[1-9][0-9]*)$ ]] || THRESHOLD="$DEFAULT_THRESHOLD"

USED_TOKENS=$(printf '%s' "$USAGE_LINE" | jq -r '
  (.message.usage.input_tokens // 0) +
  (.message.usage.cache_creation_input_tokens // 0) +
  (.message.usage.cache_read_input_tokens // 0)
' 2>/dev/null)
[[ -z "$USED_TOKENS" || "$USED_TOKENS" == "null" ]] && exit 0

PCT=$(( USED_TOKENS * 100 / CONTEXT_WINDOW ))
[[ "$PCT" -lt "$THRESHOLD" ]] && exit 0

# Marker producer: PCT を claude-compact-warn に書き込む。
# compact-plus プラグインの reminder hook がこれを読み、ユーザーに通知する。
WARN_DIR="${TMPDIR:-/tmp}/claude-compact-warn"; WARN_MARKER="$WARN_DIR/$SESSION_ID"
[[ -f "$WARN_MARKER" ]] && exit 0
mkdir -p "$WARN_DIR" 2>/dev/null || true
printf '%s\n' "$PCT" > "$WARN_MARKER" 2>/dev/null || true
exit 0
