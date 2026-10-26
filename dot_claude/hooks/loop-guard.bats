#!/usr/bin/env bats
# loop-guard.sh のユニットテスト。usage-route.sh と statusline の状態ファイルを、検証用の TMPDIR に置いて読ませる。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_loop-guard.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    export XDG_STATE_HOME="$TMPDIR_TEST/state"
    LOG="$XDG_STATE_HOME/claude-loop-guard/decisions.log"
    for v in STATE_TOKENS STATE_PCT HANDOFF_TOKENS HANDOFF_PCT TIGHT_MIN_SECONDS; do unset "LOOP_GUARD_$v"; done
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

route() { mkdir -p "$TMPDIR/claude-usage-route" && echo "$1" > "$TMPDIR/claude-usage-route/sess"; }

# ctx <使用率> [<窓の大きさ>]。窓の既定は 1000000
ctx() {
    mkdir -p "$TMPDIR/claude-status-context-usage" "$TMPDIR/claude-status-context-window"
    echo "$1" > "$TMPDIR/claude-status-context-usage/sess"
    echo "${2:-1000000}" > "$TMPDIR/claude-status-context-window/sess"
}

wakeup() {
    run bash "$SCRIPT" <<< "$(jq -nc --argjson d "${1:-1800}" --arg p "${2:-/loop check}" \
        '{session_id: "sess", hook_event_name: "PreToolUse", tool_name: "ScheduleWakeup",
          tool_input: {delaySeconds: $d, prompt: $p, reason: "r"}}')"
}

wakeup_stop() {
    run bash "$SCRIPT" <<< '{"session_id":"sess","hook_event_name":"PreToolUse","tool_name":"ScheduleWakeup","tool_input":{"stop":true}}'
}

cron() {
    run bash "$SCRIPT" <<< "$(jq -nc --arg c "$1" --arg p "${2:-/loop poll}" --argjson r "${3:-true}" \
        '{session_id: "sess", hook_event_name: "PreToolUse", tool_name: "CronCreate",
          tool_input: {cron: $c, prompt: $p, recurring: $r}}')"
}

prompt() {
    run bash "$SCRIPT" <<< "$(jq -nc --arg p "$1" '{session_id: "sess", hook_event_name: "UserPromptSubmit", prompt: $p}')"
}

decision() { jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$output"; }
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "$output"; }
context_of() { jq -r '.hookSpecificOutput.additionalContext // empty' <<< "$output"; }

# --- 読めないときは通す ---

@test "状態ファイルもマーカーも無い -> 通す" {
    wakeup 60
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "session_id が不正 -> 何も出さない" {
    route stop
    run bash "$SCRIPT" <<< '{"session_id":"../x","hook_event_name":"PreToolUse","tool_name":"ScheduleWakeup","tool_input":{}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "サブエージェント内の呼び出し -> 何もしない" {
    route stop
    run bash "$SCRIPT" <<< '{"session_id":"sess","agent_id":"a1","hook_event_name":"PreToolUse","tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":60}}'
    [ -z "$output" ]
}

# --- 利用枠 stop ---

@test "stop -> ScheduleWakeup を deny し、止め方を返す" {
    route stop
    wakeup 1800
    [ "$(decision)" = deny ]
    [[ "$(reason)" == "[loop-guard] "*"stop: true"*"CronDelete"* ]]
    [[ "$(cat "$LOG")" == *$'\tdeny:stop\tstop\t'* ]]
}

@test "stop でも ScheduleWakeup の stop: true は通す" {
    route stop
    ctx 90
    wakeup_stop
    [ -z "$output" ]
}

@test "前の版の名前 stop-5h も stop として扱う" {
    route stop-5h
    wakeup 1800
    [ "$(decision)" = deny ]
}

@test "stop -> 繰り返しの CronCreate を deny、一度きりは通す" {
    route stop
    cron "7 * * * *"
    [ "$(decision)" = deny ]
    cron "30 14 28 2 *" "/remind" false
    [ -z "$output" ]
}

# --- 逼迫（offload、lean）の間隔の下限 ---

@test "offload で 1199 秒 -> deny、1200 秒 -> 通す" {
    route offload
    wakeup 1199
    [ "$(decision)" = deny ]
    [[ "$(reason)" == *"1200"* ]]
    wakeup 1200
    [ -z "$output" ]
}

@test "lean でも 600 秒は deny" {
    route lean
    wakeup 600
    [ "$(decision)" = deny ]
}

@test "normal なら 60 秒でも通す" {
    route normal
    wakeup 60
    [ -z "$output" ]
}

@test "offload で cron の間隔を判定する" {
    route offload
    cron "*/5 * * * *";  [ "$(decision)" = deny ]
    cron "*/10 * * * *"; [ "$(decision)" = deny ]
    cron "*/20 * * * *"; [ -z "$output" ]
    cron "7 * * * *";    [ -z "$output" ]
    cron "7,17 * * * *"; [ "$(decision)" = deny ]
    cron "0-40/20 * * * *"; [ -z "$output" ]
    cron "* * * * *";    [ "$(decision)" = deny ]
}

@test "offload で毎時の境目をまたぐ間隔も数える（50 分と 0 分は 10 分おき）" {
    route offload
    cron "0,50 * * * *"
    [ "$(decision)" = deny ]
    # 時が限られていれば境目はまたがない
    cron "0,50 9 * * *"
    [ -z "$output" ]
}

@test "offload で読めない cron は通す" {
    route offload
    cron "@hourly"
    [ -z "$output" ]
}

@test "下限は環境変数で差し替えられる" {
    route offload
    LOOP_GUARD_TIGHT_MIN_SECONDS=300 wakeup 400
    [ -z "$output" ]
}

# --- コンテキスト ---

@test "一段目（1M の窓で 30%）-> 一度だけ deny し、二度目は通す" {
    ctx 30
    wakeup 1800
    [ "$(decision)" = deny ]
    [[ "$(reason)" == *"約 300000 トークン"*"## 状態"* ]]
    wakeup 1800
    [ -z "$output" ]
}

@test "一段目を下回ったら、次に越えたときにまた一度 deny する" {
    ctx 30
    wakeup; [ "$(decision)" = deny ]
    wakeup; [ -z "$output" ]
    ctx 5
    wakeup; [ -z "$output" ]
    ctx 30
    wakeup; [ "$(decision)" = deny ]
}

@test "二段目（1M の窓で 40%）-> 毎回 deny し、引き継ぎを返す" {
    ctx 40
    wakeup
    [ "$(decision)" = deny ]
    [[ "$(reason)" == *"Herdr"*"/loop"* ]]
    wakeup
    [ "$(decision)" = deny ]
}

@test "200K の窓では使用率で判定する（50% で一段目、75% で二段目）" {
    ctx 49 200000; wakeup; [ -z "$output" ]
    ctx 50 200000; wakeup; [ "$(decision)" = deny ]; [[ "$(reason)" == *"一段目"* ]]
    ctx 75 200000; wakeup; [ "$(decision)" = deny ]; [[ "$(reason)" == *"二段目"* ]]
}

@test "窓の大きさが無いときも使用率で判定する" {
    mkdir -p "$TMPDIR/claude-status-context-usage"
    echo 80 > "$TMPDIR/claude-status-context-usage/sess"
    wakeup
    [[ "$(reason)" == *"二段目"* ]]
}

@test "二段目では新しい CronCreate も deny" {
    ctx 40
    cron "7 * * * *"
    [ "$(decision)" = deny ]
}

@test "一段目では CronCreate は通す" {
    ctx 30
    cron "7 * * * *"
    [ -z "$output" ]
}

@test "stop はコンテキストより先に判定する" {
    route stop
    ctx 40
    wakeup
    [[ "$(reason)" == *"stop"* ]]
}

@test "閾値は環境変数で差し替えられる" {
    ctx 30
    LOOP_GUARD_STATE_TOKENS=350000 LOOP_GUARD_HANDOFF_TOKENS=500000 wakeup
    [ -z "$output" ]
}

# --- ループの発火（UserPromptSubmit） ---

@test "予約した prompt の発火だけに知らせる" {
    route normal
    cron "7 * * * *" "/loop poll ci"
    route stop
    prompt "/loop poll ci"
    [[ "$(context_of)" == "[loop-guard] このプロンプトはループの発火。"*"CronDelete"* ]]
    prompt "ふつうの質問"
    [ -z "$output" ]
}

@test "発火で何も当たらなければ黙る" {
    route normal
    wakeup 1800 "/loop x"
    prompt "/loop x"
    [ -z "$output" ]
}

@test "発火でコンテキストの二段目 -> 引き継ぎを知らせる" {
    wakeup 1800 "/loop x"
    ctx 45
    prompt "/loop x"
    [[ "$(context_of)" == *"Herdr"* ]]
}

@test "発火で逼迫 -> 間隔の作り直しを知らせる" {
    cron "*/20 * * * *" "/loop y"
    route lean
    prompt "/loop y"
    [[ "$(context_of)" == *"CronDelete"*"20 分以上"* ]]
}

@test "deny した予約の prompt は覚えない" {
    route stop
    wakeup 1800 "/loop z"
    route normal
    ctx 40
    prompt "/loop z"
    [ -z "$output" ]
}
