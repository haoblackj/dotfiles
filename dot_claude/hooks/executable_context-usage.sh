#!/bin/bash
# 統制役が任意の時点でコンテキスト使用率を実測するための道具（penguinEx issue #73）。
#
# 読む場所は2つ、どちらもこのセッションで実際に読めることを確認済み:
#   - 窓の幅: ${TMPDIR:-/tmp}/claude-status-context-window/<session_id>
#     （statusline-context-window.sh が Claude Code 本体の
#     context_window.context_window_size を書いたもの）
#   - 使用量: ~/.claude/projects/<プロジェクトのスラッグ>/<session_id>.jsonl の
#     最後の assistant レコード（isSidechain が false）の message.usage にある
#     input_tokens + cache_read_input_tokens + cache_creation_input_tokens
#
# 最重要要件: 上のどちらかが欠けている／読めない／数値でないときは、
# 「0とする」「既定値を使う」を一切せず、理由を書いて非ゼロで終了する。
# 黙って測れたふりをして成功を返さない。
#
# session_id はプロジェクトのスラッグ（cwd依存）を跨いで一意なUUIDである前提で、
# transcript は projects 配下を横断的に検索して見つける。統制役が自分のセッションIDを
# 確実に知る経路がハーネス側に無いため、引数必須にした（環境変数を当てにしない）。

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

command -v jq >/dev/null 2>&1 || die "jq が無い"

# --- 窓の幅 ---
WINDOW_FILE="${TMPDIR:-/tmp}/claude-status-context-window/$SESSION_ID"

if [[ ! -f "$WINDOW_FILE" ]]; then
  die "窓の幅ファイルが無い: $WINDOW_FILE"
fi

WINDOW_SIZE=$(cat "$WINDOW_FILE" 2>/dev/null)
WINDOW_SIZE=$(printf '%s' "$WINDOW_SIZE" | tr -d '[:space:]')

if [[ -z "$WINDOW_SIZE" ]]; then
  die "窓の幅ファイルが空: $WINDOW_FILE"
fi

if [[ ! "$WINDOW_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  die "窓の幅が数値でない: '$WINDOW_SIZE' ($WINDOW_FILE)"
fi

# --- transcript を探す（プロジェクトのスラッグを跨いで検索） ---
mapfile -t CANDIDATES < <(find "$HOME/.claude/projects" -maxdepth 2 -type f -name "${SESSION_ID}.jsonl" 2>/dev/null)

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  die "transcript が見つからない (session_id=$SESSION_ID)"
fi

if [[ "${#CANDIDATES[@]}" -gt 1 ]]; then
  die "transcript の候補が複数ある、自動選択しない: ${CANDIDATES[*]}"
fi

TRANSCRIPT="${CANDIDATES[0]}"

if [[ ! -r "$TRANSCRIPT" ]]; then
  die "transcript が読めない: $TRANSCRIPT"
fi

# 最後の「isSidechain=false かつ type=assistant」レコードの usage を取り出す。
# jq はJSONLを単一ストリームとして扱えるので、行ごとにパースしなくてよい
# （壊れた行があれば jq がエラーで落ち、$? が非ゼロになる＝それも失敗として拾う）。
LAST_USAGE_JSON=$(jq -c '
  select(.type == "assistant" and .isSidechain == false) | .message.usage // empty
' "$TRANSCRIPT" 2>/dev/null | tail -n 1)
JQ_STATUS=$?

if [[ $JQ_STATUS -ne 0 ]]; then
  die "transcript の解析に失敗した（壊れたJSON行の可能性）: $TRANSCRIPT"
fi

if [[ -z "$LAST_USAGE_JSON" ]]; then
  die "isSidechain=false の assistant レコードが1件も無い（またはusageが無い）: $TRANSCRIPT"
fi

INPUT_TOKENS=$(printf '%s' "$LAST_USAGE_JSON" | jq -r '.input_tokens // empty')
CACHE_READ=$(printf '%s' "$LAST_USAGE_JSON" | jq -r '.cache_read_input_tokens // empty')
CACHE_CREATION=$(printf '%s' "$LAST_USAGE_JSON" | jq -r '.cache_creation_input_tokens // empty')

for pair in "input_tokens:$INPUT_TOKENS" "cache_read_input_tokens:$CACHE_READ" "cache_creation_input_tokens:$CACHE_CREATION"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if [[ -z "$value" ]]; then
    die "usage.$name が欠けている: $TRANSCRIPT"
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    die "usage.$name が数値でない: '$value' ($TRANSCRIPT)"
  fi
done

USAGE_TOKENS=$((INPUT_TOKENS + CACHE_READ + CACHE_CREATION))

PCT=$(awk -v u="$USAGE_TOKENS" -v w="$WINDOW_SIZE" 'BEGIN { printf "%.1f", (u / w) * 100 }')

echo "session:       $SESSION_ID"
echo "window_tokens:  $WINDOW_SIZE"
echo "usage_tokens:   $USAGE_TOKENS (input=$INPUT_TOKENS cache_read=$CACHE_READ cache_creation=$CACHE_CREATION)"
echo "usage_pct:      ${PCT}%"

exit 0
