#!/bin/bash
# SessionStart hook: 入力JSONの model からコンテキストウィンドウ幅を判定し、
# ${TMPDIR:-/tmp}/claude-context-window/$SESSION_ID に書き込む。
#
# UserPromptSubmit hook には model が渡らない（公式ドキュメント上、model を受け取れるのは
# SessionStart だけで、それも存在は保証されない）。警告hook側はこのマーカーを読んで窓幅を決める。
#
# stdout には何も出さない。SessionStart の stdout は additionalContext として会話に注入されるため。
# fail-open (常に exit 0)

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/context-window.sh
. "$HOOK_DIR/lib/context-window.sh" 2>/dev/null || exit 0

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# 実測では model は文字列で渡る（claude-opus-5[1m]）。将来 object 化した場合に備えて .model.id も見る。
MODEL=$(printf '%s' "$INPUT" | jq -r '
  if (.model | type) == "object" then (.model.id // empty) else (.model // empty) end
' 2>/dev/null)

# session_id は英数字・ドット・アンダースコア・ハイフンのみ許可(パストラバーサル対策)。
[[ -z "$SESSION_ID" || ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ || -z "$MODEL" ]] && exit 0

WINDOW=$(context_window_for_model "$MODEL")
[[ "$WINDOW" =~ ^[1-9][0-9]*$ ]] || exit 0

WINDOW_DIR="${TMPDIR:-/tmp}/claude-context-window"
mkdir -p "$WINDOW_DIR" 2>/dev/null || exit 0
printf '%s\n' "$WINDOW" > "$WINDOW_DIR/$SESSION_ID" 2>/dev/null || true
exit 0
