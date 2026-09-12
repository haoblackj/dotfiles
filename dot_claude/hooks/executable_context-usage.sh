#!/bin/bash
# 統制役が任意の時点でコンテキスト使用率を実測するための道具（penguinEx issue #73）。
#
# 読む場所は2つ。どちらも statusline-context-window.sh が Claude Code 本体の
# statusLine 入力 JSON から転記したマーカーで、値は本体が計算したもの:
#   - 窓の幅:  ${TMPDIR:-/tmp}/claude-status-context-window/<session_id>
#              （context_window.context_window_size）
#   - 使用率:  ${TMPDIR:-/tmp}/claude-status-context-usage/<session_id>
#              （context_window.used_percentage。/compact 直後は null になりマーカーが消え、
#              次の API 呼び出しで圧縮後の値に戻る）
#
# 以前は transcript の最後の assistant レコードの usage を自前で足していたが、/compact 直後は
# 圧縮前の最後のレコードを拾って古い値を出す（2026-09-12 に確認）。公式の値に一本化した。
#
# 最重要要件: 上のどちらかが欠けている／読めない／数値でないときは、
# 「0とする」「既定値を使う」を一切せず、理由を書いて非ゼロで終了する。
# 黙って測れたふりをして成功を返さない。
#
# 統制役が自分のセッションIDを確実に知る経路がハーネス側に無いため、引数必須にした。

set -uo pipefail

die() {
  echo "MEASURE_FAILED: $1" >&2
  exit 1
}

SESSION_ID="${1:-}"

if [[ -z "$SESSION_ID" ]]; then
  echo "使い方: context-usage.sh <session_id>" >&2
  die "session_id が渡されていない"
fi

# statusline-context-window.sh と同じパストラバーサル対策の正規表現。
if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die "session_id の形式が不正: $SESSION_ID"
fi

read_marker() { # name path -> value (stdout)。欠け・空は die
  local name="$1" path="$2" value
  [[ -f "$path" ]] || die "$name のマーカーが無い: $path"
  value=$(head -n1 "$path" 2>/dev/null | tr -d '[:space:]')
  [[ -n "$value" ]] || die "$name のマーカーが空: $path"
  printf '%s' "$value"
}

# --- 窓の幅 ---
WINDOW_SIZE=$(read_marker "窓の幅" "${TMPDIR:-/tmp}/claude-status-context-window/$SESSION_ID") || exit 1
if [[ ! "$WINDOW_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  die "窓の幅が数値でない: '$WINDOW_SIZE'"
fi

# --- 使用率 ---
# マーカーが無いのは「セッション最初の API 呼び出し前」「/compact 直後で次の呼び出し前」
# 「statusLine が動いていない」のいずれか。どれも「いま測れない」なので失敗として返す。
USAGE_PCT=$(read_marker "使用率" "${TMPDIR:-/tmp}/claude-status-context-usage/$SESSION_ID") || exit 1
if [[ ! "$USAGE_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  die "使用率が数値でない: '$USAGE_PCT'"
fi

echo "session:       $SESSION_ID"
echo "window_tokens:  $WINDOW_SIZE"
echo "usage_pct:      ${USAGE_PCT}%  (Claude Code 本体の context_window.used_percentage)"

exit 0
