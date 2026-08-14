#!/usr/bin/env bash
# statusline-context-window.sh のユニットテスト。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/executable_statusline-context-window.sh"
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
  cat "$TMPDIR_TEST/claude-status-context-window/$1" 2>/dev/null || echo ''
}

# ccstatusline をモックする。実際のバイナリを叩かず、stdinをそのままstdoutへ通すだけ。
FAKE_BIN="$TMPDIR_TEST/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/ccstatusline" <<'EOS'
#!/bin/bash
cat
EOS
chmod +x "$FAKE_BIN/ccstatusline"
export PATH="$FAKE_BIN:$PATH"

# --- 1. session_id と context_window_size が揃った入力 → マーカーに窓幅、stdoutは元のJSONがそのまま通る ---
INPUT1='{"session_id":"sess-1","context_window":{"context_window_size":1000000}}'
out="$(printf '%s' "$INPUT1" | "$SCRIPT")"; rc=$?
check "揃った入力 → マーカーに1000000" "1000000" "$(marker_of sess-1)"
check "揃った入力 → stdoutに元のJSONがそのまま通る" "$INPUT1" "$out"
check "揃った入力 → exit 0" "0" "$rc"

# --- 2. context_window_size が null → マーカー未作成、fail-open ---
INPUT2='{"session_id":"sess-2","context_window":{"context_window_size":null}}'
out="$(printf '%s' "$INPUT2" | "$SCRIPT")"; rc=$?
check "context_window_size=null → マーカー未作成" "" "$(marker_of sess-2)"
check "context_window_size=null → stdoutは元のJSONがそのまま通る" "$INPUT2" "$out"
check "context_window_size=null → exit 0" "0" "$rc"

# --- 3. context_window キー自体が無い → マーカー未作成、fail-open ---
INPUT3='{"session_id":"sess-3"}'
out="$(printf '%s' "$INPUT3" | "$SCRIPT")"; rc=$?
check "context_windowキー欠落 → マーカー未作成" "" "$(marker_of sess-3)"
check "context_windowキー欠落 → exit 0" "0" "$rc"

# --- 4. session_id にパストラバーサル文字列 → マーカーdir外に副作用なし ---
INPUT4='{"session_id":"../evil","context_window":{"context_window_size":1000000}}'
out="$(printf '%s' "$INPUT4" | "$SCRIPT")"; rc=$?
check "session_id=../evil → TMPDIR直下にファイルが作られない" "no" "$([ -f "$TMPDIR_TEST/evil" ] && echo yes || echo no)"
check "session_id=../evil → exit 0" "0" "$rc"

# --- 5. context_window_size が 0 や不正値 → マーカー未作成 ---
for bad in "0" '"notanumber"' "-5"; do
  sid="sess-5-$bad"
  input="{\"session_id\":\"$sid\",\"context_window\":{\"context_window_size\":$bad}}"
  printf '%s' "$input" | "$SCRIPT" >/dev/null
  check "context_window_size不正($bad) → マーカー未作成" "" "$(marker_of "$sid")"
done

# --- 6. 壊れたJSON → クラッシュせず exit 0、stdoutにそのまま通る(ccstatusline側の責務) ---
out="$(printf '%s' 'not json at all' | "$SCRIPT")"; rc=$?
check "壊れたJSON → マーカー未作成(session_idが取れない)" "" "$(marker_of 'sess-broken')"
check "壊れたJSON → exit 0" "0" "$rc"
check "壊れたJSON → stdoutに元の文字列がそのまま通る" "not json at all" "$out"

rm -rf "$TMPDIR_TEST"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
