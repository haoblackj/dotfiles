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
    for v in STATE_TOKENS STATE_PCT HANDOFF_TOKENS HANDOFF_PCT; do unset "CONTEXT_GUARD_$v"; done
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

@test "一段目 -> 依頼のあとに /clear を勧めさせる。一度だけ" {
    ctx 32
    prompt "ふつうの依頼"
    [ "$status" -eq 0 ]
    [[ "$(context_of)" == "[chat-context-guard] "*"一段目"*"片付けたら"*"/clear"* ]]
    prompt "次の依頼"
    [ -z "$output" ]
    grep -q "notice:state" "$LOG"
}

@test "二段目 -> 依頼の前に状態を書き出し、/clear を勧めて止まらせる。一度だけ" {
    ctx 45
    prompt "ふつうの依頼"
    [[ "$(context_of)" == *"二段目"*"入る前に"*"/clear"* ]]
    prompt "このまま続けて"
    [ -z "$output" ]
}

@test "一段目の知らせのあとに二段目を越えたら、二段目も一度出す" {
    ctx 32
    prompt "a"
    ctx 45
    prompt "b"
    [[ "$(context_of)" == *"二段目"* ]]
}

@test "一段目を下回ったら、次に越えたときにまた知らせる" {
    ctx 32
    prompt "a"
    ctx 5
    prompt "b"
    [ -z "$output" ]
    ctx 32
    prompt "c"
    [[ "$(context_of)" == *"一段目"* ]]
}

@test "200K の窓では使用率で判定する" {
    ctx 50 200000
    prompt "a"
    [[ "$(context_of)" == *"一段目"* ]]
}

@test "閾値は環境変数で差し替えられる" {
    ctx 32
    CONTEXT_GUARD_STATE_TOKENS=350000 prompt "a"
    [ -z "$output" ]
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
    [[ "$(context_of)" == *"二段目"* ]]
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
