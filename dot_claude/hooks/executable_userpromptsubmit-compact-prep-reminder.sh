#!/bin/bash
# UserPromptSubmit hook: transcript_path の直近usage+modelからcontext使用率を自前計算し、
# 閾値超過なら additionalContext で /compact-prep 実行を提案する（cooldown付き, one-shot的に1サイクル1回）。
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
[[ -z "$SESSION_ID" || -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

WARNED_DIR="${TMPDIR:-/tmp}/claude-compact-warned"
WARNED_MARKER="$WARNED_DIR/$SESSION_ID"
[[ -f "$WARNED_MARKER" ]] && exit 0

# 末尾から usage を含む最初の行を1件だけ取得(cache_read_input_tokensは累積値のため
# 直近1件がその時点のcontext使用量の近似値になる)。同じ行に model も乗っている。
USAGE_LINE=$(tac "$TRANSCRIPT" 2>/dev/null | grep -m1 '"usage"')
[[ -z "$USAGE_LINE" ]] && exit 0

MODEL_NAME=$(printf '%s' "$USAGE_LINE" | jq -r '.message.model // empty' 2>/dev/null)
DEFAULT_WINDOW=$(model_context_window "$MODEL_NAME")
CONTEXT_WINDOW="${CLAUDE_CONTEXT_WINDOW_TOKENS:-$DEFAULT_WINDOW}"
# 非数値の override は自動判定値にフォールバックする(fail-open。set -u 下での算術式クラッシュ防止)
[[ "$CONTEXT_WINDOW" =~ ^[0-9]+$ ]] || CONTEXT_WINDOW="$DEFAULT_WINDOW"
DEFAULT_THRESHOLD=$(default_threshold_for_window "$CONTEXT_WINDOW")
THRESHOLD="${CLAUDE_COMPACT_WARN_THRESHOLD:-$DEFAULT_THRESHOLD}"
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || THRESHOLD="$DEFAULT_THRESHOLD"

USED_TOKENS=$(printf '%s' "$USAGE_LINE" | jq -r '
  (.message.usage.input_tokens // 0) +
  (.message.usage.cache_creation_input_tokens // 0) +
  (.message.usage.cache_read_input_tokens // 0)
' 2>/dev/null)
[[ -z "$USED_TOKENS" || "$USED_TOKENS" == "null" ]] && exit 0

PCT=$(( USED_TOKENS * 100 / CONTEXT_WINDOW ))
[[ "$PCT" -lt "$THRESHOLD" ]] && exit 0

mkdir -p "$WARNED_DIR" 2>/dev/null || true
printf '%s\n' "$(date +%s)" > "$WARNED_MARKER" 2>/dev/null || true

CTX="[COMPACT PREP REMINDER] context 使用率が約 ${PCT}%（推定 ${USED_TOKENS}/${CONTEXT_WINDOW} tokens）に達した。"
CTX+=$'\n'"- 作業区切りでユーザーに \`/compact-prep\` の実行を提案せよ。"
CTX+=$'\n'"- \`/compact-prep\` 実行後、ユーザーに \`/compact\` 実行を案内せよ。"
CTX+=$'\n'"- scope 縮小や別セッション化ではなく、圧縮前 state 保存で対処せよ。"

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
exit 0
