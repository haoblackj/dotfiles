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

# --- 13. claude-opus-5(サフィックス無し) → 200K窓・既定85%閾値と判定される ---
TR13="$TMPDIR_TEST/t13.jsonl"
make_transcript "$TR13" 140000 "claude-opus-5"   # 200,000のうち140002 tokens = 70% → 85%未満
out="$(printf '%s' "{\"session_id\":\"sess-13\",\"transcript_path\":\"$TR13\"}" | "$SCRIPT")"
check "opus-5(200K窓)は70%では既定85%閾値に届かず空stdout" "" "$out"

TR13B="$TMPDIR_TEST/t13b.jsonl"
make_transcript "$TR13B" 180000 "claude-opus-5"   # 200,000のうち180002 tokens = 90% → 85%超過
out="$(printf '%s' "{\"session_id\":\"sess-13b\",\"transcript_path\":\"$TR13B\"}" | "$SCRIPT")"
check "opus-5(200K窓)は90%で warn marker が作成される" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-13b" ] && echo yes || echo no)"

make_window_marker() { # session_id window model
  mkdir -p "$TMPDIR_TEST/claude-context-window"
  printf '%s %s\n' "$2" "$3" > "$TMPDIR_TEST/claude-context-window/$1"
}

# --- 14. マーカーがあれば transcript のモデル名テーブルより優先される(マーカーのモデル名がtranscriptと一致する場合) ---
TR14="$TMPDIR_TEST/t14.jsonl"
make_transcript "$TR14" 180000 "claude-opus-5"   # テーブルなら200K窓で90% → 警告。マーカー1Mかつモデル一致なら18% → 警告なし
make_window_marker "sess-14" 1000000 "claude-opus-5[1m]"
out="$(printf '%s' "{\"session_id\":\"sess-14\",\"transcript_path\":\"$TR14\"}" | "$SCRIPT")"
check "マーカー1M(モデル一致) → transcriptのopus-5(200K)より優先され18%で警告なし" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-14" ] && echo yes || echo no)"

# FINDING-3: 「警告が作られない」だけでなく、閾値を極端に下げて実際に1M窓が使われたこと(PCT=18)を直接主張する。
out="$(CLAUDE_COMPACT_WARN_THRESHOLD=1 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-14\\\",\\\"transcript_path\\\":\\\"$TR14\\\"}\" | \"$SCRIPT\"")"
check "[FINDING-3] ケース14を閾値1で再実行するとwarn markerの中身が18(1M窓が使われた直接証拠)" "18" "$(cat "$TMPDIR_TEST/claude-compact-warn/sess-14" 2>/dev/null || echo '')"

# --- FINDING-1: マーカーのモデル名がtranscriptと食い違う場合、マーカーは無効になりテーブルに落ちる ---
# 1Mセッション開始時にSessionStartが書いたマーカー(claude-opus-5[1m])が、/model による
# 200Kモデル(claude-haiku-4-5)への切替後もそのまま残っている状況を再現する。
TR_MISMATCH="$TMPDIR_TEST/t_mismatch.jsonl"
make_transcript "$TR_MISMATCH" 180000 "claude-haiku-4-5"
make_window_marker "sess-mismatch" 1000000 "claude-opus-5[1m]"
out="$(printf '%s' "{\"session_id\":\"sess-mismatch\",\"transcript_path\":\"$TR_MISMATCH\"}" | "$SCRIPT")"
check "[FINDING-1] マーカーのモデル(opus-5[1m])とtranscriptのモデル(haiku-4-5)が食い違う → マーカー破棄しテーブル(200K)で90%警告" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-mismatch" ] && echo yes || echo no)"
warn_pct_mismatch="$(cat "$TMPDIR_TEST/claude-compact-warn/sess-mismatch" 2>/dev/null || echo '')"
check "[FINDING-1] モデル食い違いケースのPCTが90" "90" "$warn_pct_mismatch"

# --- FINDING-1 退行再現(実装前にRED確認済み): モデル名を伴わない旧形式マーカーは無効として扱う ---
# 旧sessionstart(修正前)が書いていた「窓幅のみ」の1行マーカーがそのまま残っているケース。
# 旧形式を信用すると/model切替後も古い窓幅が勝ち続け、警告が出ない退行がそのまま残る。
TR_OLDFMT="$TMPDIR_TEST/t_oldfmt.jsonl"
make_transcript "$TR_OLDFMT" 180000 "claude-haiku-4-5"
mkdir -p "$TMPDIR_TEST/claude-context-window"
printf '1000000\n' > "$TMPDIR_TEST/claude-context-window/sess-oldfmt"
out="$(printf '%s' "{\"session_id\":\"sess-oldfmt\",\"transcript_path\":\"$TR_OLDFMT\"}" | "$SCRIPT")"
check "[FINDING-1 退行再現] モデル名を伴わない旧形式マーカーは無効としテーブル(200K)で90%警告" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-oldfmt" ] && echo yes || echo no)"

# --- 15. 環境変数はマーカーより優先される ---
TR15="$TMPDIR_TEST/t15.jsonl"
make_transcript "$TR15" 180000 "claude-opus-5"
make_window_marker "sess-15" 1000000 "claude-opus-5[1m]"
out="$(CLAUDE_CONTEXT_WINDOW_TOKENS=200000 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-15\\\",\\\"transcript_path\\\":\\\"$TR15\\\"}\" | \"$SCRIPT\"")"
check "環境変数200K → マーカー1Mより優先され90%で警告" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-15" ] && echo yes || echo no)"
check "環境変数優先時の PCT が90であること" "90" "$(cat "$TMPDIR_TEST/claude-compact-warn/sess-15" 2>/dev/null || echo '')"

# --- 16. マーカーの窓幅が不正なら transcript のテーブルに落ちる(モデル名は一致させ、窓幅だけを不正にして原因を切り分ける) ---
for bad in "notanumber" "0" "0100"; do
  sid="sess-16-$bad"
  TR16="$TMPDIR_TEST/t16-$bad.jsonl"
  make_transcript "$TR16" 180000 "claude-opus-5"   # テーブルなら200K窓で90% → 警告
  make_window_marker "$sid" "$bad" "claude-opus-5[1m]"
  stderr_file="$TMPDIR_TEST/t16-$bad.stderr"
  out="$(printf '%s' "{\"session_id\":\"$sid\",\"transcript_path\":\"$TR16\"}" | "$SCRIPT" 2>"$stderr_file")"; rc=$?
  check "マーカー不正($bad) → exit 0" "0" "$rc"
  check "マーカー不正($bad) → テーブル(200K)に落ちて90%で警告" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/$sid" ] && echo yes || echo no)"
  check "マーカー不正($bad) → stderrノイズ無し" "" "$(cat "$stderr_file")"
done

# --- 17. マーカーが無ければ従来どおり transcript のテーブルに落ちる ---
TR17="$TMPDIR_TEST/t17.jsonl"
make_transcript "$TR17" 700000 "claude-sonnet-5"   # テーブルで1M窓 → 70%で60%閾値超過
out="$(printf '%s' "{\"session_id\":\"sess-17\",\"transcript_path\":\"$TR17\"}" | "$SCRIPT")"
check "マーカー無し → テーブル(1M)で70%の警告" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-17" ] && echo yes || echo no)"

# --- 18. 使用量が窓幅を超えたら保険で1Mとして扱う(マーカー・環境変数なし) ---
TR18="$TMPDIR_TEST/t18.jsonl"
make_transcript "$TR18" 300000 "claude-opus-5"   # テーブルは200K窓。300002 tokens は窓を超えている
out="$(printf '%s' "{\"session_id\":\"sess-18\",\"transcript_path\":\"$TR18\"}" | "$SCRIPT")"
check "使用量>窓幅 → 保険で1M窓となり30%で警告なし" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-18" ] && echo yes || echo no)"

# FINDING-3: 閾値を1に下げて再実行し、warn markerの中身が30(=1M窓分母で計算された値)であることを直接主張する。
out="$(CLAUDE_COMPACT_WARN_THRESHOLD=1 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-18\\\",\\\"transcript_path\\\":\\\"$TR18\\\"}\" | \"$SCRIPT\"")"
check "[FINDING-3] ケース18を閾値1で再実行するとwarn markerの中身が30(保険で1M窓が使われた直接証拠)" "30" "$(cat "$TMPDIR_TEST/claude-compact-warn/sess-18" 2>/dev/null || echo '')"

# --- FINDING-4: マーカー由来の窓幅を使用量が超えたケース(保険とマーカーの組み合わせ) ---
TR_MARKER_INS="$TMPDIR_TEST/t_marker_ins.jsonl"
make_transcript "$TR_MARKER_INS" 300000 "claude-opus-5"   # マーカー(200K, モデル一致)を使用量300002が超えている
make_window_marker "sess-marker-ins" 200000 "claude-opus-5"
out="$(printf '%s' "{\"session_id\":\"sess-marker-ins\",\"transcript_path\":\"$TR_MARKER_INS\"}" | "$SCRIPT")"
check "[FINDING-4] マーカー由来の窓幅(200K)を使用量が超えたら保険で1M窓となり30%で警告なし" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-marker-ins" ] && echo yes || echo no)"

# --- 19. 保険は環境変数による手動指定にも適用される ---
TR19="$TMPDIR_TEST/t19.jsonl"
make_transcript "$TR19" 300000 "claude-opus-5"
out="$(CLAUDE_CONTEXT_WINDOW_TOKENS=200000 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-19\\\",\\\"transcript_path\\\":\\\"$TR19\\\"}\" | \"$SCRIPT\"")"
check "環境変数200Kでも使用量が超えていれば保険で1M窓となり警告なし" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-19" ] && echo yes || echo no)"

# FINDING-3: 閾値を1に下げて再実行し、warn markerの中身が30(=1M窓分母で計算された値)であることを直接主張する。
out="$(CLAUDE_CONTEXT_WINDOW_TOKENS=200000 CLAUDE_COMPACT_WARN_THRESHOLD=1 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-19\\\",\\\"transcript_path\\\":\\\"$TR19\\\"}\" | \"$SCRIPT\"")"
check "[FINDING-3] ケース19を閾値1で再実行するとwarn markerの中身が30(環境変数200Kでも保険で1M窓が使われた直接証拠)" "30" "$(cat "$TMPDIR_TEST/claude-compact-warn/sess-19" 2>/dev/null || echo '')"

make_status_marker() { # session_id window
  mkdir -p "$TMPDIR_TEST/claude-status-context-window"
  printf '%s\n' "$2" > "$TMPDIR_TEST/claude-status-context-window/$1"
}

# --- 20. SessionStartマーカーが無く、statusLineマーカーがあるとき → statusLineマーカーの窓幅が使われる ---
TR20="$TMPDIR_TEST/t20.jsonl"
make_transcript "$TR20" 180000 "claude-opus-5"   # テーブルなら200K窓で90% → 警告。statusLineマーカー1Mなら18% → 警告なし
make_status_marker "sess-20" 1000000
out="$(printf '%s' "{\"session_id\":\"sess-20\",\"transcript_path\":\"$TR20\"}" | "$SCRIPT")"
check "statusLineマーカーのみ(1M) → テーブル(200K)より優先され18%で警告なし" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-20" ] && echo yes || echo no)"

out="$(CLAUDE_COMPACT_WARN_THRESHOLD=1 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-20\\\",\\\"transcript_path\\\":\\\"$TR20\\\"}\" | \"$SCRIPT\"")"
check "ケース20を閾値1で再実行するとwarn markerの中身が18(statusLineマーカーの1M窓が使われた直接証拠)" "18" "$(cat "$TMPDIR_TEST/claude-compact-warn/sess-20" 2>/dev/null || echo '')"

# --- 21. SessionStartマーカーとstatusLineマーカーが両方あるとき → statusLineマーカー(実測値)が優先される ---
TR21="$TMPDIR_TEST/t21.jsonl"
make_transcript "$TR21" 180000 "claude-opus-5"
make_window_marker "sess-21" 200000 "claude-opus-5"   # SessionStartマーカー: 200K(モデル一致、テーブル由来の推測値)
make_status_marker "sess-21" 1000000                  # statusLineマーカー: 1M(実測値)
out="$(printf '%s' "{\"session_id\":\"sess-21\",\"transcript_path\":\"$TR21\"}" | "$SCRIPT")"
check "両マーカーあり → statusLineマーカー(1M)が優先され18%で警告なし" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-21" ] && echo yes || echo no)"

out="$(CLAUDE_COMPACT_WARN_THRESHOLD=1 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-21\\\",\\\"transcript_path\\\":\\\"$TR21\\\"}\" | \"$SCRIPT\"")"
check "ケース21を閾値1で再実行するとwarn markerの中身が18(statusLineマーカーが実際に優先された直接証拠)" "18" "$(cat "$TMPDIR_TEST/claude-compact-warn/sess-21" 2>/dev/null || echo '')"

# --- 22. statusLineマーカーの値が不正(SessionStartマーカー無し) → テーブルに落ちる ---
for bad in "notanumber" "0" "0100"; do
  sid="sess-22-$bad"
  TR22="$TMPDIR_TEST/t22-$bad.jsonl"
  make_transcript "$TR22" 180000 "claude-opus-5"   # テーブルなら200K窓で90% → 警告
  make_status_marker "$sid" "$bad"
  out="$(printf '%s' "{\"session_id\":\"$sid\",\"transcript_path\":\"$TR22\"}" | "$SCRIPT")"
  check "statusLineマーカー不正($bad) → テーブル(200K)に落ちて90%で警告" "yes" "$([ -f "$TMPDIR_TEST/claude-compact-warn/$sid" ] && echo yes || echo no)"
done

# --- 23. statusLineマーカーが有効なら、SessionStartマーカーの有効性に関わらず無条件で優先される ---
# 新しい優先順位(statusLineマーカーが2段目)では、SessionStartマーカーがモデル不一致で無効かどうかは
# そもそも評価されない。statusLineマーカーの値をテーブルデフォルト(haiku-4-5=200K)とは異なる1Mにして、
# 「実際にstatusLineマーカーが読まれた」ことをテーブルへの取りこぼしと区別できるようにする。
TR23="$TMPDIR_TEST/t23.jsonl"
make_transcript "$TR23" 180000 "claude-haiku-4-5"   # テーブルなら200K窓で90% → 警告。statusLineマーカー1Mなら18% → 警告なし
make_window_marker "sess-23" 1000000 "claude-opus-5[1m]"   # SessionStartマーカー: モデル不一致で無効になる
make_status_marker "sess-23" 1000000                       # statusLineマーカー: 1M(テーブルの200Kとは異なる値)
out="$(printf '%s' "{\"session_id\":\"sess-23\",\"transcript_path\":\"$TR23\"}" | "$SCRIPT")"
check "SessionStartマーカー無効 → statusLineマーカー(1M)へフォールスルーし18%で警告なし" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-23" ] && echo yes || echo no)"

out="$(CLAUDE_COMPACT_WARN_THRESHOLD=1 bash -c "printf '%s' \"{\\\"session_id\\\":\\\"sess-23\\\",\\\"transcript_path\\\":\\\"$TR23\\\"}\" | \"$SCRIPT\"")"
check "ケース23を閾値1で再実行するとwarn markerの中身が18(statusLineマーカーの1M窓が実際に読まれた直接証拠、テーブル(200K)なら90になるはず)" "18" "$(cat "$TMPDIR_TEST/claude-compact-warn/sess-23" 2>/dev/null || echo '')"

# --- 24. statusLineマーカーが不正で、SessionStartマーカーが有効なとき → SessionStartマーカーへフォールバックする ---
TR24="$TMPDIR_TEST/t24.jsonl"
make_transcript "$TR24" 180000 "claude-opus-5"        # テーブルなら200K窓で90% → 警告
make_status_marker "sess-24" "notanumber"             # statusLineマーカー: 不正値
make_window_marker "sess-24" 1000000 "claude-opus-5"  # SessionStartマーカー: 1M(モデル一致)
out="$(printf '%s' "{\"session_id\":\"sess-24\",\"transcript_path\":\"$TR24\"}" | "$SCRIPT")"
check "statusLineマーカー不正 → SessionStartマーカー(1M)へフォールバックし18%で警告なし" "no" "$([ -f "$TMPDIR_TEST/claude-compact-warn/sess-24" ] && echo yes || echo no)"

# --- FINDING-6: libのsourceに失敗した場合はfail-open(exit 0, 空stdout) ---
NOLIB_DIR="$(mktemp -d)"
cp "$SCRIPT" "$NOLIB_DIR/"
out="$(printf '%s' '{"session_id":"sess-nolib","transcript_path":"/no/such/file"}' | bash "$NOLIB_DIR/$(basename "$SCRIPT")")"; rc=$?
check "[FINDING-6] lib無し → 空stdout" "" "$out"
check "[FINDING-6] lib無し → exit 0" "0" "$rc"
rm -rf "$NOLIB_DIR"

rm -rf "$TMPDIR_TEST"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
