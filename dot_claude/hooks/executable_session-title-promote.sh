#!/bin/bash
# SessionStart / UserPromptSubmit hook: 自動生成のセッションタイトル（ai-title）を
# custom-title へ格上げし、入力欄の枠のチップに出す（haoblackj/dotfiles#11）。
#
# チップは custom-title しか表示しない。ai-title を渡すフックの入力欄は無いので、
# transcript の jsonl にある {"type":"ai-title","aiTitle":...} の最後の行を読む。
# jsonl の形式は内部仕様でバージョンごとに変わりうるため、読めなければ何もしない。
#
# 一度名前を付けたセッションには印（${TMPDIR:-/tmp}/claude-session-titled/<session_id>）
# を置き、二度は付けない。利用者が付けた名前を上書きしないよう、次の2つでも印を置く。
#   SessionStart:      入力の session_title がある（claude -n、名前付きセッションの resume）
#   UserPromptSubmit:  jsonl に custom-title の行がある（最初のプロンプト前の /rename）
#
# fail-open: 常に exit 0。

set -uo pipefail

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# session_id は英数字・ドット・アンダースコア・ハイフンのみ許可(パストラバーサル対策)。
[[ -z "$SESSION_ID" || ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] && exit 0

MARK_DIR="${TMPDIR:-/tmp}/claude-session-titled"
MARK="$MARK_DIR/$SESSION_ID"

mark() {
  mkdir -p "$MARK_DIR" 2>/dev/null && : > "$MARK" 2>/dev/null
}

# jsonl から指定した type の行だけを取り出す。grep で候補を絞ってから jq で type を
# 確かめる。本文中の同じ文字列はエスケープされているので grep の段で外れ、
# 書きかけの壊れた行は fromjson? で読み飛ばす。
records_of_type() { # $1 = type, $2 = transcript path
  grep -F "\"$1\"" "$2" 2>/dev/null |
    jq -c -R --arg t "$1" 'fromjson? | select(type == "object" and .type == $t)' 2>/dev/null
}

case "$EVENT" in
  SessionStart)
    TITLE=$(printf '%s' "$INPUT" | jq -r '.session_title // empty' 2>/dev/null)
    [[ -n "$TITLE" ]] && mark
    ;;
  UserPromptSubmit)
    [[ -f "$MARK" ]] && exit 0
    TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
    [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || exit 0
    if [[ -n "$(records_of_type custom-title "$TRANSCRIPT" | head -n1)" ]]; then
      mark
      exit 0
    fi
    AI_TITLE=$(records_of_type ai-title "$TRANSCRIPT" | tail -n1 | jq -r '.aiTitle // empty' 2>/dev/null)
    [[ -n "$AI_TITLE" ]] || exit 0
    jq -nc --arg t "$AI_TITLE" \
      '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",sessionTitle:$t}}' && mark
    ;;
esac
exit 0
