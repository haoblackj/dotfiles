#!/bin/bash
# UserPromptSubmit: ループ以外の対話セッションで、コンテキストが大きくなったことを、応答の最後に
# リーダーへ一言知らせるよう additionalContext で入れる。Claude からは引き継がない。
# 移る時機はリーダーが決め、「移って」と言われたときだけ session-handoff で移る（haoblackj/dotfiles#87 の決定。
# #73 の「40% で自分から引き継ぐ」を置き換えた）。Claude が時機を決めると引き継ぎの多くが作業の途中で起き、
# 途中で切ったあとはリーダーの言い直しと訂正が増えていたため（#87 の Q9、Q16）。
#
# 対話の段は context-level.sh の CHAT_CTX が statusline-context-window.sh のマーカーから決める。
#   40% と 60%: 依頼はいつもどおり進め、応答の最後に一言知らせる。
#   Herdr の中では「移って」と言えば移れること、外では状態を書き出して /clear できることを添える。
#   閾値は CONTEXT_GUARD_CHAT_HANDOFF_PCT と CONTEXT_GUARD_CHAT_URGENT_PCT で差し替えられる。
#   どちらも一度だけ出す。40% を下回ったら（compact のあとなど）、次に越えたときにまた出す。
# ループのセッション（context-level.sh の in_loop_session）では何もしない。ループの知らせと
# 引き継ぎは loop-guard.sh が受け持つ。
#
# サブエージェント内の入力（agent_id がある）では何もしない。
# 記録: ${XDG_STATE_HOME:-~/.local/state}/claude-chat-context-guard/decisions.log に、知らせのたびに
# 「時刻<TAB>session_id<TAB>判定<TAB>トークン数<TAB>使用率」を1行。
# fail-open: 入力が読めない、値が読めない、どの場合も黙って通す。

set -uo pipefail

INPUT=$(cat)
SID=$(jq -r '.session_id // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ "$SID" =~ ^[A-Za-z0-9._-]+$ && "$SID" != *..* ]] || exit 0
AGENT_ID=$(jq -r '.agent_id // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ -z "$AGENT_ID" ]] || exit 0
P=$(jq -r '.prompt // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ -n "$P" ]] || exit 0

T="${TMPDIR:-/tmp}"
# shellcheck source=context-level.sh
source "$(dirname "${BASH_SOURCE[0]}")/context-level.sh" 2>/dev/null || exit 0
in_loop_session "$P" && exit 0

GUARD_DIR="$T/claude-chat-context-guard"
HANDOFF_MARK="$GUARD_DIR/$SID.handoff"
URGENT_MARK="$GUARD_DIR/$SID.urgent"

[[ "$CHAT_CTX" == low ]] && rm -f -- "$HANDOFF_MARK" "$URGENT_MARK" 2>/dev/null

# 一度だけ（印のファイル $1）を使ったことにする。すでに使っていたら 1 を返す
take_once() {
  [[ -e "$1" ]] && return 1
  mkdir -p "$GUARD_DIR" 2>/dev/null && : > "$1" 2>/dev/null
  return 0
}

notify() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-chat-context-guard"
  { mkdir -p "$dir" &&
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SID" "notice:$1" \
      "${TOKENS:--}" "${PCT:--}" >> "$dir/decisions.log"; } 2>/dev/null
  jq -nc --arg c "[chat-context-guard] $2" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
  exit 0
}

# 知らせの文。$1 は段の名前（予備の閾値か、引き継ぎの閾値か）
notice_text() {
  local head
  head="$(printf '%s が%sを越えた。自分からは引き継がず、ターンも止めない。この依頼はいつもどおり進め、応答の最後に、コンテキストが大きくなったことを一言知らせる。' "$(ctx_desc)" "$1")"
  if [[ "${HERDR_ENV:-}" == 1 ]]; then
    printf '%s区切りで移るなら、リーダーが「移って」と言えばスキル `session-handoff` で新しいセッションへ移れる、と添える。' "$head"
  else
    printf '%s区切りで、状態（済んだこと、決定、次の一手）を書き出して /clear できる、と添える。' "$head"
  fi
}

if [[ "$CHAT_CTX" == urgent ]] && take_once "$URGENT_MARK"; then
  notify urgent "$(notice_text 'コンテキストの知らせの予備の閾値')"
fi
if [[ "$CHAT_CTX" == handoff ]] && take_once "$HANDOFF_MARK"; then
  notify handoff "$(notice_text 'コンテキストの知らせの閾値')"
fi
exit 0
