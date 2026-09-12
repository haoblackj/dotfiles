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

@test "context_window_sizeがnull -> マーカー未作成、fail-open" {
    input='{"session_id":"sess-2","context_window":{"context_window_size":null}}'
    run bash "$SCRIPT" <<< "$input"
    [ "$(marker_of sess-2)" = "" ]
    [ "$output" = "$input" ]
    [ "$status" -eq 0 ]
}

@test "context_windowキー自体が無い -> マーカー未作成、fail-open" {
    input='{"session_id":"sess-3"}'
    run bash "$SCRIPT" <<< "$input"
    [ "$(marker_of sess-3)" = "" ]
    [ "$status" -eq 0 ]
}

@test "session_idにパストラバーサル文字列 -> マーカーdir外に副作用なし" {
    input='{"session_id":"../evil","context_window":{"context_window_size":1000000}}'
    run bash "$SCRIPT" <<< "$input"
    [ ! -f "$TMPDIR_TEST/evil" ]
    [ "$status" -eq 0 ]
}

@test "context_window_sizeが0や不正値 -> マーカー未作成" {
    # sidをbadから独立させる。"notanumber"(引用符付き)を直接sidに埋め込むと
    # session_id自体が正規表現に落ちてしまい、window_sizeの検証経路を実際には通らないまま
    # アサーションだけ通ってしまう(意図した経路を検証できていない)ため。
    i=0
    for bad in "0" '"notanumber"' "-5"; do
        i=$((i + 1))
        sid="sess-5-$i"
        input="{\"session_id\":\"$sid\",\"context_window\":{\"context_window_size\":$bad}}"
        bash "$SCRIPT" <<< "$input" >/dev/null
        [ "$(marker_of "$sid")" = "" ]
    done
}

@test "壊れたJSON -> クラッシュせずexit 0、stdoutにそのまま通る(ccstatusline側の責務)" {
    run bash "$SCRIPT" <<< 'not json at all'
    [ "$(marker_of 'sess-broken')" = "" ]
    [ "$status" -eq 0 ]
    [ "$output" = "not json at all" ]
}

@test "used_percentageが数値 -> 使用率マーカーにそのまま書く(整数・小数・0)" {
    for pct in 25 62.8 0; do
        input="{\"session_id\":\"sess-u-$pct\",\"context_window\":{\"context_window_size\":1000000,\"used_percentage\":$pct}}"
        bash "$SCRIPT" <<< "$input" >/dev/null
        [ "$(usage_marker_of "sess-u-$pct")" = "$pct" ]
    done
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

@test "used_percentageキー自体が無い -> 使用率マーカー未作成、窓幅マーカーは作る" {
    input='{"session_id":"sess-nokey","context_window":{"context_window_size":200000}}'
    bash "$SCRIPT" <<< "$input" >/dev/null
    [ ! -f "$TMPDIR_TEST/claude-status-context-usage/sess-nokey" ]
    [ "$(marker_of sess-nokey)" = "200000" ]
}

@test "used_percentageが非数値 -> 使用率マーカーを作らない" {
    for bad in '"abc"' '-3' 'true'; do
        input="{\"session_id\":\"sess-ubad\",\"context_window\":{\"context_window_size\":200000,\"used_percentage\":$bad}}"
        bash "$SCRIPT" <<< "$input" >/dev/null
        [ ! -f "$TMPDIR_TEST/claude-status-context-usage/sess-ubad" ]
    done
}
