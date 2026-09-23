#!/bin/bash
# statusLine hook相当のラッパー。入力JSONの session_id と context_window の2値を
# マーカーファイルに書き込んでから、元のJSONをそのまま ccstatusline にパイプして表示を維持する。
#   窓幅:   context_window.context_window_size → ${TMPDIR:-/tmp}/claude-status-context-window/$SESSION_ID
#   使用率: context_window.used_percentage     → ${TMPDIR:-/tmp}/claude-status-context-usage/$SESSION_ID
#   残量:   rate_limits の5時間枠と週枠          → ${TMPDIR:-/tmp}/claude-status-rate-limits/$SESSION_ID
#           home-dashboard の collector が全セッション分を読み、枠ごとに最新の値を選ぶ。
#           渡る値に受信時刻が無いので、枠の値が変わった時刻を枠ごとの changedAt として残す。
#
# どちらも Claude Code 本体が計算した値で、公式ドキュメントは statusLine を「assistant の
# 応答ごと」と「/compact 完了時」に再実行すると定めている。used_percentage は /compact 直後に
# null になり、次の API 呼び出しで圧縮後の値に戻る（2026-09-12 に 25% → null → 7% を実測）。
# null のときは使用率マーカーを消す。読む側は「マーカーが無い＝いま測れない」として扱い、
# 古い値を残さない。transcript を自前で解析すると圧縮前の最後の usage を拾ってしまうため、
# 使用率の出所はこのマーカーに一本化している（penguinEx issue #73）。
#
# fail-open: マーカー書き込みに失敗しても、ccstatusline の実行(=画面表示)は必ず行う。
# session_id は既存hookと同じ正規表現でパストラバーサル対策する。
#
# herdr のタブ名の同期（haoblackj/dotfiles#11）は herdr-tab-title-sync.sh に任せ、
# 入力JSONを渡してバックグラウンドで呼ぶ。stdout と stderr を捨てるのは、子が
# 表示のパイプを握ったままにならないようにするため。握ったままだと Claude Code が
# パイプの終端を待ち、表示が遅れる。

set -uo pipefail

INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s' "$INPUT" | bash "$HOOK_DIR/herdr-tab-title-sync.sh" >/dev/null 2>&1 &

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
WINDOW_SIZE=$(printf '%s' "$INPUT" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
USED_PCT=$(printf '%s' "$INPUT" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)

if [[ -n "$SESSION_ID" && "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  if [[ "$WINDOW_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    WINDOW_DIR="${TMPDIR:-/tmp}/claude-status-context-window"
    mkdir -p "$WINDOW_DIR" 2>/dev/null && printf '%s\n' "$WINDOW_SIZE" > "$WINDOW_DIR/$SESSION_ID" 2>/dev/null
  fi
  USAGE_DIR="${TMPDIR:-/tmp}/claude-status-context-usage"
  if [[ "$USED_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    mkdir -p "$USAGE_DIR" 2>/dev/null && printf '%s\n' "$USED_PCT" > "$USAGE_DIR/$SESSION_ID" 2>/dev/null
  else
    rm -f -- "$USAGE_DIR/$SESSION_ID" 2>/dev/null
  fi

  RATE_DIR="${TMPDIR:-/tmp}/claude-status-rate-limits"
  RATE_FILE="$RATE_DIR/$SESSION_ID"
  # 前回の値。通常のファイルのときだけ読む（FIFO やリンクを読んで固まったり他を読んだりしない）
  PREV='{}'
  if [[ -f "$RATE_FILE" && ! -L "$RATE_FILE" ]]; then
    PREV=$(jq -c 'if type == "object" then . else {} end' "$RATE_FILE" 2>/dev/null) || PREV='{}'
    [[ -n "$PREV" ]] || PREV='{}'
  fi
  RATE=$(printf '%s' "$INPUT" | jq -c --argjson prev "$PREV" --argjson now "$(date +%s)" '
    def win($src; $key):
      if ($src | type) == "object"
         and ($src.used_percentage | type) == "number" and ($src.resets_at | type) == "number"
      then {($key): {
              used: $src.used_percentage,
              resetsAt: $src.resets_at,
              changedAt: (
                if ($prev[$key] | type) == "object"
                   and $prev[$key].used == $src.used_percentage
                   and $prev[$key].resetsAt == $src.resets_at
                   and ($prev[$key].changedAt | type) == "number"
                then $prev[$key].changedAt else $now end)}}
      else {} end;
    (.rate_limits // {}) as $r
    | if ($r | type) == "object" then win($r.five_hour; "fiveHour") + win($r.seven_day; "sevenDay") else {} end
  ' 2>/dev/null)
  # 一時ファイルに書いてから置き換え、collector が書きかけを読まないようにする
  if [[ -n "$RATE" && "$RATE" != "{}" ]] && mkdir -p "$RATE_DIR" 2>/dev/null \
     && RATE_TMP=$(mktemp "$RATE_DIR/.tmp.XXXXXX" 2>/dev/null); then
    if ! { printf '%s\n' "$RATE" > "$RATE_TMP" && mv -f -- "$RATE_TMP" "$RATE_FILE"; } 2>/dev/null; then
      rm -f -- "$RATE_TMP" 2>/dev/null
    fi
  fi
fi

# ステータスラインは3行構成（モデル/使用量/思考・文脈）で組んである。
# 端末が広くて1行目と2行目が横に並ぶなら、その2行を連結して2行構成へ畳む。
# 収まらないときだけ3行のまま出す。ccstatusline 自身には幅で行数を変える
# 機能がないため（flexMode は区切りの伸縮のみ）、ここで後処理する。
#
# 幅は親プロセスのTTYから読む。statusLine コマンドは制御端末を持たないので
# /dev/tty は使えず、ccstatusline と同じく親を辿る必要がある。
#
# fail-open: 幅が読めない、python3 がない、行数が想定と違う——どの場合も
# ccstatusline の出力をそのまま流す。畳めないだけで表示は壊れない。

probe_terminal_width() {
  local pid=$$ ppid tty cols i
  # ccstatusline と同じ上書き変数を尊重する。検証時に幅を固定できる。
  if [[ "${CCSTATUSLINE_WIDTH:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$CCSTATUSLINE_WIDTH"
    return 0
  fi
  for ((i = 0; i < 8; i++)); do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$ppid" || "$ppid" == "0" ]] && return 1
    pid=$ppid
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$tty" || "$tty" == "?" || ! -e "/dev/$tty" ]] && continue
    cols=$(stty size < "/dev/$tty" 2>/dev/null | cut -d' ' -f2)
    [[ "$cols" =~ ^[0-9]+$ ]] && { printf '%s' "$cols"; return 0; }
  done
  return 1
}

OUTPUT=$(printf '%s' "$INPUT" | ccstatusline)

TERM_WIDTH=$(probe_terminal_width) || TERM_WIDTH=""

if [[ -z "$TERM_WIDTH" ]] || ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "$OUTPUT"
  exit 0
fi

printf '%s\n' "$OUTPUT" | python3 -c '
import re, sys, unicodedata

# 色（CSI ... m）と OSC（\x1b] ... BEL または ESC \）。OSC 8 のリンクは URL が
# 画面に出ないので、幅に数えると1行目が実際より長く見えて畳む判定が外れる。
ANSI = re.compile(r"\x1b\[[0-9;]*m|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

def visible_width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1
               for c in ANSI.sub("", s))

lines = [l.rstrip("\n") for l in sys.stdin]
try:
    width = int(sys.argv[1])
except (IndexError, ValueError):
    width = 0

# 使用量widgetは rate_limits が来ていない間その行ごと消えるため、
# 3行そろっているときだけ畳む。2行しかないなら2行目は思考・文脈行で、
# 連結すると別物どうしがつながる。
if len(lines) == 3 and width > 0 and visible_width(lines[0]) + visible_width(lines[1]) <= width:
    lines = [lines[0] + lines[1]] + lines[2:]

for line in lines:
    print(line)
' "$TERM_WIDTH"

exit 0
