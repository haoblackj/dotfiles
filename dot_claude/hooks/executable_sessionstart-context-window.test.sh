#!/usr/bin/env bash
# sessionstart-context-window.sh のユニットテスト。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/executable_sessionstart-context-window.sh"
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

marker_of() { # session_id
  cat "$TMPDIR_TEST/claude-context-window/$1" 2>/dev/null || echo ''
}

# --- 1. [1m] サフィックス付き → 1,000,000 が書かれる ---
out="$(printf '%s' '{"session_id":"sess-1","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5[1m]"}' | "$SCRIPT")"; rc=$?
check "[1m]付き → 空stdout" "" "$out"
check "[1m]付き → exit 0" "0" "$rc"
check "[1m]付き → マーカーに1000000とモデル名" "1000000 claude-opus-5[1m]" "$(marker_of sess-1)"

# --- 2. サフィックス無しの既知モデル → 世代テーブルの値が書かれる ---
printf '%s' '{"session_id":"sess-2","model":"claude-opus-5"}' | "$SCRIPT" >/dev/null
check "opus-5(サフィックス無し) → マーカーに200000とモデル名" "200000 claude-opus-5" "$(marker_of sess-2)"

printf '%s' '{"session_id":"sess-2b","model":"claude-sonnet-5"}' | "$SCRIPT" >/dev/null
check "sonnet-5 → マーカーに1000000とモデル名" "1000000 claude-sonnet-5" "$(marker_of sess-2b)"

printf '%s' '{"session_id":"sess-2c","model":"claude-haiku-4-5"}' | "$SCRIPT" >/dev/null
check "haiku-4-5 → マーカーに200000とモデル名" "200000 claude-haiku-4-5" "$(marker_of sess-2c)"

# --- 3. model フィールド欠落 → マーカーを作らず exit 0 ---
out="$(printf '%s' '{"session_id":"sess-3","hook_event_name":"SessionStart"}' | "$SCRIPT")"; rc=$?
check "model欠落 → 空stdout" "" "$out"
check "model欠落 → exit 0" "0" "$rc"
check "model欠落 → マーカー未作成" "no" "$([ -f "$TMPDIR_TEST/claude-context-window/sess-3" ] && echo yes || echo no)"

# --- 4. model が object 形式でも .model.id を拾う ---
printf '%s' '{"session_id":"sess-4","model":{"id":"claude-opus-5[1m]","display_name":"Opus 5"}}' | "$SCRIPT" >/dev/null
check "model がobject → .model.id から1000000とモデル名" "1000000 claude-opus-5[1m]" "$(marker_of sess-4)"

# --- 5. session_id にパストラバーサル文字列 → マーカーdir外に副作用なし ---
out="$(printf '%s' '{"session_id":"../evil","model":"claude-opus-5[1m]"}' | "$SCRIPT")"; rc=$?
check "session_id=../evil → 空stdout" "" "$out"
check "session_id=../evil → exit 0" "0" "$rc"
check "session_id=../evil → TMPDIR直下にファイルが作られない" "no" "$([ -f "$TMPDIR_TEST/evil" ] && echo yes || echo no)"

out="$(printf '%s' '{"session_id":"a/b","model":"claude-opus-5[1m]"}' | "$SCRIPT")"; rc=$?
check "session_id=a/b → 空stdout" "" "$out"
check "session_id=a/b → exit 0" "0" "$rc"
check "session_id=a/b → claude-context-window/a に副作用なし" "no" "$([ -e "$TMPDIR_TEST/claude-context-window/a" ] && echo yes || echo no)"

# --- 6. 壊れたJSON → クラッシュせず exit 0 ---
out="$(printf '%s' 'not json at all' | "$SCRIPT")"; rc=$?
check "壊れたJSON → 空stdout" "" "$out"
check "壊れたJSON → exit 0" "0" "$rc"

# --- 7. libのsourceに失敗した場合はfail-open(exit 0, 空stdout) ---
NOLIB_DIR="$(mktemp -d)"
cp "$SCRIPT" "$NOLIB_DIR/"
out="$(printf '%s' '{"session_id":"sess-nolib","model":"claude-opus-5"}' | bash "$NOLIB_DIR/$(basename "$SCRIPT")")"; rc=$?
check "lib無し → 空stdout" "" "$out"
check "lib無し → exit 0" "0" "$rc"
rm -rf "$NOLIB_DIR"

rm -rf "$TMPDIR_TEST"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
