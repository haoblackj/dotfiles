#!/usr/bin/env bash
# compaction-recovery.sh のユニットテスト。memory-reflect.test.sh に倣った純bashハーネス。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/compaction-recovery.sh"
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

# --- 1. session_id 不在 → marker を作らず exit 0 ---
out="$(printf '%s' '{}' | "$SCRIPT")"; rc=$?
check "session_id不在 → exit 0" "0" "$rc"
check "session_id不在 → marker dir 未作成" "no" "$([ -d "$TMPDIR_TEST/claude-compacted" ] && echo yes || echo no)"

# --- 2. session_id あり → marker file が作られる ---
out="$(printf '%s' '{"session_id":"sess-1","trigger":"manual"}' | "$SCRIPT")"; rc=$?
check "session_idあり → exit 0" "0" "$rc"
check "marker file 作成" "yes" "$([ -f "$TMPDIR_TEST/claude-compacted/sess-1" ] && echo yes || echo no)"
check "marker file に trigger=manual 記録" "manual" "$(awk '{print $2}' "$TMPDIR_TEST/claude-compacted/sess-1")"

# --- 3. warned cooldown marker が既にある場合、削除される ---
mkdir -p "$TMPDIR_TEST/claude-compact-warned"
touch "$TMPDIR_TEST/claude-compact-warned/sess-2"
printf '%s' '{"session_id":"sess-2"}' | "$SCRIPT" >/dev/null
check "warned marker が削除される" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warned/sess-2" ] && echo yes || echo no)"

# --- 4. 不正JSON → フェイルオープン ---
out="$(printf '%s' 'not json' | "$SCRIPT")"; rc=$?
check "不正JSON → 空stdout" "" "$out"
check "不正JSON → exit 0" "0" "$rc"

rm -rf "$TMPDIR_TEST"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
