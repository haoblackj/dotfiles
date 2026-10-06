#!/bin/bash
# PostToolUse と PostToolUseFailure（全ツール）: Claude と Codex の利用枠から、実装の担い手を決め、
# 変わったときだけ親の Claude に知らせる（haoblackj/dotfiles#14、方針の反転は #34）。
# 失敗したツール呼び出しは PostToolUseFailure だけが届くので、両方に配線する（#29）。
#
# 値とペースは CodexBar の serve（systemd の codexbar-serve）が持つ。serve はキャッシュを
# 内蔵し、期限が切れても直前の値をすぐ返すので、ここでは毎回読むだけでキャッシュしない。
#
# 振り先（状態ファイルの route）:
#   normal   Claude に余裕。Claude が実装する（平常。初回は知らせない）
#   offload  Claude が逼迫し、Codex に余裕。実装の単位を Codex へ退避する
#   lean     Claude が逼迫し、Codex も逼迫か読めない。退避せず Claude が消費を絞って続ける
#   stop     Claude が尽きる手前。issue に状態を書いてターンを終える（知らせるだけで打ち切らない）
#
# しきい値（#34 の初期値。遷移ログを見て見直す）。逼迫と stop は、直前の状態で入りと出を分ける
# （ヒステリシス）。出る側の値は、直前が逼迫の側（offload、lean、stop）のときに使う。
#   Claude 逼迫・5時間枠: 使用率 70% 以上、かつリセットまで 45 分以上で入る。出るのは 60% 未満。
#     リセット間際に新しく退避を始めると、退避の手間（ブリーフ、統合）のほうが高くつくので、
#     45 分の条件は入るときだけに掛ける。逼迫の最中にリセットが近づいても、余裕が戻ったとは言わない。
#   Claude 逼迫・週枠: ペース差 +10 以上か使用率 75% 以上（出るのはペース差 0 以下かつ使用率 70% 未満）。
#     ペース差は pace.secondary.deltaPercent（使用率 − 経過率）。ペースの超過は「消費を減らせ」の
#     合図なので、止めずに退避の条件にする。
#   Claude stop: 5時間枠 90% 以上か週枠 95% 以上（出るのは 5時間枠 80% 未満かつ週枠 90% 未満）。
#   Codex に余裕: 5時間枠 70% 未満、週枠 85% 未満、週のペース差 +15 未満のすべて。
#
# サブエージェント内のツール呼び出し（入力に agent_id がある）では何もしない。知らせが
# サブエージェントの文脈に入り、状態だけが進んで親に届かなくなるため。
#
# 状態ファイル: ${TMPDIR:-/tmp}/claude-usage-route/<session_id> に "<route>"。先頭の語だけを読む。
# 前の版の名前（split、claude-only、stop-5h、stop-weekly。打ち切りの数つきもある）は、
# normal と stop に読み替える。split のまま動いているセッションは、起動時に読んだ前の方針
# （両方に余裕があれば実装は Codex）を持っているので、normal になるときに一度だけ方針の変更を知らせる。
# 状態の読みから書きまでを session ごとのロック（flock -n）で囲む。並列のツール呼び出しが同じ遷移を
# 重ねて知らせ、遷移ログに同じ行を重ねるのを防ぐ。ロックを取れなかった呼び出しは黙って抜ける。
# 遷移ログ: ${XDG_STATE_HOME:-~/.local/state}/claude-usage-route/transitions.log に、振り先が
# 変わるたびに「時刻<TAB>session_id<TAB>前<TAB>後<TAB>要約」を1行。書けなくても知らせは出す。
#
# fail-open: serve に届かない、Claude がエラー、JSON が想定と違う、どの場合も何も出さず exit 0。
# 状態ファイルも書き換えない。Codex だけ読めない（無い、エラー、数値でない）ときは、Codex に
# 余裕が無いものとして扱う。要約の Codex は「Codex 読めず」と書く。
# テストは USAGE_ROUTE_URL（file:// も可）と USAGE_ROUTE_NOW（epoch 秒）で入力を差し替える。

set -uo pipefail

URL="${USAGE_ROUTE_URL:-http://127.0.0.1:8080/usage?provider=both}"
NOW="${USAGE_ROUTE_NOW:-$(date +%s)}"
[[ "$NOW" =~ ^[0-9]+$ ]] || exit 0

INPUT=$(cat)
SID=$(jq -r '.session_id // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ "$SID" =~ ^[A-Za-z0-9._-]+$ && "$SID" != *..* ]] || exit 0
AGENT_ID=$(jq -r '.agent_id // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ -z "$AGENT_ID" ]] || exit 0
EVENT=$(jq -r '.hook_event_name // empty' <<< "$INPUT" 2>/dev/null)
[[ "$EVENT" == PostToolUseFailure ]] || EVENT=PostToolUse

STATE_DIR="${TMPDIR:-/tmp}/claude-usage-route"
STATE="$STATE_DIR/$SID"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
if command -v flock >/dev/null 2>&1; then
  # 状態ファイルと同じく symlink は避け、追記で開いて既存のファイルを切り詰めない
  [[ -L "$STATE_DIR/.lock.$SID" ]] && exit 0
  exec 9>> "$STATE_DIR/.lock.$SID" 2>/dev/null || exit 0
  flock -n 9 || exit 0
fi
RAW_PREV=""
if [[ -f "$STATE" && ! -L "$STATE" ]]; then
  read -r RAW_PREV _ < "$STATE" 2>/dev/null
fi
PREV_ROUTE="$RAW_PREV"
case "$PREV_ROUTE" in
  split|claude-only) PREV_ROUTE=normal ;;
  stop-5h|stop-weekly) PREV_ROUTE=stop ;;
  normal|offload|lean|stop) ;;
  *) PREV_ROUTE="" ;;
esac

BODY=$(curl -s -f -m 2 "$URL" 2>/dev/null) || exit 0

VERDICT=$(jq -r --arg prev "$PREV_ROUTE" --argjson now "$NOW" '
  def first_of($n): [.[] | select(type == "object" and .provider == $n)][0];
  def ok($e): $e != null and $e.error == null
    and ($e.usage.primary.usedPercent | type) == "number"
    and ($e.usage.secondary.usedPercent | type) == "number";
  def h5($e): $e.usage.primary.usedPercent;
  def wk($e): $e.usage.secondary.usedPercent;
  def delta($e): ($e.pace.secondary.deltaPercent // null);
  def delta_ge($e; $t): (delta($e) | type) == "number" and delta($e) >= $t;
  def delta_gt($e; $t): (delta($e) | type) == "number" and delta($e) > $t;
  # 5時間枠のリセットまでの分。読めなければ null（逼迫の判定ではリセットが遠いものとして扱う）
  def h5_left($e): ($e.usage.primary.resetsAt // null)
    | if type == "string" then (try ((sub("\\.[0-9]+"; "") | fromdateiso8601) - $now | . / 60 | floor) catch null)
      else null end;
  ($prev == "offload" or $prev == "lean" or $prev == "stop") as $was_tight
  | def claude_stop($e):
      if $prev == "stop" then h5($e) >= 80 or wk($e) >= 90
      else h5($e) >= 90 or wk($e) >= 95 end;
    def claude_tight($e):
      (h5_left($e)) as $left
      | (if $was_tight then h5($e) >= 60 else h5($e) >= 70 and ($left == null or $left >= 45) end)
        or (if $was_tight then delta_gt($e; 0) or wk($e) >= 70
            else delta_ge($e; 10) or wk($e) >= 75 end);
    def codex_room($e): ok($e) and h5($e) < 70 and wk($e) < 85 and (delta_ge($e; 15) | not);
    def fmt($name; $e): "\($name) 5時間枠 \(h5($e))%"
      + (if (h5_left($e) | type) == "number" then "（リセットまで \(h5_left($e)) 分）" else "" end)
      + "、週枠 \(wk($e))%"
      + (if (delta($e) | type) == "number" then "（ペース差 \(if delta($e) >= 0 then "+" else "" end)\(delta($e))）" else "" end);
  if type != "array" then empty else
    first_of("claude") as $c | first_of("codex") as $x
    | if ok($c) | not then empty else
        (if claude_stop($c) then "stop"
         elif claude_tight($c) then (if codex_room($x) then "offload" else "lean" end)
         else "normal" end) as $r
        | $r + "\t" + fmt("Claude"; $c) + " / " + (if ok($x) then fmt("Codex"; $x) else "Codex 読めず" end)
      end
  end' <<< "$BODY" 2>/dev/null) || exit 0
[[ -n "$VERDICT" ]] || exit 0
ROUTE=${VERDICT%%$'\t'*}
SUMMARY=${VERDICT#*$'\t'}

# 一時ファイルから置き換え、並列の呼び出しに書きかけを読ませない
save() {
  local tmp
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  tmp=$(mktemp "$STATE_DIR/.tmp.XXXXXX" 2>/dev/null) || return 0
  if ! { printf '%s\n' "$1" > "$tmp" && mv -f -- "$tmp" "$STATE"; } 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
  fi
}

log_transition() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-usage-route"
  { mkdir -p "$dir" &&
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" "$SID" "$PREV_ROUTE" "$ROUTE" "$SUMMARY" \
      >> "$dir/transitions.log"; } 2>/dev/null
  return 0
}

notify() {
  jq -nc --arg e "$EVENT" --arg c "$1" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}

if [[ "$ROUTE" == "$PREV_ROUTE" ]]; then
  # 前の版の名前で残っていたら、振り先は同じなので新しい名前に書き直す
  [[ "$RAW_PREV" == "$ROUTE" ]] || save "$ROUTE"
  if [[ "$RAW_PREV" == split ]]; then
    notify "利用枠: 振り分けの方針が変わった（$SUMMARY）。平常は Claude が実装する。Codex へ退避するのは、Claude の枠が逼迫したとこのフックが知らせたときだけ。"
  fi
  exit 0
fi

save "$ROUTE"
log_transition

# 初回で平常なら知らせない（どのセッションでも最初のツールのたびに出ると邪魔になる）
[[ -z "$PREV_ROUTE" && "$ROUTE" == normal ]] && exit 0

case "$ROUTE" in
  normal)
    notify "利用枠: Claude の枠に余裕が戻った（$SUMMARY）。実装は Claude で行う。" ;;
  offload)
    notify "利用枠: Claude の枠が逼迫している（$SUMMARY）。Codex に余裕があるので、これから着手する実装の単位は ~/.codex/codex-delegate.sh へブリーフで渡す。着手中の編集は仕上げてよい。全件テスト、統合、コミット、レビューは Claude が持つ。" ;;
  lean)
    notify "利用枠: Claude の枠が逼迫しているが、Codex も逼迫しているか読めない（$SUMMARY）。Codex へは退避しない。Claude が実装を続け、着手中の単位を仕上げることを優先する。新しい並列のサブエージェントやレビューの往復は増やさない。Codex の無料リセットの権利は、リーダーの許可なく使わない。" ;;
  stop)
    notify "利用枠: Claude の枠が尽きる手前（$SUMMARY）。issue に状態（どこまで進んだか、次の一手）を書いてから、ターンを終える。" ;;
esac
exit 0
