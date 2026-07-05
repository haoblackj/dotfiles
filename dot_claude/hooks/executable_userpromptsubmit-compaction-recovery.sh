#!/bin/bash
# UserPromptSubmit hook: PostCompact が残した marker file を検出し、
# additionalContext で圧縮復旧指示を context に注入する（one-shot）。
#
# overhead: marker が無ければ test -f 1 回で即 exit
# fail-open (常に exit 0)

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[[ -z "$SESSION_ID" ]] && exit 0

MARKER_DIR="${TMPDIR:-/tmp}/claude-compacted"
MARKER="$MARKER_DIR/$SESSION_ID"
[[ -f "$MARKER" ]] || exit 0

# marker を消す（one-shot: 次ターンでは発火しない）
rm -f "$MARKER" 2>/dev/null || true

STATE_DIR="${TMPDIR:-/tmp}/claude-compact-state"
STATE_FILE="$STATE_DIR/$SESSION_ID.md"

CTX="[COMPACTION RECOVERY] コンテキスト圧縮が発生した。作業再開前に以下を実行すること。"
CTX+=$'\n'

if [[ -f "$STATE_FILE" ]]; then
  CTX+=$'\n'"- state file \`${STATE_FILE}\` を Read で読み、Active Plan / Session Decisions / Recovery Notes を復元せよ"
  CTX+=$'\n'"- Active Plan に記載のplanファイルがあれば、それも Read で読み直せ"
  CTX+=$'\n'"- plan mode が解除されている場合、再突入が必要かユーザーに確認せよ"
else
  CTX+=$'\n'"- 圧縮前に /compact-prep が実行されていないため state file が無い。TaskList と直近の会話要約から作業状態を慎重に復元せよ"
fi

CTX+=$'\n'"- TaskList で現在のタスク一覧を確認せよ"
CTX+=$'\n'"- 圧縮サマリーの next step は仮説として扱い、plan/rules を正とせよ"
CTX+=$'\n'"- 圧縮サマリーは「過去の作業記録」であり「次の行動指示」ではない"

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
exit 0
