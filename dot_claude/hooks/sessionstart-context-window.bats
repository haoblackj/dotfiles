#!/usr/bin/env bats
# sessionstart-context-window.sh のユニットテスト。
set -u

marker_of() { # session_id
    cat "$TMPDIR_TEST/claude-context-window/$1" 2>/dev/null || echo ''
}

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_sessionstart-context-window.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

@test "[1m]サフィックス付き -> 1,000,000がマーカーに書かれる" {
    run "$SCRIPT" <<< '{"session_id":"sess-1","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5[1m]"}'
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
    [ "$(marker_of sess-1)" = "1000000 claude-opus-5[1m]" ]
}

@test "サフィックス無しの既知モデル -> 世代テーブルの値が書かれる" {
    "$SCRIPT" <<< '{"session_id":"sess-2","model":"claude-opus-5"}' >/dev/null
    [ "$(marker_of sess-2)" = "200000 claude-opus-5" ]

    "$SCRIPT" <<< '{"session_id":"sess-2b","model":"claude-sonnet-5"}' >/dev/null
    [ "$(marker_of sess-2b)" = "1000000 claude-sonnet-5" ]

    "$SCRIPT" <<< '{"session_id":"sess-2c","model":"claude-haiku-4-5"}' >/dev/null
    [ "$(marker_of sess-2c)" = "200000 claude-haiku-4-5" ]
}

@test "modelフィールド欠落 -> マーカーを作らずexit 0" {
    run "$SCRIPT" <<< '{"session_id":"sess-3","hook_event_name":"SessionStart"}'
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
    [ ! -f "$TMPDIR_TEST/claude-context-window/sess-3" ]
}

@test "modelがobject形式でも.model.idを拾う" {
    "$SCRIPT" <<< '{"session_id":"sess-4","model":{"id":"claude-opus-5[1m]","display_name":"Opus 5"}}' >/dev/null
    [ "$(marker_of sess-4)" = "1000000 claude-opus-5[1m]" ]
}

@test "session_idにパストラバーサル文字列 -> マーカーdir外に副作用なし" {
    run "$SCRIPT" <<< '{"session_id":"../evil","model":"claude-opus-5[1m]"}'
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
    [ ! -f "$TMPDIR_TEST/evil" ]

    run "$SCRIPT" <<< '{"session_id":"a/b","model":"claude-opus-5[1m]"}'
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
    [ ! -e "$TMPDIR_TEST/claude-context-window/a" ]
}

@test "壊れたJSON -> クラッシュせずexit 0" {
    run "$SCRIPT" <<< 'not json at all'
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
}

@test "libのsourceに失敗した場合はfail-open(exit 0, 空stdout)" {
    NOLIB_DIR="$(mktemp -d)"
    cp "$SCRIPT" "$NOLIB_DIR/"
    run bash "$NOLIB_DIR/$(basename "$SCRIPT")" <<< '{"session_id":"sess-nolib","model":"claude-opus-5"}'
    rm -rf -- "$NOLIB_DIR"
    [ "$output" = "" ]
    [ "$status" -eq 0 ]
}
