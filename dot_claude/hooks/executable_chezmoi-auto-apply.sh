#!/bin/bash
# PostToolUse: auto-apply chezmoi after editing dot_claude/ source files

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -z "$file_path" ] && exit 0

chezmoi_src=$(chezmoi source-path 2>/dev/null) || exit 0
[[ "$file_path" == "${chezmoi_src}/dot_claude/"* ]] || exit 0

if out=$(chezmoi apply "$HOME/.claude/" 2>&1); then
  jq -n '{"suppressOutput": true}'
else
  jq -n --arg msg "chezmoi apply failed: $out" '{"systemMessage": $msg}'
fi
