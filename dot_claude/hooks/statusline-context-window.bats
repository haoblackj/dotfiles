#!/usr/bin/env bats
# statusline-context-window.sh のユニットテスト。
set -u

marker_of() { # session_id
    cat "$TMPDIR_TEST/claude-status-context-window/$1" 2>/dev/null || echo ''
}

usage_marker_of() { # session_id
    cat "$TMPDIR_TEST/claude-status-context-usage/$1" 2>/dev/null || echo ''
}

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_statusline-context-window.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"

    # ccstatusline をモックする。実際のバイナリを叩かず、stdinをそのままstdoutへ通すだけ。
    # setup()でPATHを組み立て、各@testはこれを継承する。
    FAKE_BIN="$TMPDIR_TEST/fakebin"
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/ccstatusline" <<'EOS'
#!/bin/bash
cat
EOS
    chmod +x "$FAKE_BIN/ccstatusline"
    export PATH="$FAKE_BIN:$PATH"
    unset HERDR_ENV HERDR_TAB_ID HERDR_PANE_ID
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

@test "session_idとcontext_window_sizeが揃った入力 -> マーカーに窓幅、stdoutは元のJSONがそのまま通る" {
    input='{"session_id":"sess-1","context_window":{"context_window_size":1000000}}'
    run bash "$SCRIPT" <<< "$input"
    [ "$(marker_of sess-1)" = "1000000" ]
    [ "$output" = "$input" ]
    [ "$status" -eq 0 ]
}

@test "used_percentageがnull(/compact直後) -> 既存の使用率マーカーを消す。窓幅マーカーは残す" {
    # 2026-09-12 実測: 25% → /compact → null → 次のAPI呼び出しで 7%。
    # null の間に古い 25 が残ると、圧縮直後に圧縮前の値で警告する退行が再発する。
    input='{"session_id":"sess-n","context_window":{"context_window_size":1000000,"used_percentage":25}}'
    bash "$SCRIPT" <<< "$input" >/dev/null
    [ "$(usage_marker_of sess-n)" = "25" ]

    input='{"session_id":"sess-n","context_window":{"context_window_size":1000000,"used_percentage":null,"current_usage":null}}'
    bash "$SCRIPT" <<< "$input" >/dev/null
    [ ! -f "$TMPDIR_TEST/claude-status-context-usage/sess-n" ]
    [ "$(marker_of sess-n)" = "1000000" ]
}

rate_of() { # session_id
    cat "$TMPDIR_TEST/claude-status-rate-limits/$1" 2>/dev/null || echo ''
}

@test "rate_limits の両方の枠 -> 枠ごとに used と resetsAt と changedAt" {
    input='{"session_id":"rl-1","rate_limits":{"five_hour":{"used_percentage":38.5,"resets_at":1790170000},"seven_day":{"used_percentage":19,"resets_at":1790700000}}}'
    run bash "$SCRIPT" <<< "$input"
    [ "$status" -eq 0 ]
    [ "$output" = "$input" ]
    [ "$(rate_of rl-1 | jq -c 'del(.fiveHour.changedAt, .sevenDay.changedAt)')" = '{"fiveHour":{"used":38.5,"resetsAt":1790170000},"sevenDay":{"used":19,"resetsAt":1790700000}}' ]
    [[ "$(rate_of rl-1 | jq -r '.fiveHour.changedAt')" =~ ^[0-9]+$ ]]
    [[ "$(rate_of rl-1 | jq -r '.sevenDay.changedAt')" =~ ^[0-9]+$ ]]
}

