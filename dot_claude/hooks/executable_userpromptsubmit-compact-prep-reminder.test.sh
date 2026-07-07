#!/usr/bin/env bash
# userpromptsubmit-compact-prep-reminder.sh のユニットテスト。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/executable_userpromptsubmit-compact-prep-reminder.sh"
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

make_transcript() { # path used_tokens [model]
  local model="${3:-}"
  printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s,"output_tokens":10}}}\n' "$model" "$2" > "$1"
}

# --- 1. モデル不明(既定200K窓・85%閾値) → 閾値未満なら何も出力しない ---
TR1="$TMPDIR_TEST/t1.jsonl"
make_transcript "$TR1" 1000   # モデル無指定 → 200000窓のうち1002 tokens ≈ 0%
out="$(printf '%s' "{\"session_id\":\"sess-1\",\"transcript_path\":\"$TR1\"}" | "$SCRIPT")"; rc=$?
check "閾値未満 → 空stdout" "" "$out"
check "閾値未満 → exit 0" "0" "$rc"
check "閾値未満 → warn marker 未作成" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-1" ] && echo yes || echo no)"

# --- 2. モデル不明(200K窓) → 85%以上で warn marker を作成、additionalContext は出力しない ---
TR2="$TMPDIR_TEST/t2.jsonl"
make_transcript "$TR2" 180000   # 200000のうち180002 tokens ≈ 90%
out="$(printf '%s' "{\"session_id\":\"sess-2\",\"transcript_path\":\"$TR2\"}" | "$SCRIPT")"
check "閾値超過 → 空stdout" "" "$out"
check "閾値超過 → warn marker 作成" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-2" ] && echo yes || echo no)"
warn_pct="$(cat "$TMPDIR_TEST/claude-compact-warn/sess-2" 2>/dev/null || echo '')"
check "warn marker に PCT 値を含む" "yes" "$([ -n "$warn_pct" ] && [ "$warn_pct" -eq 90 ] 2>/dev/null && echo yes || echo no)"

# --- 3. cooldown中は再度閾値超過でも何も出力しない、warn marker も作成しない ---
mkdir -p "$TMPDIR_TEST/claude-compact-warned"
touch "$TMPDIR_TEST/claude-compact-warned/sess-2"
rm -f "$TMPDIR_TEST/claude-compact-warn/sess-2"
out="$(printf '%s' "{\"session_id\":\"sess-2\",\"transcript_path\":\"$TR2\"}" | "$SCRIPT")"
check "cooldown中 → 空stdout" "" "$out"
check "cooldown中 → warn marker 作成されない" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-2" ] && echo yes || echo no)"

# --- 4. CLAUDE_COMPACT_WARN_THRESHOLD で閾値を変更できる ---
TR3="$TMPDIR_TEST/t3.jsonl"
make_transcript "$TR3" 10000   # ≈5%
out="$(CLAUDE_COMPACT_WARN_THRESHOLD=3 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-3\\\",\\\"transcript_path\\\":\\\"$TR3\\\"}\" | \"$SCRIPT\"")"
check "閾値を環境変数で下げると5%で warn marker が作成される" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-3" ] && echo yes || echo no)"

# --- 5. transcript_path が存在しない → フェイルオープン ---
out="$(printf '%s' '{"session_id":"sess-4","transcript_path":"/no/such/file"}' | "$SCRIPT")"; rc=$?
check "transcript無し → 空stdout" "" "$out"
check "transcript無し → exit 0" "0" "$rc"

# --- 6. claude-sonnet-5 → 1M窓・既定60%閾値と判定される(70%は超過扱いになる) ---
TR6="$TMPDIR_TEST/t6.jsonl"
make_transcript "$TR6" 700000 "claude-sonnet-5"   # 1,000,000のうち700002 tokens = 70%
out="$(printf '%s' "{\"session_id\":\"sess-6\",\"transcript_path\":\"$TR6\"}" | "$SCRIPT")"
check "sonnet-5(1M窓)は70%で warn marker が作成される" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-6" ] && echo yes || echo no)"
warn_pct6="$(cat "$TMPDIR_TEST/claude-compact-warn/sess-6" 2>/dev/null || echo '')"
check "warn marker の PCT 値が 70 である" "yes" "$([ "$warn_pct6" = "70" ] && echo yes || echo no)"

# --- 7. claude-haiku-4-5 → 200K窓・既定85%閾値と判定される(70%はまだ超過しない) ---
TR7="$TMPDIR_TEST/t7.jsonl"
make_transcript "$TR7" 140000 "claude-haiku-4-5"   # 200,000のうち140002 tokens = 70%
out="$(printf '%s' "{\"session_id\":\"sess-7\",\"transcript_path\":\"$TR7\"}" | "$SCRIPT")"
check "haiku-4-5(200K窓)は70%ではまだ既定85%閾値に届かず空stdout" "" "$out"

# --- 8. CLAUDE_COMPACT_WARN_THRESHOLD が非数値 → 自動判定閾値にフォールバックしfail-open(exit 0) ---
TR8="$TMPDIR_TEST/t8.jsonl"
make_transcript "$TR8" 1000   # モデル無指定・200000窓のうち1002 tokens ≈ 0% → 既定85%未満
out="$(CLAUDE_COMPACT_WARN_THRESHOLD=abc bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-8\\\",\\\"transcript_path\\\":\\\"$TR8\\\"}\" | \"$SCRIPT\"")"; rc=$?
check "THRESHOLD非数値 → クラッシュせず exit 0" "0" "$rc"
check "THRESHOLD非数値 → 自動判定閾値(85%)を使い0%は未超過で空stdout" "" "$out"

# --- 9. CLAUDE_CONTEXT_WINDOW_TOKENS が非数値 → 自動判定ウィンドウにフォールバックしfail-open(exit 0) ---
TR9="$TMPDIR_TEST/t9.jsonl"
make_transcript "$TR9" 180000 "claude-haiku-4-5"   # 200,000のうち180002 tokens = 90% → haiku既定85%超過
out="$(CLAUDE_CONTEXT_WINDOW_TOKENS=notanumber bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-9\\\",\\\"transcript_path\\\":\\\"$TR9\\\"}\" | \"$SCRIPT\"")"; rc=$?
check "CONTEXT_WINDOW非数値 → クラッシュせず exit 0" "0" "$rc"
check "CONTEXT_WINDOW非数値 → 自動判定窓(200000)にフォールバックし90%で warn marker を作成" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-9" ] && echo yes || echo no)"

# --- 10. CLAUDE_CONTEXT_WINDOW_TOKENS=0 → 数字だが除数として不正 → 自動判定窓にフォールバックしゼロ除算を回避 ---
TR10="$TMPDIR_TEST/t10.jsonl"
make_transcript "$TR10" 180000   # モデル無指定 → 既定200000窓のうち180002 tokens ≈ 90% (既定85%超過)
out="$(CLAUDE_CONTEXT_WINDOW_TOKENS=0 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-10\\\",\\\"transcript_path\\\":\\\"$TR10\\\"}\" | \"$SCRIPT\"")"; rc=$?
check "CONTEXT_WINDOW=0 → ゼロ除算せずクラッシュせず exit 0" "0" "$rc"
check "CONTEXT_WINDOW=0 → 自動判定窓(200000)にフォールバックし90%で warn marker を作成" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-10" ] && echo yes || echo no)"
warn_pct10="$(cat "$TMPDIR_TEST/claude-compact-warn/sess-10" 2>/dev/null || echo '')"
check "CONTEXT_WINDOW=0 → 分母が自動判定の200000であることを反映(90%) " "yes" "$([ "$warn_pct10" = "90" ] && echo yes || echo no)"

# --- 11. CLAUDE_COMPACT_WARN_THRESHOLD=089(先頭ゼロ・8進誤パース対象) → 自動判定閾値にフォールバックしfail-open、stderrノイズ無し ---
TR11="$TMPDIR_TEST/t11.jsonl"
make_transcript "$TR11" 1000   # モデル無指定 → 200000窓のうち1002 tokens ≈ 0% (既定85%未満)
stderr_file="$TMPDIR_TEST/t11.stderr"
out="$(CLAUDE_COMPACT_WARN_THRESHOLD=089 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-11\\\",\\\"transcript_path\\\":\\\"$TR11\\\"}\" | \"$SCRIPT\"" 2>"$stderr_file")"; rc=$?
check "THRESHOLD=089(先頭ゼロ) → クラッシュせず exit 0" "0" "$rc"
check "THRESHOLD=089(先頭ゼロ) → 自動判定閾値(85%)にフォールバックし0%は未超過で空stdout" "" "$out"
check "THRESHOLD=089(先頭ゼロ) → 8進パースエラー等のstderrノイズ無し" "" "$(cat "$stderr_file")"

# --- 12. session_id にパストラバーサル文字列 → 空stdout・exit 0・cooldown marker dir外に副作用なし ---
TR12="$TMPDIR_TEST/t12.jsonl"
make_transcript "$TR12" 180000   # 200000のうち180002 tokens ≈ 90%(本来なら閾値超過するケース)
out="$(printf '%s' "{\"session_id\":\"../evil\",\"transcript_path\":\"$TR12\"}" | "$SCRIPT")"; rc=$?
check "session_id=../evil → 空stdout" "" "$out"
check "session_id=../evil → exit 0" "0" "$rc"
check "session_id=../evil → TMPDIR直下に評価対象ファイルが作られない" "no" "$([ -f "$TMPDIR_TEST/evil" ] && echo yes || echo no)"

out="$(printf '%s' "{\"session_id\":\"a/b\",\"transcript_path\":\"$TR12\"}" | "$SCRIPT")"; rc=$?
check "session_id=a/b → 空stdout" "" "$out"
check "session_id=a/b → exit 0" "0" "$rc"

rm -rf "$TMPDIR_TEST"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
