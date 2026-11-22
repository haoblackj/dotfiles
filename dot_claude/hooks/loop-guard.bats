#!/usr/bin/env bats
# loop-guard.sh のユニットテスト。usage-route.sh と statusline の状態ファイルを、検証用の TMPDIR に置いて読ませる。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_loop-guard.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    export XDG_STATE_HOME="$TMPDIR_TEST/state"
    LOG="$XDG_STATE_HOME/claude-loop-guard/decisions.log"
    unset LOOP_GUARD_TIGHT_MIN_SECONDS; for v in STATE_TOKENS STATE_PCT HANDOFF_TOKENS HANDOFF_PCT; do unset "CONTEXT_GUARD_$v"; done
    # 繰り返しの CronCreate は既定で止める。その判定は「固定間隔のループ」の節で見る。
    # ほかのテストでは、許したときの判定（stop）を確かめるため許しておく
    export LOOP_GUARD_ALLOW_RECURRING_CRON=1
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

route() { mkdir -p "$TMPDIR/claude-usage-route" && echo "$1" > "$TMPDIR/claude-usage-route/sess"; }

wakeup() {
    run bash "$SCRIPT" <<< "$(jq -nc --argjson d "${1:-1800}" --arg p "${2:-/loop check}" \
        '{session_id: "sess", hook_event_name: "PreToolUse", tool_name: "ScheduleWakeup",
          tool_input: {delaySeconds: $d, prompt: $p, reason: "r"}}')"
}

cron() {
    run bash "$SCRIPT" <<< "$(jq -nc --arg c "$1" --arg p "${2:-/loop poll}" --argjson r "${3:-true}" \
        '{session_id: "sess", hook_event_name: "PreToolUse", tool_name: "CronCreate",
          tool_input: {cron: $c, prompt: $p, recurring: $r}}')"
}

decision() { jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$output"; }
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "$output"; }

# --- 固定間隔のループ（既定で止める） ---

@test "既定では繰り返しの CronCreate をどの状態でも deny し、自己ペースを勧める" {
    unset LOOP_GUARD_ALLOW_RECURRING_CRON
    cron "7 * * * *"
    [ "$(decision)" = deny ]
    [[ "$(reason)" == *"自己ペース"* ]]
    [[ "$(cat "$LOG")" == *$'\tdeny:cron\t'* ]]
    route normal
    cron "*/20 * * * *"
    [ "$(decision)" = deny ]
}

# --- 利用枠 stop ---

@test "stop -> ScheduleWakeup を deny し、止め方を返す" {
    route stop
    wakeup 1800
    [ "$(decision)" = deny ]
    [[ "$(reason)" == "[loop-guard] "*"stop: true"*"CronDelete"* ]]
    [[ "$(cat "$LOG")" == *$'\tdeny:stop\tstop\t'* ]]
}

