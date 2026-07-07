#!/bin/bash
# compact-plus 両取り E2E: producer→plugin③→backend guard→plugin PostCompact→plugin② を
# live実体(deployed producer/backend + plugin cache hooks)で通す。codex は呼ばない(guard経路のみ)。
set -uo pipefail
# plugin バージョンをハードコードせず動的解決(更新耐性)
CACHE=$(find "$HOME/.claude/plugins/cache" -path '*compact-plus/*/hooks' -type d 2>/dev/null | sort -V | tail -1)
[[ -n "$CACHE" && -d "$CACHE" ]] || { echo "FAIL0: compact-plus plugin hooks 未検出(installされているか)"; exit 1; }
PROD=~/.claude/hooks/userpromptsubmit-compact-prep-reminder.sh
BACKEND=~/.claude/compact-plus-backend/backend-codex-mini.sh
TP="$HOME/.claude/projects/-home-yagu001-repo-github-com-haoblackj-penguinEx/9bbdb771-6e0a-427a-88e1-c79f8f1d071d.jsonl"
TMP=$(mktemp -d); export TMPDIR="$TMP"; trap 'rm -rf "$TMP"' EXIT
SID="e2e$$"
J="{\"session_id\":\"$SID\",\"transcript_path\":\"$TP\",\"trigger\":\"manual\",\"custom_instructions\":\"\"}"

# 1) producer: 閾値強制 → claude-compact-warn/$SID (PCT入り)
CLAUDE_CONTEXT_WINDOW_TOKENS=1 CLAUDE_COMPACT_WARN_THRESHOLD=1 bash -c "echo '$J' | bash '$PROD'" >/dev/null 2>&1
[[ -f "$TMP/claude-compact-warn/$SID" ]] || { echo "FAIL1: producer warn未生成"; exit 1; }

# 2) plugin③: warn消費 → COMPACT REMINDER注入 + warned生成 + warn削除
OUT=$(echo "$J" | bash "$CACHE/userpromptsubmit-compact-plus-reminder.sh" 2>/dev/null)
echo "$OUT" | grep -q 'COMPACT REMINDER' || { echo "FAIL2: plugin③ reminder未注入"; exit 1; }
[[ -f "$TMP/claude-compact-warned/$SID" && ! -f "$TMP/claude-compact-warn/$SID" ]] || { echo "FAIL2b: warn→warned遷移せず"; exit 1; }

# 3) backend guard: fresh .manual → 既存state echo(codex未呼び出し)
mkdir -p "$TMP/claude-compact-state"
printf '# Compact Prep State\nKEEP-MANUAL\n' > "$TMP/claude-compact-state/$SID.md"
touch "$TMP/claude-compact-state/$SID.manual"
GOUT=$(SESSION_ID="$SID" SYSTEM_PROMPT=x bash "$BACKEND" <<< "prompt")
echo "$GOUT" | grep -q KEEP-MANUAL || { echo "FAIL3: backend guardが手動state温存せず"; exit 1; }

# 4) plugin PostCompact: claude-compacted/$SID 生成 + warned リセット
echo "$J" | bash "$CACHE/compaction-recovery.sh" >/dev/null 2>&1
[[ -f "$TMP/claude-compacted/$SID" ]] || { echo "FAIL4: compacted marker未生成"; exit 1; }

# 5) plugin② UPS recovery: compacted消費 → COMPACTION RECOVERY注入
ROUT=$(echo "$J" | bash "$CACHE/userpromptsubmit-compaction-recovery.sh" 2>/dev/null)
echo "$ROUT" | grep -q 'COMPACTION RECOVERY' || { echo "FAIL5: plugin② recovery未注入"; exit 1; }

echo "PASS: full two-take cycle verified (producer→③→guard→PostCompact→②)"
