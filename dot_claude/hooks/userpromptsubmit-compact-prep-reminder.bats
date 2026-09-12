#!/usr/bin/env bats
# userpromptsubmit-compact-prep-reminder.sh のユニットテスト。
# 使用率と窓幅は statusline-context-window.sh が書くマーカーだけから読む。
bats_require_minimum_version 1.5.0
set -u

json_input() { # session_id -> JSON (stdout)
    printf '{"session_id":"%s"}' "$1"
}

make_usage_marker() { # session_id used_percentage
    mkdir -p "$TMPDIR_TEST/claude-status-context-usage"
    printf '%s\n' "$2" > "$TMPDIR_TEST/claude-status-context-usage/$1"
}

make_window_marker() { # session_id window
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

@test "1. 200K窓・既定85%閾値: 閾値未満なら何も出力しない" {
    make_usage_marker sess-1 50
    make_window_marker sess-1 200000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-1)"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-1" ]
}

@test "2+3. 閾値超過でwarn markerを作成し、cooldown中は再度作成しない(順序依存)" {
    make_usage_marker sess-2 90
    make_window_marker sess-2 200000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-2)"
    [ "$output" = "" ]
    [ "$(warn_marker_of sess-2)" = "90" ]

    # cooldown: compact-plus プラグインの reminder hook が書いた warned marker を模す。
    # ケース3はケース2が作った sess-2 の warn marker を rm してから読み直すため、
    # この対は1つの @test に留めて順序を保証する。
    mkdir -p "$TMPDIR_TEST/claude-compact-warned"
    touch "$TMPDIR_TEST/claude-compact-warned/sess-2"
    rm -f "$TMPDIR_TEST/claude-compact-warn/sess-2"
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-2)"
    [ "$output" = "" ]
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-2" ]
}

@test "4. CLAUDE_COMPACT_WARN_THRESHOLDで閾値を変更できる" {
    make_usage_marker sess-3 5
    make_window_marker sess-3 200000
    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=3 "$SCRIPT" <<< "$(json_input sess-3)"
    [ "$(warn_marker_of sess-3)" = "5" ]
}

@test "5. 使用率マーカーが無い(最初のAPI呼び出し前・/compact直後・statusLine未実行) → 黙ってexit 0" {
    make_window_marker sess-4 1000000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-4)"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$stderr" = "" ]
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-4" ]
}

@test "6. 1M窓 → 既定60%閾値(70%は超過扱いになる)" {
    make_usage_marker sess-6 70
    make_window_marker sess-6 1000000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-6)"
    [ "$(warn_marker_of sess-6)" = "70" ]
}

@test "7. 200K窓 → 既定85%閾値(70%はまだ超過しない)" {
    make_usage_marker sess-7 70
    make_window_marker sess-7 200000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-7)"
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-7" ]
}

@test "8. 小数の使用率(62.8)は整数部で判定し、warn markerにも整数で書く" {
    make_usage_marker sess-8 62.8
    make_window_marker sess-8 1000000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-8)"
    [ "$(warn_marker_of sess-8)" = "62" ]
}

@test "9. 窓幅マーカーが無い → 閾値を推測せず黙ってexit 0" {
    make_usage_marker sess-9 90
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-9)"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-9" ]
}

@test "10. 使用率マーカーが非数値 → 黙ってexit 0、warn markerを作らない" {
    make_usage_marker sess-10 'null'
    make_window_marker sess-10 1000000
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-10)"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-10" ]
}

@test "11. CLAUDE_COMPACT_WARN_THRESHOLD=089(先頭ゼロ) → 自動判定閾値にフォールバックしstderrノイズ無し" {
    make_usage_marker sess-11 1
    make_window_marker sess-11 200000
    run --separate-stderr env CLAUDE_COMPACT_WARN_THRESHOLD=089 "$SCRIPT" <<< "$(json_input sess-11)"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$stderr" = "" ]
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-11" ]
}

@test "12. session_idにパストラバーサル文字列 → 空stdout・exit 0・marker dir外に副作用なし" {
    run --separate-stderr "$SCRIPT" <<< "$(json_input '../evil')"
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
    [ ! -f "$TMPDIR_TEST/evil" ]

    run --separate-stderr "$SCRIPT" <<< "$(json_input 'a/b')"
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
}

@test "13. 圧縮前の古い値は使わない: 使用率マーカーが消えた(=/compact直後の)状態では警告しない(退行再現)" {
    # 2026-09-12 の実害: /compact 直後に transcript から圧縮前の 63% を拾って警告した。
    # 圧縮前に閾値超過の値があっても、statusLine が /compact 完了時にマーカーを消せば黙る。
    make_usage_marker sess-13 63
    make_window_marker sess-13 1000000
    rm -f "$TMPDIR_TEST/claude-status-context-usage/sess-13"
    run --separate-stderr "$SCRIPT" <<< "$(json_input sess-13)"
    [ "$status" -eq 0 ]
    [ ! -f "$TMPDIR_TEST/claude-compact-warn/sess-13" ]
}
