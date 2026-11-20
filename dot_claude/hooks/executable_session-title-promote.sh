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
# 格上げする題は Haiku（claude -p）で 20 文字以内に縮める（haoblackj/dotfiles#91）。ai-title は
# 20〜30 文字になりやすく、そのままタブ名にすると長い。縮められなければ（claude が無い、時間切れ、
# 形に合わない答え）元の題を使う。呼び出しは 1 回 4〜12 秒（#91 で実測）で、格上げの 1 回だけ待つ。子の claude はフックを読まない設定で立て、
# CLAUDE_TITLE_SHORTEN_CHILD を渡して、この呼び出しが子の中で繰り返されないようにする。
#
# fail-open: 常に exit 0。

set -uo pipefail

[[ -n "${CLAUDE_TITLE_SHORTEN_CHILD:-}" ]] && exit 0

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

# transcript の最初のユーザーの発言（文字列か text の要素）を、先頭 300 文字まで出す。
first_user_prompt() { # $1 = transcript path
  records_of_type user "$1" | jq -rs '
    [.[] | .message.content
     | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join(" ")) end
     | select(. != "")][0] // "" | .[0:300]' 2>/dev/null
}

SHORTEN_PROMPT='セッションの題を、作業の中身を表す短い日本語の名前に言い換える。固有名詞は残し、補足の語は落とす。
例: 「Herdr のタブ名同期」「chezmoi 自動適用の失敗」「画像読込の高速化」「圧縮の空回り」「ログの日付の書式」「ビューアの 64bit 化」'

# 名前の形は指示でなく --json-schema で縛る。Haiku は文字数の指示を守らず、20 文字を超える答えが
# 8 回中 3 回あった（#91 で実測）。スキーマに合わない答えは CLI が受け付けない。
SHORTEN_SCHEMA='{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":20,"pattern":"^(?!.*引き継ぎ)(?!.*#[0-9])[^\\n\\r]+$"}},"required":["name"],"additionalProperties":false}'

# Haiku に短い名前を作らせる。$1 = 題の材料。作れたら名前を出して 0、だめなら 1。
shorten() {
  local out
  command -v claude >/dev/null 2>&1 || return 1
  out=$(cd / && CLAUDE_TITLE_SHORTEN_CHILD=1 timeout "${CLAUDE_TITLE_SHORTEN_TIMEOUT:-20}" \
    claude -p --model haiku --setting-sources "" --strict-mcp-config --no-session-persistence \
      --disable-slash-commands --tools "" --system-prompt "$SHORTEN_PROMPT" \
      --output-format json --json-schema "$SHORTEN_SCHEMA" "$1" 2>/dev/null) || return 1
  # CLI の検証をすり抜けた答えを使わないよう、同じ条件をここでも確かめる。
  out=$(jq -r '.structured_output.name // empty
    | select(length >= 1 and length <= 20 and (test("[\\n\\r]|#[0-9]") | not) and (contains("引き継ぎ") | not))' \
    <<< "$out" 2>/dev/null)
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
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
      PROMPT_HEAD=$(printf '%s' "$INPUT" | jq -r '.prompt // "" | .[0:300]' 2>/dev/null)
      SHORT=$(shorten "最初の発言: $PROMPT_HEAD") && TITLE="$SHORT"
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
    TITLE="$AI_TITLE"
    SHORT=$(shorten "題: $AI_TITLE
最初の発言: $(first_user_prompt "$TRANSCRIPT")") && TITLE="$SHORT"
    emit_title "$TITLE" && mark
    ;;
esac
exit 0
