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

printf '%s' "$INPUT" | ccstatusline
exit 0
