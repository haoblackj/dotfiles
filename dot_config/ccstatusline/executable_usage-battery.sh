#!/bin/bash
# ccstatusline の custom-command widget 用。
# statusLine が渡す JSON の rate_limits から、5時間枠と週間枠の状態を1行に詰める。
#
#   5h / 7d      どちらの制限枠か
#   形 = 残量    5セルを █/░ で塗る。塗り数は int(残量 / 20)。
#   色 = ペース  枠の経過率から使用率を引いたポイント差の4段階。
#   末尾の時間   週間枠のリセットまでの残り。5時間枠は枠が短く回るので出さない。
#
# 枠の開始時刻は「リセット時刻 - 枠の長さ」で求める。ccstatusline 内部の
# buildUsageWindow と同じ式なので、他のwidgetと経過率が食い違わない。
#
# rate_limits はサブスク契約者かつ最初のAPI応答後にしか入らない。欠けている
# 間は何も出さない。キャッシュに残った古い値を出すより誤解が少ない。
#
# 出力例:  5h ████░90% │ 7d ████░97% │ 6d21h
# 色は自前のANSIで付けるため、widget側に preserveColors: true が要る。

set -uo pipefail

INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

VALS=$(printf '%s' "$INPUT" | jq -r '
  def num(v): if (v | type) == "number" then (v | tostring) else "-" end;
  [ num(.rate_limits.five_hour.used_percentage),
    num(.rate_limits.five_hour.resets_at),
    num(.rate_limits.seven_day.used_percentage),
    num(.rate_limits.seven_day.resets_at)
  ] | @tsv' 2>/dev/null) || exit 0

[ -n "$VALS" ] || exit 0

printf '%s\n' "$VALS" | awk -F'\t' -v now="$(date +%s)" '
function pace_color(diff) {
    if (diff >= 10)  return "\033[1;38;2;41;211;152m"    # 緑   余裕
    if (diff > -10)  return "\033[1;38;2;154;165;177m"   # 灰   オンペース
    if (diff > -25)  return "\033[1;38;2;250;194;154m"   # 橙   やや使いすぎ
    return "\033[1;38;2;233;86;120m"                     # 赤   かなり使いすぎ
}

function bar(remain,   filled, i, out) {
    filled = int(remain / 20)
    if (filled > 5) filled = 5
    if (filled < 0) filled = 0
    out = ""
    for (i = 0; i < 5; i++) out = out (i < filled ? "█" : "░")
    return out
}

# 上位2単位まで。6d21h / 3h54m / 47m / <1m
function short_time(sec,   d, h, m) {
    if (sec < 0) sec = 0
    d = int(sec / 86400)
    h = int((sec % 86400) / 3600)
    m = int((sec % 3600) / 60)
    if (d > 0) return d "d" h "h"
    if (h > 0) return h "h" m "m"
    if (m > 0) return m "m"
    return "<1m"
}

function gauge(label, used, resets, window,   remain, elapsed, elapsed_pct, diff) {
    remain = 100 - used
    if (remain < 0) remain = 0
    if (remain > 100) remain = 100

    elapsed = now - (resets - window)
    if (elapsed < 0) elapsed = 0
    if (elapsed > window) elapsed = window
    elapsed_pct = elapsed / window * 100

    diff = elapsed_pct - used

    return LABEL label " " RESET pace_color(diff) bar(remain) int(remain) "%" RESET
}

BEGIN {
    LABEL   = "\033[38;2;110;115;125m"   # 枠ラベル
    SEP     = "\033[38;2;80;85;95m"      # 区切りの縦線
    DIM     = "\033[1;38;2;120;120;128m" # 残り時間
    RESET   = "\033[0m"
    FIVE_H  = 18000
    SEVEN_D = 604800
    BAR     = " " SEP "│" RESET " "
}

{
    out = ""
    if ($1 != "-" && $2 != "-") out = gauge("5h", $1 + 0, $2 + 0, FIVE_H)
    if ($3 != "-" && $4 != "-") {
        out = (out == "" ? "" : out BAR) gauge("7d", $3 + 0, $4 + 0, SEVEN_D) \
              BAR DIM short_time($4 + 0 - now) RESET
    }
    if (out != "") print out
}
'
