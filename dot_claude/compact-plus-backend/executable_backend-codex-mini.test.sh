#!/bin/bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$DIR/executable_backend-codex-mini.sh"
TMP=$(mktemp -d)
export TMPDIR="$TMP"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/claude-compact-state"

# Create a fake codex executable to avoid real API calls
CODEX_BIN="$TMP/codex"
cat > "$CODEX_BIN" <<'CODEX_SCRIPT'
#!/bin/bash
# Fake codex that outputs a canned compact-prep state
cat <<'STATE'
# Compact Prep State

This is a test output from fake codex.
STATE
CODEX_SCRIPT
chmod +x "$CODEX_BIN"

# Prepend fake codex to PATH
export PATH="$TMP:$PATH"

# Test (A): fresh manual → codex not called, existing state echoed
echo "Test (A): fresh manual marker → existing state echoed..."
SID="okid"
printf '# Compact Prep State\nKEEP-MANUAL\n' > "$TMP/claude-compact-state/$SID.md"
touch "$TMP/claude-compact-state/$SID.manual"
OUT=$(SESSION_ID="$SID" SYSTEM_PROMPT="test" bash "$S" <<< "prompt")
echo "$OUT" | grep -q "KEEP-MANUAL" || { echo "FAIL(A): manual not echoed"; exit 1; }
echo "PASS(A)"

# Test (B): structure validation (checks for gpt-5.4-mini and sed pattern)
echo "Test (B): backend structure validation..."
grep -q 'gpt-5.4-mini' "$S" || { echo "FAIL(B): missing gpt-5.4-mini"; exit 1; }
grep -q "sed -n '/^# Compact Prep State/,\$p'" "$S" || { echo "FAIL(B): missing sed pattern"; exit 1; }
echo "PASS(B)"

# Test (C): session_id hardening - traversal attempts should not create files outside state dir
echo "Test (C): session_id traversal hardening..."
SESSION_ID='../../evil' SYSTEM_PROMPT="test" bash "$S" <<< "test" >/dev/null 2>&1
[[ -e /tmp/evil ]] && { echo "FAIL(C): traversal created file"; exit 1; }
echo "PASS(C)"

echo "PASS: backend guard + structure ok"
