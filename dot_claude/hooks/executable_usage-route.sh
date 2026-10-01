#!/bin/bash
# PostToolUse（全ツール）: Claude と Codex の利用枠から、実装とレビューの振り先を決め、
# 変わったときだけ Claude に知らせる（haoblackj/dotfiles#14）。
#
# 値とペースは CodexBar の serve（systemd の codexbar-serve）が持つ。serve はキャッシュを
# 内蔵し、期限が切れても直前の値をすぐ返すので、ここでは毎回読むだけでキャッシュしない。
#
# 振り先（状態ファイルの route）:
#   split        両方に余裕。実装は Codex、レビューは Claude
#   claude-only  Codex が尽きた。実装も Claude
#   stop-5h      Claude の5時間枠が尽きた。知らせるだけ（週枠から少し借りて区切りまで進む
#                仕組みがあり、越えた分は週枠に表れるので、強制はしない）
#   stop-weekly  Claude の週枠が尽きた。知らせたあともツールが FORCE_AFTER 回呼ばれたら
#                continue:false で打ち切る。打ち切りは、この状態に入るたびに1回だけ
# 尽きた: 5時間枠は使用率 85% 以上。週枠は使用率 90% 以上、または pace.secondary.deltaPercent
# （使用率 − 経過率）25 以上。deltaPercent はステータスライン（usage-battery.sh）の
# 「経過率 − 使用率」と符号が逆なだけで同じ計算。
#
# 状態ファイル: ${TMPDIR:-/tmp}/claude-usage-route/<session_id> に "<route> <count> <forced>"。
# サブエージェントのツール呼び出しも同じ session_id で数える。
#
# fail-open: serve に届かない、どちらかの provider がエラー、JSON が想定と違う、どの場合も
# 何も出さず exit 0。状態ファイルも書き換えない。

set -uo pipefail

FORCE_AFTER=5
URL="${USAGE_ROUTE_URL:-http://127.0.0.1:8080/usage?provider=both}"

SID=$(jq -r '.session_id // empty' 2>/dev/null) || exit 0
[[ "$SID" =~ ^[A-Za-z0-9._-]+$ && "$SID" != *..* ]] || exit 0

BODY=$(curl -s -f -m 2 "$URL" 2>/dev/null) || exit 0

VERDICT=$(jq -r '
  def first_of($n): [.[] | select(.provider == $n)][0];
  def ok($e): $e != null and $e.error == null
    and ($e.usage.primary.usedPercent | type) == "number"
    and ($e.usage.secondary.usedPercent | type) == "number";
  def delta($e): ($e.pace.secondary.deltaPercent // null);
  def h5_out($e): $e.usage.primary.usedPercent >= 85;
  def week_out($e): $e.usage.secondary.usedPercent >= 90
    or ((delta($e) | type) == "number" and delta($e) >= 25);
  def fmt($name; $e): "\($name) 5時間枠 \($e.usage.primary.usedPercent)%、週枠 \($e.usage.secondary.usedPercent)%"
    + (if (delta($e) | type) == "number" then "（ペース差 \(if delta($e) >= 0 then "+" else "" end)\(delta($e))）" else "" end);
  if type != "array" then empty else
    first_of("claude") as $c | first_of("codex") as $x
    | if (ok($c) and ok($x)) | not then empty else
        (if week_out($c) then "stop-weekly"
         elif h5_out($c) then "stop-5h"
         elif h5_out($x) or week_out($x) then "claude-only"
         else "split" end) + "\t" + fmt("Claude"; $c) + " / " + fmt("Codex"; $x)
      end
  end' <<< "$BODY" 2>/dev/null) || exit 0
[[ -n "$VERDICT" ]] || exit 0
ROUTE=${VERDICT%%$'\t'*}
SUMMARY=${VERDICT#*$'\t'}

STATE_DIR="${TMPDIR:-/tmp}/claude-usage-route"
STATE="$STATE_DIR/$SID"
PREV_ROUTE="" COUNT=0 FORCED=0
if [[ -f "$STATE" && ! -L "$STATE" ]]; then
  read -r PREV_ROUTE COUNT FORCED < "$STATE" 2>/dev/null
  [[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
  [[ "$FORCED" =~ ^[01]$ ]] || FORCED=0
fi

# 一時ファイルから置き換え、並列のサブエージェントに書きかけを読ませない
save() {
  local tmp
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  tmp=$(mktemp "$STATE_DIR/.tmp.XXXXXX" 2>/dev/null) || return 0
  if ! { printf '%s %s %s\n' "$1" "$2" "$3" > "$tmp" && mv -f -- "$tmp" "$STATE"; } 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
  fi
}

notify() {
  jq -nc --arg c "$1" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
}

if [[ "$ROUTE" != "$PREV_ROUTE" ]]; then
  save "$ROUTE" 0 0
  # 初回で平常なら知らせない（どのセッションでも最初のツールのたびに出ると邪魔になる）
  [[ -z "$PREV_ROUTE" && "$ROUTE" == split ]] && exit 0
  case "$ROUTE" in
    split)
      notify "利用枠: 両方に余裕が戻った（$SUMMARY）。実装は Codex、レビューは Claude に振る。" ;;
    claude-only)
      notify "利用枠: Codex の枠が尽きた（$SUMMARY）。実装も Claude で行う。Codex の無料リセットの権利は、リーダーの許可なく使わない。" ;;
    stop-5h)
      notify "利用枠: Claude の5時間枠が 85% を越えた（$SUMMARY）。issue に状態（どこまで進んだか、次の一手）を書いてから、ターンを終える。" ;;
    stop-weekly)
      notify "利用枠: Claude の週枠が尽きた（$SUMMARY）。issue に状態（どこまで進んだか、次の一手）を書いてから、ターンを終える。このあとツールを ${FORCE_AFTER} 回呼ぶと、フックが強制的に打ち切る。" ;;
  esac
  exit 0
fi

if [[ "$ROUTE" == stop-weekly && "$FORCED" == 0 ]]; then
  COUNT=$((COUNT + 1))
  if (( COUNT >= FORCE_AFTER )); then
    save "$ROUTE" "$COUNT" 1
    jq -nc --arg r "Claude の週枠が尽きたため、利用枠のフック（usage-route.sh）が打ち切った（$SUMMARY）。" \
      '{continue: false, stopReason: $r}'
  else
    save "$ROUTE" "$COUNT" 0
  fi
fi
exit 0
