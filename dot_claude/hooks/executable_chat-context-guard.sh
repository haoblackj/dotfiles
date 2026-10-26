#!/bin/bash
# UserPromptSubmit: ループ以外の対話セッションで、自動の compact より先に、状態を書き出して /clear へ
# 誘導する知らせを additionalContext で入れる（haoblackj/dotfiles#71）。
# compact は要約で何を落とすか読めず、コンテキストが長いほど毎回の呼び出しで送り直す量も増えるため。
# フックからは /clear も /compact も打てない（公式の hooks）ので、打つのはリーダー。
#
# コンテキストの段は context-level.sh が statusline-context-window.sh のマーカーから決める。
# 閾値は loop-guard.sh と共有する。
#   一段目: 依頼を片付けたあと、状態の書き出しと /clear を勧めさせる。
#   二段目: 依頼に入る前に状態を書き出させ、/clear を勧めて止まらせる。続けるよう言われたら従う。
#   どちらも一度だけ出す。一段目を下回ったら（compact のあとなど）、次に越えたときにまた出す。
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
STATE_MARK="$GUARD_DIR/$SID.state"
HANDOFF_MARK="$GUARD_DIR/$SID.handoff"

[[ "$CTX" == low ]] && rm -f -- "$STATE_MARK" "$HANDOFF_MARK" 2>/dev/null

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

if [[ "$CTX" == handoff ]] && take_once "$HANDOFF_MARK"; then
  notify handoff "$(printf '%s が二段目の閾値を越えた。この依頼に入る前に、状態（済んだこと、決定、次の一手）を issue の `## 状態` コメントか作業中の文書へ書き出し、リーダーに /clear を勧めてターンを終える。リーダーがこのまま続けるよう言ったら従う。' "$(ctx_desc)")"
fi
if [[ "$CTX" == state ]] && take_once "$STATE_MARK"; then
  notify state "$(printf '%s が一段目の閾値を越えた。この依頼を片付けたら、応答の最後に、状態（済んだこと、決定、次の一手）を書き出して /clear することをリーダーに一言勧める。' "$(ctx_desc)")"
fi
exit 0
