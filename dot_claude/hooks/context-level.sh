# shellcheck shell=bash disable=SC2034  # 決めた変数は source した側が使う
# loop-guard.sh と chat-context-guard.sh が source する共通部分（haoblackj/dotfiles#71）。
# 実行はしない。読む前に T（${TMPDIR:-/tmp}）と SID（検証済みの session_id）を決めておく。
#
# コンテキストの段（CTX）を、statusline-context-window.sh のマーカーから決める。ここでは測らない。
#   一段目: CONTEXT_GUARD_STATE_TOKENS トークン以上か、使用率 CONTEXT_GUARD_STATE_PCT% 以上
#   二段目: CONTEXT_GUARD_HANDOFF_TOKENS トークン以上か、使用率 CONTEXT_GUARD_HANDOFF_PCT% 以上
#   1M の窓のトークン数は、実践者の経験則（300K を確認点にする、300〜400K を上限にする）から取った
#   （#69 の決定）。測定に基づく値ではない。200K の窓では使用率のほうが先に効く（75% は 150K）。
#   トークン数は、マーカーの使用率 × 窓の大きさ。使用率のマーカーが無い（/compact の直後など）
#   ときは CTX を空にする。
# 決めるもの: CTX（low / state / handoff / 空）、PCT、TOKENS
# 関数: read_word、ctx_desc、in_loop_session
#
# 閾値が数でなければ 1 を返す。読む側は黙って通す（fail-open）。

STATE_TOKENS="${CONTEXT_GUARD_STATE_TOKENS:-300000}"
STATE_PCT="${CONTEXT_GUARD_STATE_PCT:-50}"
HANDOFF_TOKENS="${CONTEXT_GUARD_HANDOFF_TOKENS:-400000}"
HANDOFF_PCT="${CONTEXT_GUARD_HANDOFF_PCT:-75}"
for v in "$STATE_TOKENS" "$STATE_PCT" "$HANDOFF_TOKENS" "$HANDOFF_PCT"; do
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
done

# ループの予約を通したことのあるセッションの印。loop-guard.sh が予約の prompt のハッシュを書く
LOOP_PROMPTS="$T/claude-loop-guard/$SID.prompts"

# 通常のファイルの先頭の語だけを読む（FIFO やリンクを読んで固まったり他を読んだりしない）
read_word() {
  local w=""
  [[ -f "$1" && ! -L "$1" ]] && read -r w _ < "$1" 2>/dev/null
  printf '%s' "$w"
}

PCT=$(read_word "$T/claude-status-context-usage/$SID")
WIN=$(read_word "$T/claude-status-context-window/$SID")
TOKENS=""
CTX=""
if [[ "$PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  PCT_INT=${PCT%%.*}
  if [[ "$WIN" =~ ^[1-9][0-9]*$ ]]; then
    TOKENS=$(awk -v p="$PCT" -v w="$WIN" 'BEGIN { printf "%d", p * w / 100 }')
  fi
  over() { (( PCT_INT >= $1 )) || { [[ -n "$TOKENS" ]] && (( TOKENS >= $2 )); }; }
  if over "$HANDOFF_PCT" "$HANDOFF_TOKENS"; then
    CTX=handoff
  elif over "$STATE_PCT" "$STATE_TOKENS"; then
    CTX=state
  else
    CTX=low
  fi
fi

ctx_desc() {
  if [[ -n "$TOKENS" ]]; then printf 'コンテキスト 約 %s トークン（使用率 %s%%）' "$TOKENS" "$PCT"
  else printf 'コンテキスト 使用率 %s%%' "$PCT"; fi
}

# ループのセッションか。予約を通したことがあるか、prompt（$1）が /loop で始まるとき 0 を返す。
# ループの合間の手打ちもループのセッションとして扱う（prompt 単位で分けると、合間の手打ちに
# 対話向けの知らせが出て、ループの引き継ぎとぶつかる）。
in_loop_session() {
  [[ -e "$LOOP_PROMPTS" || -L "$LOOP_PROMPTS" ]] && return 0
  [[ "${1:-}" =~ ^[[:space:]]*/loop([[:space:]]|$) ]]
}
