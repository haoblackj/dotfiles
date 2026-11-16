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
# /clear の後は例外（haoblackj/dotfiles#12）。Claude Code は格上げした名前を新しい会話へ
# 引き継ぎ、名前付きのセッションには ai-title を生成しない。フックから名前は外せない
# （空の sessionTitle は無視される）ので、SessionStart の source が clear のときは
# 印の代わりに <session_id>.clear を置き、最初のプロンプトの先頭から題を作る。
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
CLEARED="$MARK.clear"

mark() {
  mkdir -p "$MARK_DIR" 2>/dev/null && : > "$MARK" 2>/dev/null
}

emit_title() { # $1 = title
  jq -nc --arg t "$1" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",sessionTitle:$t}}'
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
    SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)
    if [[ "$SOURCE" == clear ]]; then
      mkdir -p "$MARK_DIR" 2>/dev/null && : > "$CLEARED" 2>/dev/null
      exit 0
    fi
    TITLE=$(printf '%s' "$INPUT" | jq -r '.session_title // empty' 2>/dev/null)
    [[ -n "$TITLE" ]] && mark
    ;;
  UserPromptSubmit)
    [[ -f "$MARK" ]] && exit 0
    if [[ -f "$CLEARED" ]]; then
      # 最初の空でない行の空白を詰め、先頭30文字（コードポイント）に切る。
      TITLE=$(printf '%s' "$INPUT" | jq -r '
        [.prompt // "" | split("\n")[] | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
         | select(. != "")][0] // "" | .[0:30]' 2>/dev/null)
      [[ -n "$TITLE" ]] || exit 0
      emit_title "$TITLE" && mark
      exit 0
    fi
    TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
    [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || exit 0
    if [[ -n "$(records_of_type custom-title "$TRANSCRIPT" | head -n1)" ]]; then
      mark
      exit 0
    fi
    AI_TITLE=$(records_of_type ai-title "$TRANSCRIPT" | tail -n1 | jq -r '.aiTitle // empty' 2>/dev/null)
    [[ -n "$AI_TITLE" ]] || exit 0
    emit_title "$AI_TITLE" && mark
    ;;
esac
exit 0
