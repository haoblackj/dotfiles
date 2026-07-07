#!/bin/bash
# compact-plus backend: codex exec gpt-5.4-mini (ChatGPT Plus frame).
# fresh な手動 compact-prep state があれば codex を呼ばず既存 state を echo (手動優先・quota 節約).
# env: SYSTEM_PROMPT, SESSION_ID, TMPDIR / stdin: user_prompt
set -uo pipefail

SID="${SESSION_ID:-}"
if [[ "$SID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  MANUAL="${TMPDIR:-/tmp}/claude-compact-state/$SID.manual"
  STATE="${TMPDIR:-/tmp}/claude-compact-state/$SID.md"
  if [[ -f "$MANUAL" && -f "$STATE" ]]; then
    now=$(date +%s)
    mt=$(stat -c %Y "$MANUAL" 2>/dev/null || echo 0)
    if [[ "$mt" =~ ^[0-9]+$ ]] && (( now - mt < 1800 )); then
      cat "$STATE"
      exit 0  # 手動 state 温存、codex skip
    fi
  fi
fi

{ printf '%s\n\n' "${SYSTEM_PROMPT:-}"; cat; } \
  | codex exec -m gpt-5.4-mini -c model_reasoning_effort=low \
      --sandbox read-only --skip-git-repo-check --ignore-user-config --ephemeral - 2>/dev/null \
  | sed -n '/^# Compact Prep State/,$p'
