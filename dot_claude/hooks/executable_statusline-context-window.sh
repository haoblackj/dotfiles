#!/bin/bash
# statusLine hook相当のラッパー。入力JSONの session_id と context_window.context_window_size を
# ${TMPDIR:-/tmp}/claude-status-context-window/$SESSION_ID に書き込んでから、
# 元のJSONをそのまま ccstatusline にパイプして表示を維持する。
#
# UserPromptSubmit hookにはmodelが渡らず、SessionStart hookも/clearではmodelを受け取れない。
# statusLineコマンドはClaude Code本体が計算した実測値のcontext_window_sizeを直接受け取れるため、
# モデル名や[1m]サフィックスの解析を経由せず窓幅を得られる代替経路として使う。
#
# fail-open: マーカー書き込みに失敗しても、ccstatusline の実行(=画面表示)は必ず行う。
# session_id は既存hookと同じ正規表現でパストラバーサル対策する。

set -uo pipefail

INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
WINDOW_SIZE=$(printf '%s' "$INPUT" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)

if [[ -n "$SESSION_ID" && "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ && "$WINDOW_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  WINDOW_DIR="${TMPDIR:-/tmp}/claude-status-context-window"
  mkdir -p "$WINDOW_DIR" 2>/dev/null && printf '%s\n' "$WINDOW_SIZE" > "$WINDOW_DIR/$SESSION_ID" 2>/dev/null
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

ANSI = re.compile(r"\x1b\[[0-9;]*m")

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
