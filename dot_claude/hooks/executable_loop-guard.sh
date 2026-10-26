#!/bin/bash
# PreToolUse（ScheduleWakeup、CronCreate）と UserPromptSubmit: /loop を回している間に、
# 利用枠かコンテキストが逼迫したら、次の予約を止めて理由を返す（haoblackj/dotfiles#69）。
#
# 利用枠の振り先は usage-route.sh の状態ファイル、コンテキストは statusline-context-window.sh の
# マーカーを読むだけで、ここでは測らない。フックの入力にはどちらの値も入らない（公式の hooks）。
#
# PreToolUse で見ること（上から順に、最初に当たったもので deny する）:
#   ScheduleWakeup の stop: true は、どの状態でも通す（ループを止める手段を塞がない）。
#   1. 振り先が stop        → 予約を deny。状態を書いてループを止めさせる。新しい CronCreate も deny。
#   2. コンテキストが二段目  → 予約を deny。状態を書いてループを止め、新しいセッションへ引き継がせる。
#                             新しい CronCreate も deny（大きな会話のまま新しいループを始めない）。
#   3. コンテキストが一段目  → ScheduleWakeup を一度だけ deny し、状態コメントを書かせる。
#                             一段目を下回ったら（圧縮のあとなど）、次に越えたときにまた一度 deny する。
#   4. 振り先が offload か lean → 間隔が 20 分より短い予約を deny（ScheduleWakeup の delaySeconds、
#                             繰り返しの CronCreate の cron の分の欄から求めた最短の間隔）。
#   繰り返しの CronCreate（固定間隔のループ）は、上の判定より前に、どの状態でも deny する。
#   固定間隔のループの発火はフックから止められず、逼迫や引き継ぎを強制できないため（#69 の決定）。
#   LOOP_GUARD_ALLOW_RECURRING_CRON=1 のときだけ通し、上の 1、2、4 で判定する。
#   通した予約の prompt は、ハッシュにしてセッションごとに覚える。
#
# UserPromptSubmit では、prompt が覚えた予約のどれかと同じとき（ループの発火）だけ、上の 1〜4 に
# 当たる知らせを additionalContext で入れる。固定間隔のループは ScheduleWakeup を呼ばないので、
# 発火の側で知らせないと止める合図が届かない。発火そのものは止めない。
#
# 閾値（#69 の決定。環境変数で差し替えられる。記録を見て見直す）。1M の窓のトークン数は、実践者の
# 経験則（300K を確認点にする、300〜400K を上限にする）から取った。測定に基づく値ではない。
# 200K の窓では使用率のほうが先に効く（75% は 150K）:
#   一段目: LOOP_GUARD_STATE_TOKENS トークン以上か、使用率 LOOP_GUARD_STATE_PCT% 以上
#   二段目: LOOP_GUARD_HANDOFF_TOKENS トークン以上か、使用率 LOOP_GUARD_HANDOFF_PCT% 以上
#   トークン数は、マーカーの使用率 × 窓の大きさ。使用率のマーカーが無い（/compact の直後など）
#   ときは、コンテキストの判定をしない。
#   逼迫の間の間隔の下限: LOOP_GUARD_TIGHT_MIN_SECONDS 秒
#
# サブエージェント内のツール呼び出し（入力に agent_id がある）では何もしない。
# 記録: ${XDG_STATE_HOME:-~/.local/state}/claude-loop-guard/decisions.log に、deny と知らせのたびに
# 「時刻<TAB>session_id<TAB>event<TAB>tool<TAB>判定<TAB>振り先<TAB>トークン数<TAB>使用率」を1行。
# fail-open: 入力が読めない、値が読めない、どの場合も黙って通す。

set -uo pipefail

STATE_TOKENS="${LOOP_GUARD_STATE_TOKENS:-300000}"
STATE_PCT="${LOOP_GUARD_STATE_PCT:-50}"
HANDOFF_TOKENS="${LOOP_GUARD_HANDOFF_TOKENS:-400000}"
HANDOFF_PCT="${LOOP_GUARD_HANDOFF_PCT:-75}"
TIGHT_MIN="${LOOP_GUARD_TIGHT_MIN_SECONDS:-1200}"
ALLOW_CRON="${LOOP_GUARD_ALLOW_RECURRING_CRON:-0}"
for v in "$STATE_TOKENS" "$STATE_PCT" "$HANDOFF_TOKENS" "$HANDOFF_PCT" "$TIGHT_MIN"; do
  [[ "$v" =~ ^[0-9]+$ ]] || exit 0
done

INPUT=$(cat)
SID=$(jq -r '.session_id // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ "$SID" =~ ^[A-Za-z0-9._-]+$ && "$SID" != *..* ]] || exit 0
AGENT_ID=$(jq -r '.agent_id // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ -z "$AGENT_ID" ]] || exit 0
EVENT=$(jq -r '.hook_event_name // empty' <<< "$INPUT" 2>/dev/null) || exit 0
TOOL=$(jq -r '.tool_name // empty' <<< "$INPUT" 2>/dev/null) || exit 0

T="${TMPDIR:-/tmp}"
GUARD_DIR="$T/claude-loop-guard"
PROMPTS="$GUARD_DIR/$SID.prompts"
NOTED="$GUARD_DIR/$SID.noted"

# 通常のファイルの先頭の語だけを読む（FIFO やリンクを読んで固まったり他を読んだりしない）
read_word() {
  local w=""
  [[ -f "$1" && ! -L "$1" ]] && read -r w _ < "$1" 2>/dev/null
  printf '%s' "$w"
}

ROUTE=$(read_word "$T/claude-usage-route/$SID")
case "$ROUTE" in
  stop-5h|stop-weekly) ROUTE=stop ;;
  normal|offload|lean|stop) ;;
  *) ROUTE="" ;;
esac

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

# 一段目を下回ったら、一度だけの deny を次に越えたときのために戻す
[[ "$CTX" == low ]] && rm -f -- "$NOTED" 2>/dev/null

log() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-loop-guard"
  { mkdir -p "$dir" &&
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SID" "$EVENT" "$TOOL" "$1" \
      "${ROUTE:--}" "${TOKENS:--}" "${PCT:--}" >> "$dir/decisions.log"; } 2>/dev/null
  return 0
}

ctx_desc() {
  if [[ -n "$TOKENS" ]]; then printf 'コンテキスト 約 %s トークン（使用率 %s%%）' "$TOKENS" "$PCT"
  else printf 'コンテキスト 使用率 %s%%' "$PCT"; fi
}

# 一段目の一度だけを使ったことにする。すでに使っていたら 1 を返す
take_note() {
  [[ -e "$NOTED" ]] && return 1
  mkdir -p "$GUARD_DIR" 2>/dev/null && : > "$NOTED" 2>/dev/null
  return 0
}

hash_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

remember() {
  local h
  h=$(hash_of "$1")
  mkdir -p "$GUARD_DIR" 2>/dev/null || return 0
  [[ -L "$PROMPTS" ]] && return 0
  grep -qxF -- "$h" "$PROMPTS" 2>/dev/null || printf '%s\n' "$h" >> "$PROMPTS" 2>/dev/null
  return 0
}

deny() {
  log "deny:$1"
  jq -nc --arg r "[loop-guard] $2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

notify() {
  log "notice:$1"
  jq -nc --arg c "[loop-guard] $2" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
  exit 0
}

# cron の分の欄から、発火の最短の間隔（分）を出す。読めなければ何も出さない。
# 時の欄が * のときだけ、毎時の境目をまたぐ間隔も数える。
cron_min_gap() {
  local min_f="$1" hour_f="$2" item base step a b m
  local -a mins=() items=()
  # for で回すと * がファイル名に展開されるので、read で配列に割る
  IFS=, read -ra items <<< "$min_f"
  for item in "${items[@]}"; do
    step=1
    if [[ "$item" == */* ]]; then step=${item#*/}; base=${item%%/*}; else base=$item; fi
    [[ "$step" =~ ^[0-9]+$ ]] && (( step >= 1 )) || return 0
    if [[ "$base" == "*" ]]; then a=0; b=59
    elif [[ "$base" =~ ^([0-9]+)-([0-9]+)$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    elif [[ "$base" =~ ^[0-9]+$ ]]; then a=$((10#$base)); if [[ "$item" == */* ]]; then b=59; else b=$a; fi
    else return 0; fi
    (( a <= b && b <= 59 )) || return 0
    for ((m = a; m <= b; m += step)); do mins+=("$m"); done
  done
  (( ${#mins[@]} > 0 )) || return 0
  printf '%s\n' "${mins[@]}" | sort -n -u | awk -v wrap="$([[ "$hour_f" == "*" || "$hour_f" == "*/1" ]] && echo 1 || echo 0)" '
    NR == 1 { first = $1 } NR > 1 { g = $1 - prev; if (best == "" || g < best) best = g } { prev = $1 }
    END {
      if (wrap) { g = 60 - prev + first; if (best == "" || g < best) best = g }
      if (best == "") best = 60
      print best
    }'
}

STOP_MSG="利用枠が尽きる手前（stop）。ループを終える。issue に \`## 状態\`（済んだこと、決定、次の一手）を書き、自己ペースのループは ScheduleWakeup の stop: true、固定間隔のループは CronDelete（ID は CronList）で止めてから、ターンを終える。再開はリーダーが /loop を打ち直す。"
handoff_msg() {
  printf '%s が二段目の閾値を越えた。このセッションでループを続けない。issue に `## 状態`（済んだこと、決定、次の一手）を書き、自己ペースのループは ScheduleWakeup の stop: true、固定間隔のループは CronDelete で止める。そのうえで Herdr の同じリポジトリのワークスペースに新しいタブを立て、/loop と同じ指示に状態コメントの場所を添えて渡す。' "$(ctx_desc)"
}
state_msg() {
  printf '%s が一段目の閾値を越えた。次の予約の前に、issue に `## 状態`（済んだこと、決定、次の一手）を書く。書いたら、同じ予約をもう一度呼んでよい（この止め方は一度だけ）。' "$(ctx_desc)"
}

case "$EVENT" in
  PreToolUse)
    case "$TOOL" in
      ScheduleWakeup)
        [[ "$(jq -r '.tool_input.stop // false' <<< "$INPUT" 2>/dev/null)" == true ]] && exit 0
        [[ "$ROUTE" == stop ]] && deny stop "$STOP_MSG"
        [[ "$CTX" == handoff ]] && deny handoff "$(handoff_msg)"
        [[ "$CTX" == state ]] && take_note && deny state "$(state_msg)"
        DELAY=$(jq -r '.tool_input.delaySeconds // empty' <<< "$INPUT" 2>/dev/null)
        if [[ "$ROUTE" == offload || "$ROUTE" == lean ]] && [[ "$DELAY" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( ${DELAY%%.*} < TIGHT_MIN )); then
          deny tight "Claude の利用枠が逼迫している（$ROUTE）。ループの 1 回は Claude の枠を食うので、逼迫の間は delaySeconds を $TIGHT_MIN 以上にして予約し直す。"
        fi
        remember "$(jq -r '.tool_input.prompt // empty' <<< "$INPUT" 2>/dev/null)"
        ;;
      CronCreate)
        # jq の // は false も既定へ倒すので、false と比べる
        [[ "$(jq -r '.tool_input.recurring == false' <<< "$INPUT" 2>/dev/null)" == true ]] && exit 0
        [[ "$ALLOW_CRON" == 1 ]] || deny cron "固定間隔のループ（繰り返しの CronCreate）は使わない。間隔を書かない /loop（自己ペース。ScheduleWakeup で次の回を予約する）で回す。一度きりのリマインダー（recurring: false）は使ってよい。"
        [[ "$ROUTE" == stop ]] && deny stop "利用枠が尽きる手前（stop）。新しいループを始めない。"
        [[ "$CTX" == handoff ]] && deny handoff "$(ctx_desc) が二段目の閾値を越えている。このセッションで新しいループを始めず、Herdr で新しいタブを立てて、そちらで /loop を始める。"
        if [[ "$ROUTE" == offload || "$ROUTE" == lean ]]; then
          read -r CMIN CHOUR _ <<< "$(jq -r '.tool_input.cron // empty' <<< "$INPUT" 2>/dev/null)"
          GAP=$(cron_min_gap "${CMIN:-}" "${CHOUR:-}")
          if [[ "$GAP" =~ ^[0-9]+$ ]] && (( GAP * 60 < TIGHT_MIN )); then
            deny tight "Claude の利用枠が逼迫している（$ROUTE）。最短 $GAP 分おきの予約になる。逼迫の間は $((TIGHT_MIN / 60)) 分以上の間隔にする。"
          fi
        fi
        remember "$(jq -r '.tool_input.prompt // empty' <<< "$INPUT" 2>/dev/null)"
        ;;
    esac
    ;;
  UserPromptSubmit)
    P=$(jq -r '.prompt // empty' <<< "$INPUT" 2>/dev/null)
    [[ -n "$P" && -f "$PROMPTS" && ! -L "$PROMPTS" ]] || exit 0
    grep -qxF -- "$(hash_of "$P")" "$PROMPTS" 2>/dev/null || exit 0
    [[ "$ROUTE" == stop ]] && notify stop "このプロンプトはループの発火。$STOP_MSG"
    [[ "$CTX" == handoff ]] && notify handoff "このプロンプトはループの発火。$(handoff_msg)"
    [[ "$CTX" == state ]] && take_note && notify state "このプロンプトはループの発火。$(state_msg)"
    if [[ "$ROUTE" == offload || "$ROUTE" == lean ]]; then
      notify tight "このプロンプトはループの発火。Claude の利用枠が逼迫している（$ROUTE）。固定間隔のループで間隔が $((TIGHT_MIN / 60)) 分より短いなら、CronDelete して $((TIGHT_MIN / 60)) 分以上の間隔で作り直す。自己ペースのループは、次の予約を $TIGHT_MIN 秒以上にする。"
    fi
    ;;
esac
exit 0
