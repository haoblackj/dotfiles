#!/usr/bin/env bats
# mutation-target: dot_claude/hooks/executable_userpromptsubmit-compact-prep-reminder.sh
# userpromptsubmit-compact-prep-reminder.sh のユニットテスト。
bats_require_minimum_version 1.5.0
set -u

json_input() { # session_id transcript_path -> JSON (stdout)
    printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2"
}

make_transcript() { # path used_tokens [model]
    local model="${3:-}"
    printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s,"output_tokens":10}}}\n' "$model" "$2" > "$1"
}

make_window_marker() { # session_id window model
    mkdir -p "$TMPDIR_TEST/claude-context-window"
    printf '%s %s\n' "$2" "$3" > "$TMPDIR_TEST/claude-context-window/$1"
}

make_status_marker() { # session_id window
    mkdir -p "$TMPDIR_TEST/claude-status-context-window"
    printf '%s\n' "$2" > "$TMPDIR_TEST/claude-status-context-window/$1"
}

warn_marker_of() { # session_id -> warn markerの中身 (stdout, 無ければ空)
    cat "$TMPDIR_TEST/claude-compact-warn/$1" 2>/dev/null || echo ''
}

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_userpromptsubmit-compact-prep-reminder.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

@test "1. モデル不明(既定200K窓・85%閾値) → 閾値未満なら何も出力しない" {
    make_transcript "$TMPDIR_TEST/t1.jsonl" 1000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-1 "$TMPDIR_TEST/t1.jsonl")"
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-1" ]
}

@test "2+3. 閾値超過でwarn markerを作成し、cooldown中は再度作成しない(順序依存)" {
    make_transcript "$TMPDIR_TEST/t2.jsonl" 180000   # 200000のうち180002 tokens ≈ 90%
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-2 "$TMPDIR_TEST/t2.jsonl")"
    [ "$output" = "" ]
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-2" ]
    [ "$(warn_marker_of sess-2)" = "90" ]

    # cooldown: compact-plus プラグインの reminder hook が書いた warned marker を模す。
    # ケース3はケース2が作った sess-2 の warn marker を rm してから読み直すため、
    # この対は1つの @test に留めて順序を保証する。
    mkdir -p "$TMPDIR_TEST/claude-compact-warned"
    touch "$TMPDIR_TEST/claude-compact-warned/sess-2"
    rm -f "$TMPDIR_TEST/claude-compact-warn/sess-2"
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-2 "$TMPDIR_TEST/t2.jsonl")"
    [ "$output" = "" ]
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-2" ]
}

@test "4. CLAUDE_COMPACT_WARN_THRESHOLDで閾値を変更できる" {
    make_transcript "$TMPDIR_TEST/t3.jsonl" 10000   # ≈5%
    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=3 "$SCRIPT" <<< "$(json_input sess-3 "$TMPDIR_TEST/t3.jsonl")"
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-3" ]
}

@test "5. transcript_pathが存在しない → フェイルオープン" {
    run --separate-stderr "$SCRIPT" <<< '{"session_id":"sess-4","transcript_path":"/no/such/file"}'
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
}

@test "6. claude-sonnet-5 → 1M窓・既定60%閾値と判定される(70%は超過扱いになる)" {
    make_transcript "$TMPDIR_TEST/t6.jsonl" 700000 "claude-sonnet-5"   # 1,000,000のうち700002 tokens = 70%
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-6 "$TMPDIR_TEST/t6.jsonl")"
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-6" ]
    [ "$(warn_marker_of sess-6)" = "70" ]
}

@test "7. claude-haiku-4-5 → 200K窓・既定85%閾値と判定される(70%はまだ超過しない)" {
    make_transcript "$TMPDIR_TEST/t7.jsonl" 140000 "claude-haiku-4-5"   # 200,000のうち140002 tokens = 70%
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-7 "$TMPDIR_TEST/t7.jsonl")"
    [ "$output" = "" ]
}

@test "8. CLAUDE_COMPACT_WARN_THRESHOLDが非数値 → 自動判定閾値にフォールバックしfail-open" {
    make_transcript "$TMPDIR_TEST/t8.jsonl" 1000   # モデル無指定・200000窓のうち1002 tokens ≈ 0%(既定85%未満)
    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=abc "$SCRIPT" <<< "$(json_input sess-8 "$TMPDIR_TEST/t8.jsonl")"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "9. CLAUDE_CONTEXT_WINDOW_TOKENSが非数値 → 自動判定ウィンドウにフォールバックしfail-open" {
    make_transcript "$TMPDIR_TEST/t9.jsonl" 180000 "claude-haiku-4-5"   # 200,000のうち180002 tokens = 90% → haiku既定85%超過
    run --separate-stderr env CLAUDE_CONTEXT_WINDOW_TOKENS=notanumber "$SCRIPT" <<< "$(json_input sess-9 "$TMPDIR_TEST/t9.jsonl")"
    [ "$status" -eq 0 ]
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-9" ]
}

@test "10. CLAUDE_CONTEXT_WINDOW_TOKENS=0 → ゼロ除算を回避し自動判定窓にフォールバックする" {
    make_transcript "$TMPDIR_TEST/t10.jsonl" 180000   # モデル無指定 → 既定200000窓のうち180002 tokens ≈ 90%(既定85%超過)
    run --separate-stderr env CLAUDE_CONTEXT_WINDOW_TOKENS=0 "$SCRIPT" <<< "$(json_input sess-10 "$TMPDIR_TEST/t10.jsonl")"
    [ "$status" -eq 0 ]
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-10" ]
    [ "$(warn_marker_of sess-10)" = "90" ]
}

@test "11. CLAUDE_COMPACT_WARN_THRESHOLD=089(先頭ゼロ) → 自動判定閾値にフォールバックしstderrノイズ無し" {
    make_transcript "$TMPDIR_TEST/t11.jsonl" 1000   # モデル無指定 → 200000窓のうち1002 tokens ≈ 0%(既定85%未満)
    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=089 "$SCRIPT" <<< "$(json_input sess-11 "$TMPDIR_TEST/t11.jsonl")"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$stderr" = "" ]
}

@test "12. session_idにパストラバーサル文字列 → 空stdout・exit 0・cooldown marker dir外に副作用なし" {
    make_transcript "$TMPDIR_TEST/t12.jsonl" 180000   # 200000のうち180002 tokens ≈ 90%(本来なら閾値超過するケース)
    run --separate-stderr "$SCRIPT" <<< "$(json_input '../evil' "$TMPDIR_TEST/t12.jsonl")"
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
    [ ! -f "$TMPDIR_TEST/evil" ]

    run --separate-stderr "$SCRIPT" <<< "$(json_input 'a/b' "$TMPDIR_TEST/t12.jsonl")"
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
}

@test "13. claude-opus-5(サフィックス無し) → 200K窓・既定85%閾値と判定される" {
    make_transcript "$TMPDIR_TEST/t13.jsonl" 140000 "claude-opus-5"   # 200,000のうち140002 tokens = 70% → 85%未満
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-13 "$TMPDIR_TEST/t13.jsonl")"
    [ "$output" = "" ]

    make_transcript "$TMPDIR_TEST/t13b.jsonl" 180000 "claude-opus-5"   # 200,000のうち180002 tokens = 90% → 85%超過
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-13b "$TMPDIR_TEST/t13b.jsonl")"
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-13b" ]
}

@test "14. マーカーがtranscriptのモデル名テーブルより優先される(モデル一致)" {
    # テーブルなら200K窓で90% → 警告。マーカー1Mかつモデル一致なら18% → 警告なし
    make_transcript "$TMPDIR_TEST/t14.jsonl" 180000 "claude-opus-5"
    make_window_marker sess-14 1000000 "claude-opus-5[1m]"
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-14 "$TMPDIR_TEST/t14.jsonl")"
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-14" ]

    # 「警告が作られない」だけでなく、閾値を極端に下げて実際に1M窓(PCT=18)が
    # 使われたことを直接主張する。
    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=1 "$SCRIPT" <<< "$(json_input sess-14 "$TMPDIR_TEST/t14.jsonl")"
    [ "$(warn_marker_of sess-14)" = "18" ]
}

@test "マーカーのモデル名がtranscriptと食い違う → マーカー破棄しテーブルに落ちる" {
    # 1Mセッション開始時にSessionStartが書いたマーカー(claude-opus-5[1m])が、/model による
    # 200Kモデル(claude-haiku-4-5)への切替後もそのまま残っている状況を再現する。
    make_transcript "$TMPDIR_TEST/t_mismatch.jsonl" 180000 "claude-haiku-4-5"
    make_window_marker sess-mismatch 1000000 "claude-opus-5[1m]"
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-mismatch "$TMPDIR_TEST/t_mismatch.jsonl")"
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-mismatch" ]
    [ "$(warn_marker_of sess-mismatch)" = "90" ]
}

@test "モデル名を伴わない旧形式マーカーは無効として扱う(退行再現)" {
    # 旧sessionstart(修正前)が書いていた「窓幅のみ」の1行マーカーがそのまま残っているケース。
    # 旧形式を信用すると/model切替後も古い窓幅が勝ち続け、警告が出ない退行がそのまま残る。
    make_transcript "$TMPDIR_TEST/t_oldfmt.jsonl" 180000 "claude-haiku-4-5"
    mkdir -p "$TMPDIR_TEST/claude-context-window"
    printf '1000000\n' > "$TMPDIR_TEST/claude-context-window/sess-oldfmt"
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-oldfmt "$TMPDIR_TEST/t_oldfmt.jsonl")"
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-oldfmt" ]
}

@test "15. 環境変数はマーカーより優先される" {
    make_transcript "$TMPDIR_TEST/t15.jsonl" 180000 "claude-opus-5"
    make_window_marker sess-15 1000000 "claude-opus-5[1m]"
    run --separate-stderr env CLAUDE_CONTEXT_WINDOW_TOKENS=200000 "$SCRIPT" <<< "$(json_input sess-15 "$TMPDIR_TEST/t15.jsonl")"
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-15" ]
    [ "$(warn_marker_of sess-15)" = "90" ]
}

@test "16. マーカーの窓幅が不正なら transcript のテーブルに落ちる" {
    for bad in "notanumber" "0" "0100"; do
        sid="sess-16-$bad"
        tr="$TMPDIR_TEST/t16-$bad.jsonl"
        make_transcript "$tr" 180000 "claude-opus-5"   # テーブルなら200K窓で90% → 警告
        make_window_marker "$sid" "$bad" "claude-opus-5[1m]"
        run --separate-stderr "$SCRIPT" <<< "$(json_input "$sid" "$tr")"
        [ "$status" -eq 0 ] || { echo "exit 0 を期待したが [$status] / 入力: $bad" >&2; return 1; }
        [ -f "$TMPDIR_TEST/claude-compact-warn/$sid" ] || { echo "warn marker作成を期待したが無かった / 入力: $bad" >&2; return 1; }
        [ "$stderr" = "" ] || { echo "stderrノイズ無しを期待したが [$stderr] / 入力: $bad" >&2; return 1; }
    done
}

@test "17. マーカーが無ければ従来どおりtranscriptのテーブルに落ちる" {
    make_transcript "$TMPDIR_TEST/t17.jsonl" 700000 "claude-sonnet-5"   # テーブルで1M窓 → 70%で60%閾値超過
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-17 "$TMPDIR_TEST/t17.jsonl")"
    [ -f "$TMPDIR_TEST/claude-compact-warn/sess-17" ]
}

@test "18. 使用量が窓幅を超えたら保険で1Mとして扱う" {
    make_transcript "$TMPDIR_TEST/t18.jsonl" 300000 "claude-opus-5"   # テーブルは200K窓。300002 tokensは窓を超えている
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-18 "$TMPDIR_TEST/t18.jsonl")"
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-18" ]

    # 閾値を1に下げて再実行し、warn markerの中身が30(=1M窓分母で計算された値)であることを
    # 直接主張する。
    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=1 "$SCRIPT" <<< "$(json_input sess-18 "$TMPDIR_TEST/t18.jsonl")"
    [ "$(warn_marker_of sess-18)" = "30" ]
}

@test "マーカー由来の窓幅を使用量が超えたら保険で1Mとなる(マーカーと保険の組み合わせ)" {
    # マーカー(200K, モデル一致)を使用量300002が超えている
    make_transcript "$TMPDIR_TEST/t_marker_ins.jsonl" 300000 "claude-opus-5"
    make_window_marker sess-marker-ins 200000 "claude-opus-5"
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-marker-ins "$TMPDIR_TEST/t_marker_ins.jsonl")"
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-marker-ins" ]
}

@test "19. 保険は環境変数による手動指定にも適用される" {
    make_transcript "$TMPDIR_TEST/t19.jsonl" 300000 "claude-opus-5"
    run --separate-stderr env CLAUDE_CONTEXT_WINDOW_TOKENS=200000 "$SCRIPT" <<< "$(json_input sess-19 "$TMPDIR_TEST/t19.jsonl")"
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-19" ]

    # 閾値を1に下げて再実行し、warn markerの中身が30(環境変数200Kでも保険で1M窓が使われた
    # 直接証拠)であることを主張する。
    run --separate-stderr env CLAUDE_CONTEXT_WINDOW_TOKENS=200000 CLAUDE_COMPACT_WARN_THRESHOLD=1 \
        "$SCRIPT" <<< "$(json_input sess-19 "$TMPDIR_TEST/t19.jsonl")"
    [ "$(warn_marker_of sess-19)" = "30" ]
}

@test "20. SessionStartマーカーが無くstatusLineマーカーがあるとき → statusLineマーカーの窓幅が使われる" {
    # テーブルなら200K窓で90% → 警告。statusLineマーカー1Mなら18% → 警告なし
    make_transcript "$TMPDIR_TEST/t20.jsonl" 180000 "claude-opus-5"
    make_status_marker sess-20 1000000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-20 "$TMPDIR_TEST/t20.jsonl")"
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-20" ]

    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=1 "$SCRIPT" <<< "$(json_input sess-20 "$TMPDIR_TEST/t20.jsonl")"
    [ "$(warn_marker_of sess-20)" = "18" ]
}

@test "21. SessionStartマーカーとstatusLineマーカーが両方あるとき → statusLineマーカー(実測値)が優先される" {
    make_transcript "$TMPDIR_TEST/t21.jsonl" 180000 "claude-opus-5"
    make_window_marker sess-21 200000 "claude-opus-5"   # SessionStartマーカー: 200K(モデル一致、テーブル由来の推測値)
    make_status_marker sess-21 1000000                  # statusLineマーカー: 1M(実測値)
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-21 "$TMPDIR_TEST/t21.jsonl")"
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-21" ]

    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=1 "$SCRIPT" <<< "$(json_input sess-21 "$TMPDIR_TEST/t21.jsonl")"
    [ "$(warn_marker_of sess-21)" = "18" ]
}

@test "22. statusLineマーカーの値が不正(SessionStartマーカー無し) → テーブルに落ちる" {
    for bad in "notanumber" "0" "0100"; do
        sid="sess-22-$bad"
        tr="$TMPDIR_TEST/t22-$bad.jsonl"
        make_transcript "$tr" 180000 "claude-opus-5"   # テーブルなら200K窓で90% → 警告
        make_status_marker "$sid" "$bad"
        run --separate-stderr "$SCRIPT" <<< "$(json_input "$sid" "$tr")"
        [ -f "$TMPDIR_TEST/claude-compact-warn/$sid" ] || { echo "warn marker作成を期待したが無かった / 入力: $bad" >&2; return 1; }
    done
}

@test "23. statusLineマーカーが有効ならSessionStartマーカーの有効性に関わらず優先される" {
    # SessionStartマーカーはモデル不一致で無効になる。statusLineマーカーの値をテーブル
    # デフォルト(haiku-4-5=200K)とは異なる1Mにして、実際にstatusLineマーカーが読まれた
    # ことをテーブルへの取りこぼしと区別できるようにする。
    make_transcript "$TMPDIR_TEST/t23.jsonl" 180000 "claude-haiku-4-5"
    make_window_marker sess-23 1000000 "claude-opus-5[1m]"
    make_status_marker sess-23 1000000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-23 "$TMPDIR_TEST/t23.jsonl")"
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-23" ]

    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=1 "$SCRIPT" <<< "$(json_input sess-23 "$TMPDIR_TEST/t23.jsonl")"
    [ "$(warn_marker_of sess-23)" = "18" ]
}

@test "24. statusLineマーカーが不正でSessionStartマーカーが有効なとき → SessionStartマーカーへフォールバックする" {
    make_transcript "$TMPDIR_TEST/t24.jsonl" 180000 "claude-opus-5"        # テーブルなら200K窓で90% → 警告
    make_status_marker sess-24 "notanumber"             # statusLineマーカー: 不正値
    make_window_marker sess-24 1000000 "claude-opus-5"  # SessionStartマーカー: 1M(モデル一致)
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-24 "$TMPDIR_TEST/t24.jsonl")"
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-24" ]
}

@test "libのsourceに失敗した場合はfail-open(exit 0, 空stdout)" {
    NOLIB_DIR="$(mktemp -d)"
    cp "$SCRIPT" "$NOLIB_DIR/"
    run --separate-stderr bash "$NOLIB_DIR/$(basename "$SCRIPT")" <<< '{"session_id":"sess-nolib","transcript_path":"/no/such/file"}'
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
}
