#!/usr/bin/env bats
# chat-context-guard.sh のユニットテスト。statusline のマーカーと loop-guard.sh の予約の印を、検証用の TMPDIR に置いて読ませる。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_chat-context-guard.sh"
    LOOP_GUARD="$BATS_TEST_DIRNAME/executable_loop-guard.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    export XDG_STATE_HOME="$TMPDIR_TEST/state"
    LOG="$XDG_STATE_HOME/claude-chat-context-guard/decisions.log"
    export HERDR_ENV=1
    for v in STATE_TOKENS STATE_PCT HANDOFF_TOKENS HANDOFF_PCT CHAT_HANDOFF_PCT CHAT_URGENT_PCT; do unset "CONTEXT_GUARD_$v"; done
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

# ctx <使用率> [<窓の大きさ>]。窓の既定は 1000000
ctx() {
    mkdir -p "$TMPDIR/claude-status-context-usage" "$TMPDIR/claude-status-context-window"
    echo "$1" > "$TMPDIR/claude-status-context-usage/sess"
    echo "${2:-1000000}" > "$TMPDIR/claude-status-context-window/sess"
}

prompt() {
    run bash "$SCRIPT" <<< "$(jq -nc --arg p "$1" '{session_id: "sess", hook_event_name: "UserPromptSubmit", prompt: $p}')"
}

context_of() { jq -r '.hookSpecificOutput.additionalContext // empty' <<< "$output"; }

@test "40% -> いまの依頼をキリの良いところまで進めてから session-handoff で移らせる。一度だけ" {
    ctx 40
    prompt "ふつうの依頼"
    [[ "$(context_of)" == "[chat-context-guard] "*"キリの良いところ"*"session-handoff"* ]]
    prompt "次"
    [ -z "$output" ]
    grep -q "notice:handoff" "$LOG"
}
@test "60% -> 依頼に入る前に session-handoff で移らせる。一度だけ" {
    ctx 60
    prompt "a"
    [[ "$(context_of)" == *"入る前に"*"session-handoff"* ]]
    prompt "b"
    [ -z "$output" ]
    grep -q "notice:urgent" "$LOG"
}
@test "40% の知らせのあとに 60% を越えたら、60% も一度出す" { ctx 40; prompt a; ctx 60; prompt b; [[ "$(context_of)" == *"入る前に"* ]]; }
@test "1M の窓で 30% は対話では何も出さない" { ctx 30 1000000; prompt a; [ -z "$output" ]; }
@test "40% を下回ったら、次に越えたときにまた知らせる" { ctx 40; prompt a; ctx 10; prompt b; ctx 41; prompt c; [[ "$(context_of)" == *"session-handoff"* ]]; }
@test "Herdr の外では 40% の閾値として /clear を勧める" {
    unset HERDR_ENV
    ctx 40
    prompt a
    [[ "$(context_of)" == *"40% の閾値"*"/clear"* ]]
    [[ "$(context_of)" != *"session-handoff"* ]]
}
@test "Herdr の外では 60% の閾値として依頼に入る前に /clear を勧める" {
    unset HERDR_ENV
    ctx 60
    prompt a
    [[ "$(context_of)" == *"60% の閾値"*"この依頼に入る前に"*"/clear"* ]]
    [[ "$(context_of)" != *"session-handoff"* ]]
}
@test "閾値は環境変数で差し替えられる" { export CONTEXT_GUARD_CHAT_HANDOFF_PCT=20; ctx 21; prompt a; [[ "$(context_of)" == *"session-handoff"* ]]; }

@test "200K の窓では使用率で判定する" {
    ctx 50 200000
    prompt "a"
    [[ "$(context_of)" == *"キリの良いところ"*"session-handoff"* ]]
}

@test "閾値の下か、使用率が測れない -> 黙る" {
    ctx 10
    prompt "a"
    [ -z "$output" ]
    rm -f "$TMPDIR/claude-status-context-usage/sess"
    prompt "b"
    [ -z "$output" ]
}

@test "/loop で始まる prompt には知らせを出さない" {
    ctx 45
    prompt "/loop check ci"
    [ -z "$output" ]
    prompt "  /loop"
    [ -z "$output" ]
    prompt "/loopy は別のコマンド"
    [[ "$(context_of)" == *"session-handoff"* ]]
}

@test "loop-guard.sh が予約を通したセッションでは、手打ちの prompt にも知らせを出さない" {
    run bash "$LOOP_GUARD" <<< '{"session_id":"sess","hook_event_name":"PreToolUse","tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":1800,"prompt":"/loop w"}}'
    ctx 45
    prompt "ループの合間の質問"
    [ -z "$output" ]
}

@test "サブエージェントの入力、不正な session_id -> 何もしない" {
    ctx 45
    run bash "$SCRIPT" <<< '{"session_id":"sess","agent_id":"a1","hook_event_name":"UserPromptSubmit","prompt":"x"}'
    [ -z "$output" ]
    run bash "$SCRIPT" <<< '{"session_id":"../x","hook_event_name":"UserPromptSubmit","prompt":"x"}'
    [ -z "$output" ]
}
