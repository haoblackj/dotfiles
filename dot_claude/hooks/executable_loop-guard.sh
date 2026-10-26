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
#   CronCreate は、1 と 2 では一度きり（recurring: false）も deny する（ScheduleWakeup の代わりに
#   一度きりの予約で次の回を取れば、止めたはずのループが続くため）。それ以外の一度きりは通す。
#   繰り返しの CronCreate（固定間隔のループ）は、1 と 2 に当たらなくても deny する。固定間隔の
#   発火はフックから止められず、逼迫や引き継ぎを強制できないため（#69 の決定）。
#   LOOP_GUARD_ALLOW_RECURRING_CRON=1 のときだけ通し、4 で判定する。
#   通した予約の prompt は、ハッシュにしてセッションごとに覚える。
#
# UserPromptSubmit では、prompt が覚えた予約のどれかと同じとき（ループの発火）に、知らせを
# additionalContext で入れる。発火そのものは止めない。
#   コンテキストの二段目と一段目は、その回の作業の前に知らせる（作業を一回分むだにしないため）。
#   一段目の知らせは一度だけで、予約の deny の一度きりとは別に数える。
#   振り先（stop、逼迫）の知らせは、固定間隔を許したときだけ出す。振り先のファイルはツールを
#   呼んだときにしか書き換わらず、眠っている間の発火の時点では古いことがある。自己ペースの
#   ループは、その回のツール呼び出しで新しくなった振り先を予約の時点で読むので、それで足りる。
# ループ以外の対話セッションでは、自動の compact より先に、状態を書き出して /clear へ誘導する
# 知らせを入れる（haoblackj/dotfiles#71）。フックからは /clear を打てないので、打つのはリーダー。
#   一段目: 依頼を片付けたあと、状態の書き出しと /clear を勧めさせる。
#   二段目: 依頼に入る前に状態を書き出させ、/clear を勧めて止まらせる。
#   どちらも一度だけで、一段目を下回ったら戻す。閾値はループと同じ。
#   予約を通したことのあるセッションと、/loop で始まる prompt では出さない。ループにはループの
#   引き継ぎがあり、セッション単位で分けないと、ループの合間の手打ちに /clear の誘導が出てぶつかる。
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
# 理由の文面に載せるだけなので、~ は展開しない
# shellcheck disable=SC2088
HANDOFF_CMD="~/.claude/scripts/loop-handoff.sh"
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
NOTICED="$GUARD_DIR/$SID.noticed"
CHAT_STATE="$GUARD_DIR/$SID.chat-state"
CHAT_HANDOFF="$GUARD_DIR/$SID.chat-handoff"

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

# 一段目を下回ったら、一度だけの deny と知らせを、次に越えたときのために戻す
[[ "$CTX" == low ]] && rm -f -- "$NOTED" "$NOTICED" "$CHAT_STATE" "$CHAT_HANDOFF" 2>/dev/null

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

# 一段目の一度だけ（印のファイル $1）を使ったことにする。すでに使っていたら 1 を返す
take_once() {
  [[ -e "$1" ]] && return 1
  mkdir -p "$GUARD_DIR" 2>/dev/null && : > "$1" 2>/dev/null
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

# cron の 1 つの欄を数の並びに開く。読めない形なら 1 を返す。
expand_field() {
  local f="$1" max="$2" item base step a b m
  local -a items=()
  # for で回すと * がファイル名に展開されるので、read で配列に割る
  IFS=, read -ra items <<< "$f"
  (( ${#items[@]} > 0 )) || return 1
  for item in "${items[@]}"; do
    step=1
    if [[ "$item" == */* ]]; then step=${item#*/}; base=${item%%/*}; else base=$item; fi
    [[ "$step" =~ ^[0-9]+$ ]] && (( step >= 1 )) || return 1
    if [[ "$base" == "*" ]]; then a=0; b=$max
    elif [[ "$base" =~ ^([0-9]+)-([0-9]+)$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    elif [[ "$base" =~ ^[0-9]+$ ]]; then a=$((10#$base)); if [[ "$item" == */* ]]; then b=$max; else b=$a; fi
    else return 1; fi
    (( a <= b && b <= max )) || return 1
    for ((m = a; m <= b; m += step)); do printf '%s\n' "$m"; done
  done
}

# cron の分と時の欄から、発火の最短の間隔（分）を出す。読めなければ何も出さない。
# 日の境目もまたいで数える（日、月、曜日の欄は見ないので、間隔を短めに見積もる側に倒れる）。
cron_min_gap() {
  local mins hours h m
  mins=$(expand_field "$1" 59) || return 0
  hours=$(expand_field "$2" 23) || return 0
  for h in $hours; do for m in $mins; do printf '%s\n' $((h * 60 + m)); done; done | sort -n -u | awk '
    NR == 1 { first = $1 } NR > 1 { g = $1 - prev; if (best == "" || g < best) best = g } { prev = $1 }
    END {
      g = 1440 - prev + first; if (best == "" || g < best) best = g
      print best
    }'
}

STOP_MSG="利用枠が尽きる手前（stop）。ループを終える。issue に \`## 状態\`（済んだこと、決定、次の一手）を書き、自己ペースのループは ScheduleWakeup の stop: true、固定間隔のループは CronDelete（ID は CronList）で止めてから、ターンを終える。再開はリーダーが /loop を打ち直す。"
handoff_msg() {
  printf '%s が二段目の閾値を越えた。このセッションでループを続けない。issue に `## 状態`（済んだこと、決定、次の一手）を書き、自己ペースのループは ScheduleWakeup の stop: true、固定間隔のループは CronDelete で止める。そのうえで `%s --state-url <状態コメントの URL> --model <モデル> --effort <エフォート> -- <同じ /loop の指示>` を呼んで、Herdr の新しいタブへ引き継ぐ。モデルとエフォートは、ループの中身から選ぶ。スクリプトが失敗したら、ループを止めたことと失敗の出力をリーダーに報告して、ターンを終える。' "$(ctx_desc)" "$HANDOFF_CMD"
}
state_msg() {
  printf '%s が一段目の閾値を越えた。次の予約の前に、issue に `## 状態`（済んだこと、決定、次の一手）を書く。書いたら、同じ予約をもう一度呼んでよい（この止め方は一度だけ）。' "$(ctx_desc)"
}
chat_state_notice() {
  printf '%s が一段目の閾値を越えた。この依頼を片付けたら、応答の最後に、状態（済んだこと、決定、次の一手）を書き出して /clear することをリーダーに一言勧める。' "$(ctx_desc)"
}
chat_handoff_notice() {
  printf '%s が二段目の閾値を越えた。この依頼に入る前に、状態（済んだこと、決定、次の一手）を issue の `## 状態` コメントか作業中の文書へ書き出し、リーダーに /clear を勧めてターンを終える。リーダーがこのまま続けるよう言ったら従う。' "$(ctx_desc)"
}
state_notice() {
  printf '%s が一段目の閾値を越えている。この回の作業の前に、issue に `## 状態`（済んだこと、決定、次の一手）を書く。' "$(ctx_desc)"
}

case "$EVENT" in
  PreToolUse)
    case "$TOOL" in
      ScheduleWakeup)
        [[ "$(jq -r '.tool_input.stop // false' <<< "$INPUT" 2>/dev/null)" == true ]] && exit 0
        [[ "$ROUTE" == stop ]] && deny stop "$STOP_MSG"
        [[ "$CTX" == handoff ]] && deny handoff "$(handoff_msg)"
        [[ "$CTX" == state ]] && take_once "$NOTED" && deny state "$(state_msg)"
        DELAY=$(jq -r '.tool_input.delaySeconds // empty' <<< "$INPUT" 2>/dev/null)
        if [[ "$ROUTE" == offload || "$ROUTE" == lean ]] && [[ "$DELAY" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( ${DELAY%%.*} < TIGHT_MIN )); then
          deny tight "Claude の利用枠が逼迫している（$ROUTE）。ループの 1 回は Claude の枠を食うので、逼迫の間は delaySeconds を $TIGHT_MIN 以上にして予約し直す。"
        fi
        remember "$(jq -r '.tool_input.prompt // empty' <<< "$INPUT" 2>/dev/null)"
        ;;
      CronCreate)
        [[ "$ROUTE" == stop ]] && deny stop "新しい予約を作らない（一度きりも）。$STOP_MSG"
        [[ "$CTX" == handoff ]] && deny handoff "新しい予約を作らない（一度きりも）。$(handoff_msg)"
        # jq の // は false も既定へ倒すので、false と比べる
        [[ "$(jq -r '.tool_input.recurring == false' <<< "$INPUT" 2>/dev/null)" == true ]] && exit 0
        [[ "$ALLOW_CRON" == 1 ]] || deny cron "固定間隔のループ（繰り返しの CronCreate）は使わない。間隔を書かない /loop（自己ペース。ScheduleWakeup で次の回を予約する）で回す。"
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
    [[ -n "$P" ]] || exit 0
    if [[ ! -e "$PROMPTS" && ! -L "$PROMPTS" ]]; then
      [[ "$P" =~ ^[[:space:]]*/loop([[:space:]]|$) ]] && exit 0
      [[ "$CTX" == handoff ]] && take_once "$CHAT_HANDOFF" && notify chat-handoff "$(chat_handoff_notice)"
      [[ "$CTX" == state ]] && take_once "$CHAT_STATE" && notify chat-state "$(chat_state_notice)"
      exit 0
    fi
    [[ -f "$PROMPTS" && ! -L "$PROMPTS" ]] || exit 0
    grep -qxF -- "$(hash_of "$P")" "$PROMPTS" 2>/dev/null || exit 0
    [[ "$ALLOW_CRON" == 1 && "$ROUTE" == stop ]] && notify stop "このプロンプトはループの発火。$STOP_MSG"
    [[ "$CTX" == handoff ]] && notify handoff "このプロンプトはループの発火。この回の作業をしない。$(handoff_msg)"
    [[ "$CTX" == state ]] && take_once "$NOTICED" && notify state "このプロンプトはループの発火。$(state_notice)"
    if [[ "$ALLOW_CRON" == 1 ]] && [[ "$ROUTE" == offload || "$ROUTE" == lean ]]; then
      notify tight "このプロンプトはループの発火。Claude の利用枠が逼迫している（$ROUTE）。固定間隔のループで間隔が $((TIGHT_MIN / 60)) 分より短いなら、CronDelete して $((TIGHT_MIN / 60)) 分以上の間隔で作り直す。自己ペースのループは、次の予約を $TIGHT_MIN 秒以上にする。"
    fi
    ;;
esac
exit 0
