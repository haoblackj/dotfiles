#!/usr/bin/env bats
# chat-context-guard.sh のユニットテスト。statusline のマーカーと loop-guard.sh の予約の印を、検証用の TMPDIR に置いて読ませる。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_chat-context-guard.sh"
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

@test "40% -> 自分からは引き継がず、応答の最後に大きさを一文で知らせる。移る勧めは足させない。一度だけ" {
    ctx 40
    prompt "ふつうの依頼"
    [[ "$(context_of)" == "[chat-context-guard] "*"自分からは引き継がず"*"応答の最後"*"一文で知らせる"*"勧める文は足さない"* ]]
    [[ "$(context_of)" != *"「移って」"* ]]
    [[ "$(context_of)" != *"と添える"* ]]
    prompt "次"
    [ -z "$output" ]
    grep -q "notice:handoff" "$LOG"
}
@test "60% -> 予備の閾値として、もう一度知らせるだけ。依頼に入る前に移らせない。一度だけ" {
    ctx 60
    prompt "a"
    [[ "$(context_of)" == *"予備の閾値"*"自分からは引き継がず"*"勧める文は足さない"* ]]
    [[ "$(context_of)" != *"入る前に"* ]]
    prompt "b"
    [ -z "$output" ]
    grep -q "notice:urgent" "$LOG"
}

