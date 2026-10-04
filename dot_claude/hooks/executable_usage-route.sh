#!/bin/bash
# PostToolUse と PostToolUseFailure（全ツール）: Claude と Codex の利用枠から、実装とレビューの
# 振り先を決め、変わったときだけ Claude に知らせる（haoblackj/dotfiles#14）。
# 失敗したツール呼び出しは PostToolUseFailure だけが届くので、両方に配線する（#29）。
#
# 値とペースは CodexBar の serve（systemd の codexbar-serve）が持つ。serve はキャッシュを
# 内蔵し、期限が切れても直前の値をすぐ返すので、ここでは毎回読むだけでキャッシュしない。
#
# 振り先（状態ファイルの route）:
#   split        両方に余裕。実装は Codex、レビューは Claude
#   claude-only  Codex が尽きた。実装も Claude
#   stop-5h      Claude の5時間枠が尽きた。知らせるだけ
#   stop-weekly  Claude の週枠が尽きた。知らせるだけ
# 止める側（stop-5h、stop-weekly）でも continue:false での打ち切りはしない。週枠では知らせたあとの
# 呼び出しを数えて打ち切っていたが、リーダーの指示で外した（2026-10-04）。
# 尽きた: 5時間枠は使用率 85% 以上。週枠は使用率 90% 以上、または pace.secondary.deltaPercent
# （使用率 − 経過率）25 以上。deltaPercent はステータスライン（usage-battery.sh）の
# 「経過率 − 使用率」と符号が逆なだけで同じ計算。
#
# 状態ファイル: ${TMPDIR:-/tmp}/claude-usage-route/<session_id> に "<route>"。
# 打ち切りを持っていた前の版は "<route> <count> <forced>" を書いたので、先頭の語だけを読む。
# サブエージェントのツール呼び出しも同じ session_id で届き、同じ状態ファイルを使う。
#
# fail-open: serve に届かない、Claude がエラー、JSON が想定と違う、どの場合も何も出さず exit 0。
# 状態ファイルも書き換えない。Codex だけ読めないとき（無い、エラー、数値でない）は、Claude の
# 判定（週枠、5時間枠）だけをして知らせる。Claude に余裕があると split と claude-only を
# 決められない（undecided）。直前が stop-5h / stop-weekly なら、止める側のままだと次に Claude が
# 尽きても知らせないので、claude-only に切り替えて知らせる。それ以外（split、
# claude-only、状態なし）は黙り、状態も変えない。要約の Codex は「Codex 読めず」と書く。

set -uo pipefail

URL="${USAGE_ROUTE_URL:-http://127.0.0.1:8080/usage?provider=both}"

INPUT=$(cat)
SID=$(jq -r '.session_id // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ "$SID" =~ ^[A-Za-z0-9._-]+$ && "$SID" != *..* ]] || exit 0
EVENT=$(jq -r '.hook_event_name // empty' <<< "$INPUT" 2>/dev/null)
[[ "$EVENT" == PostToolUseFailure ]] || EVENT=PostToolUse

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
    | if ok($c) | not then empty else
        (if week_out($c) then "stop-weekly"
         elif h5_out($c) then "stop-5h"
         elif ok($x) | not then "undecided"
         elif h5_out($x) or week_out($x) then "claude-only"
         else "split" end) as $r
        | $r + "\t" + fmt("Claude"; $c) + " / " + (if ok($x) then fmt("Codex"; $x) else "Codex 読めず" end)
      end
  end' <<< "$BODY" 2>/dev/null) || exit 0
[[ -n "$VERDICT" ]] || exit 0
ROUTE=${VERDICT%%$'\t'*}
SUMMARY=${VERDICT#*$'\t'}

STATE_DIR="${TMPDIR:-/tmp}/claude-usage-route"
STATE="$STATE_DIR/$SID"
PREV_ROUTE=""
if [[ -f "$STATE" && ! -L "$STATE" ]]; then
  read -r PREV_ROUTE _ < "$STATE" 2>/dev/null
fi

# 一時ファイルから置き換え、並列のサブエージェントに書きかけを読ませない
save() {
  local tmp
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  tmp=$(mktemp "$STATE_DIR/.tmp.XXXXXX" 2>/dev/null) || return 0
  if ! { printf '%s\n' "$1" > "$tmp" && mv -f -- "$tmp" "$STATE"; } 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
  fi
}

notify() {
  jq -nc --arg e "$EVENT" --arg c "$1" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}

if [[ "$ROUTE" == undecided ]]; then
  case "$PREV_ROUTE" in
    stop-5h|stop-weekly)
      ROUTE=claude-only
      save "$ROUTE"
      notify "利用枠: Claude の枠に余裕が戻った（$SUMMARY）。Codex の枠は読めないので、実装も Claude で行う。Codex の無料リセットの権利は、リーダーの許可なく使わない。"
      exit 0 ;;
    *) exit 0 ;;
  esac
fi

if [[ "$ROUTE" != "$PREV_ROUTE" ]]; then
  save "$ROUTE"
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
      notify "利用枠: Claude の週枠が尽きた（$SUMMARY）。issue に状態（どこまで進んだか、次の一手）を書いてから、ターンを終える。" ;;
  esac
fi
exit 0
