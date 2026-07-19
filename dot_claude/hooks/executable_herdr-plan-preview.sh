#!/bin/bash
# PostToolUse(Write): superpowersのプラン/spec初回書き込みをherdrの隣paneでglowレンダリング表示する

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
[ -n "${HERDR_TAB_ID:-}" ] || exit 0
command -v glow >/dev/null 2>&1 || exit 0

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -z "$file_path" ] && exit 0

case "$file_path" in
  */docs/superpowers/plans/*.md | */docs/superpowers/specs/*.md) ;;
  *) exit 0 ;;
esac
[ -f "$file_path" ] || exit 0

herdr_bin="${HERDR_BIN_PATH:-herdr}"

# 同タブに前回のplan-previewペインが残っていれば閉じてから作り直す
# (実行中ペインへの再送信はサイレントに飲まれることがあるため、reuseより閉じて再生成する方が安全)
existing_pane=$("$herdr_bin" pane list 2>/dev/null |
  jq -r --arg tab "$HERDR_TAB_ID" '.result.panes[]? | select(.tab_id==$tab and .label=="plan-preview") | .pane_id' |
  head -1)
[ -n "$existing_pane" ] && "$herdr_bin" pane close "$existing_pane" >/dev/null 2>&1

split_out=$("$herdr_bin" pane split "$HERDR_PANE_ID" --direction right --ratio 0.4 --no-focus 2>/dev/null)
target_pane=$(printf '%s' "$split_out" | jq -r '.result.pane.pane_id // empty')
[ -z "$target_pane" ] && exit 0

"$herdr_bin" pane rename "$target_pane" "plan-preview" >/dev/null 2>&1
"$herdr_bin" pane run "$target_pane" "glow -p '$file_path'" >/dev/null 2>&1

jq -n --arg path "$file_path" '{"suppressOutput": true, "systemMessage": ("herdr隣paneでプレビューを開いた: " + $path)}'
