#!/usr/bin/env bash
# userpromptsubmit-compaction-recovery.sh のユニットテスト。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/userpromptsubmit-compaction-recovery.sh"
TMPDIR_TEST="$(mktemp -d)"
export TMPDIR="$TMPDIR_TEST"
pass=0
fail=0

check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf 'ok   - %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL - %s\n   expected: [%s]\n   actual:   [%s]\n' "$1" "$2" "$3"
  fi
}

# --- 1. marker 無し → 何も出力せず exit 0 ---
out="$(printf '%s' '{"session_id":"sess-1"}' | "$SCRIPT")"; rc=$?
check "marker無し → 空stdout" "" "$out"
check "marker無し → exit 0" "0" "$rc"

# --- 2. marker あり・state file 無し → additionalContext を注入し marker削除 ---
mkdir -p "$TMPDIR_TEST/claude-compacted"
touch "$TMPDIR_TEST/claude-compacted/sess-2"
out="$(printf '%s' '{"session_id":"sess-2"}' | "$SCRIPT")"
ctx="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
check "state file無し → COMPACTION RECOVERY を含む" "yes" "$(printf '%s' "$ctx" | grep -q "COMPACTION RECOVERY" && echo yes || echo no)"
check "state file無し → state file言及なしの文言を含む" "yes" "$(printf '%s' "$ctx" | grep -q "state file が無い" && echo yes || echo no)"
check "marker が one-shot で削除される" "no" "$([ -f "$TMPDIR_TEST/claude-compacted/sess-2" ] && echo yes || echo no)"

# --- 3. marker あり・state file あり → state file パスへの言及を含む ---
mkdir -p "$TMPDIR_TEST/claude-compacted" "$TMPDIR_TEST/claude-compact-state"
touch "$TMPDIR_TEST/claude-compacted/sess-3"
echo "# dummy state" > "$TMPDIR_TEST/claude-compact-state/sess-3.md"
out="$(printf '%s' '{"session_id":"sess-3"}' | "$SCRIPT")"
ctx="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
check "state fileパスを含む" "yes" "$(printf '%s' "$ctx" | grep -qF "$TMPDIR_TEST/claude-compact-state/sess-3.md" && echo yes || echo no)"

# --- 4. 2回目の呼び出しは one-shot のため何も起きない ---
out="$(printf '%s' '{"session_id":"sess-3"}' | "$SCRIPT")"
check "2回目呼び出し → 空stdout" "" "$out"

# --- 5. session_id にパストラバーサル文字列 → 空stdout・exit 0・marker dir外に副作用なし ---
mkdir -p "$TMPDIR_TEST/claude-compacted"
out="$(printf '%s' '{"session_id":"../evil"}' | "$SCRIPT")"; rc=$?
check "session_id=../evil → 空stdout" "" "$out"
check "session_id=../evil → exit 0" "0" "$rc"
check "session_id=../evil → TMPDIR直下に評価対象ファイルが作られない" "no" "$([ -f "$TMPDIR_TEST/evil" ] && echo yes || echo no)"

out="$(printf '%s' '{"session_id":"a/b"}' | "$SCRIPT")"; rc=$?
check "session_id=a/b → 空stdout" "" "$out"
check "session_id=a/b → exit 0" "0" "$rc"

rm -rf "$TMPDIR_TEST"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
