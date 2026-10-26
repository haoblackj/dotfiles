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
    # 繰り返しの CronCreate は既定で止める。その判定は「固定間隔のループ」の節で見る。
    # ほかの節では、許したときの判定（stop、二段目、逼迫の間隔）を確かめるため許しておく
    export LOOP_GUARD_ALLOW_RECURRING_CRON=1
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

@test "既定でも一度きりの CronCreate は通す" {
    unset LOOP_GUARD_ALLOW_RECURRING_CRON
    cron "30 14 28 2 *" "/remind" false
    [ -z "$output" ]
}

@test "既定では deny した繰り返しの予約の prompt を覚えない" {
    unset LOOP_GUARD_ALLOW_RECURRING_CRON
    cron "7 * * * *" "/loop q"
    route stop
    prompt "/loop q"
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

@test "stop -> CronCreate は一度きりも deny（一度きりの予約で次の回を取らせない）" {
    route stop
    cron "7 * * * *"
    [ "$(decision)" = deny ]
    cron "30 14 28 2 *" "/remind" false
    [ "$(decision)" = deny ]
    [[ "$(reason)" == *"一度きりも"* ]]
}

@test "stop のときは、固定間隔を許していなくても stop の理由を返す" {
    unset LOOP_GUARD_ALLOW_RECURRING_CRON
    route stop
    cron "7 * * * *"
    [[ "$(reason)" == *"stop"* ]]
    [[ "$(reason)" != *"固定間隔のループ（繰り返しの CronCreate）は使わない"* ]]
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
    # 時が限られていても、続く時どうしの境目はまたぐ（9:50 と 10:00 は 10 分おき）
    cron "50,0 9,10 * * *"
    [ "$(decision)" = deny ]
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
    [[ "$(reason)" == *"loop-handoff.sh --state-url"*"Herdr"* ]]
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

@test "二段目では新しい CronCreate も、一度きりも deny" {
    ctx 40
    cron "7 * * * *"
    [ "$(decision)" = deny ]
    cron "30 14 28 2 *" "/remind" false
    [ "$(decision)" = deny ]
    [[ "$(reason)" == *"loop-handoff.sh"* ]]
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

@test "固定間隔を許していなければ、発火で振り先の知らせを出さない（振り先が古いことがあるため）" {
    unset LOOP_GUARD_ALLOW_RECURRING_CRON
    route normal
    wakeup 1800 "/loop w"
    route stop
    prompt "/loop w"
    [ -z "$output" ]
    route lean
    prompt "/loop w"
    [ -z "$output" ]
}

@test "発火の一段目の知らせは一度だけで、そのあとの予約の deny の一度きりは残る" {
    wakeup 1800 "/loop s"
    ctx 32
    prompt "/loop s"
    [[ "$(context_of)" == *"この回の作業の前に"*"## 状態"* ]]
    prompt "/loop s"
    [ -z "$output" ]
    wakeup 1800 "/loop s"
    [ "$(decision)" = deny ]
    wakeup 1800 "/loop s"
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

# --- ループ以外の対話セッション（UserPromptSubmit、#71） ---

@test "対話で一段目 -> 依頼のあとに /clear を勧めさせる。一度だけ" {
    ctx 32
    prompt "ふつうの依頼"
    [[ "$(context_of)" == "[loop-guard] "*"一段目"*"/clear"* ]]
    [[ "$(context_of)" == *"片付けたら"* ]]
    prompt "次の依頼"
    [ -z "$output" ]
    grep -q "notice:chat-state" "$LOG"
}

@test "対話で二段目 -> 依頼の前に状態を書き出し、/clear を勧めて止まらせる。一度だけ" {
    ctx 45
    prompt "ふつうの依頼"
    [[ "$(context_of)" == *"二段目"*"入る前に"*"/clear"* ]]
    [[ "$(context_of)" != *"Herdr"* ]]
    prompt "このまま続けて"
    [ -z "$output" ]
}

@test "対話で一段目の知らせのあとに二段目を越えたら、二段目も一度出す" {
    ctx 32
    prompt "a"
    ctx 45
    prompt "b"
    [[ "$(context_of)" == *"二段目"* ]]
}

@test "対話で一段目を下回ったら、次に越えたときにまた知らせる" {
    ctx 32
    prompt "a"
    ctx 5
    prompt "b"
    [ -z "$output" ]
    ctx 32
    prompt "c"
    [[ "$(context_of)" == *"一段目"* ]]
}

@test "対話で閾値の下か、使用率が測れない -> 黙る" {
    ctx 10
    prompt "a"
    [ -z "$output" ]
    rm -f "$TMPDIR/claude-status-context-usage/sess"
    prompt "b"
    [ -z "$output" ]
}

@test "/loop で始まる prompt には対話の知らせを出さない" {
    ctx 45
    prompt "/loop check ci"
    [ -z "$output" ]
    prompt "  /loop"
    [ -z "$output" ]
    prompt "/loopy は別のコマンド"
    [[ "$(context_of)" == *"二段目"* ]]
}

@test "予約を通したことのあるセッションでは、手打ちの prompt に対話の知らせを出さない" {
    wakeup 1800 "/loop w"
    ctx 45
    prompt "ループの合間の質問"
    [ -z "$output" ]
    prompt "/loop w"
    [[ "$(context_of)" == *"Herdr"* ]]
}

@test "対話でサブエージェントの入力 -> 何もしない" {
    ctx 45
    run bash "$SCRIPT" <<< '{"session_id":"sess","agent_id":"a1","hook_event_name":"UserPromptSubmit","prompt":"x"}'
    [ -z "$output" ]
}
