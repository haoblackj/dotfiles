#!/usr/bin/env bats
# usage-route.sh のユニットテスト。本物の codexbar serve は呼ばず、file:// の JSON を読ませる。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_usage-route.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    FIXTURE="$TMPDIR_TEST/usage.json"
    export USAGE_ROUTE_URL="file://$FIXTURE"
    STATE="$TMPDIR_TEST/claude-usage-route/sess"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

# usage <claude5h> <claude週> <claudeペース差> <codex5h> <codex週> <codexペース差>
# ペース差に - を渡すと pace を省く
usage() {
    jq -n --argjson c5 "$1" --argjson cw "$2" --arg cd "$3" \
          --argjson x5 "$4" --argjson xw "$5" --arg xd "$6" '
      def e($p; $h; $w; $d): {provider: $p, source: "oauth",
        usage: {primary: {usedPercent: $h, resetsAt: "2026-10-01T13:49:59Z"},
                secondary: {usedPercent: $w, resetsAt: "2026-10-08T07:59:59Z"}}}
        + (if $d == "-" then {} else {pace: {secondary: {deltaPercent: ($d | tonumber)}}} end);
      [e("codex"; $x5; $xw; $xd), e("claude"; $c5; $cw; $cd)]' > "$FIXTURE"
}

call() {
    run bash "$SCRIPT" <<< '{"session_id":"sess","hook_event_name":"PostToolUse","tool_name":"Bash"}'
}

context_of() { jq -r '.hookSpecificOutput.additionalContext // empty' <<< "$output"; }

@test "サーバーに届かない -> 何も出さない" {
    export USAGE_ROUTE_URL="http://127.0.0.1:1/usage"
    call
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE" ]
}

@test "応答しないサーバー -> 2秒ほどで諦めて何も出さない" {
    # listen するが accept も応答もしないソケット。接続は backlog で成立し、curl は応答を待つ
    python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8); print(s.getsockname()[1], flush=True); time.sleep(30)' \
        > "$TMPDIR_TEST/port" &
    HANG_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMPDIR_TEST/port" ] && break; sleep 0.2; done
    [ -s "$TMPDIR_TEST/port" ]
    HANG_PORT="$(cat "$TMPDIR_TEST/port")"
    export USAGE_ROUTE_URL="http://127.0.0.1:$HANG_PORT/usage"
    SECONDS=0
    call
    kill "$HANG_PID" 2>/dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$SECONDS" -le 4 ]
}

@test "session_id が不正 -> 何も出さない" {
    usage 90 10 0 0 10 0
    run bash "$SCRIPT" <<< '{"session_id":"../x"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "初回で両方に余裕 -> 黙って split を記録" {
    usage 10 10 0 10 10 0
    call
    [ -z "$output" ]
    [ "$(cut -d' ' -f1 "$STATE")" = split ]
}

@test "初回で Codex の5時間枠が 85% -> claude-only を知らせる" {
    usage 10 10 0 85 10 0
    call
    [[ "$(context_of)" == *"実装も Claude"* ]]
    [ "$(cut -d' ' -f1 "$STATE")" = claude-only ]
}

@test "Codex の週枠のペース差が 25 -> claude-only" {
    usage 10 10 0 10 50 25
    call
    [ "$(cut -d' ' -f1 "$STATE")" = claude-only ]
}

@test "Codex の週枠のペース差 24、使用率 89 -> split" {
    usage 10 10 0 10 89 24
    call
    [ "$(cut -d' ' -f1 "$STATE")" = split ]
}

@test "Claude の5時間枠 85% -> stop-5h を知らせ、その後は何度呼んでも打ち切らない" {
    usage 10 10 0 10 10 0
    call
    usage 85 10 0 10 10 0
    call
    [[ "$(context_of)" == *"5時間枠"* ]]
    [ "$(cut -d' ' -f1 "$STATE")" = stop-5h ]
    for _ in 1 2 3 4 5 6 7; do
        call
        [ -z "$output" ]
    done
}

@test "Claude の週枠の使用率 90%（ペース差 0） -> stop-weekly" {
    usage 10 90 0 10 10 0
    call
    [[ "$(context_of)" == *"週枠"* ]]
    [ "$(cut -d' ' -f1 "$STATE")" = stop-weekly ]
}

@test "Claude の週枠のペース差 25（使用率 30） -> stop-weekly" {
    usage 10 30 25 10 10 0
    call
    [ "$(cut -d' ' -f1 "$STATE")" = stop-weekly ]
}

@test "pace が無い -> 使用率だけで判定する" {
    usage 10 50 - 10 10 -
    call
    [ "$(cut -d' ' -f1 "$STATE")" = split ]
}

@test "stop-weekly: 知らせたあと4回は黙り、5回目で continue:false、6回目以降は黙る" {
    usage 10 95 0 10 10 0
    call
    [ -n "$(context_of)" ]
    for _ in 1 2 3 4; do
        call
        [ -z "$output" ]
    done
    call
    [ "$(jq -r '.continue' <<< "$output")" = false ]
    [[ "$(jq -r '.stopReason' <<< "$output")" == *"週枠"* ]]
    for _ in 1 2 3; do
        call
        [ -z "$output" ]
    done
}

@test "stop-weekly から戻る -> split を知らせ、再び入ったら2段階をやり直す" {
    usage 10 95 0 10 10 0
    for _ in 1 2 3 4 5 6; do call; done
    usage 10 10 0 10 10 0
    call
    [[ "$(context_of)" == *"実装は Codex"* ]]
    usage 10 95 0 10 10 0
    call
    [ -n "$(context_of)" ]
    for _ in 1 2 3 4; do call; done
    call
    [ "$(jq -r '.continue' <<< "$output")" = false ]
}

@test "振り先が同じ -> 黙る" {
    usage 10 10 0 90 10 0
    call
    call
    [ -z "$output" ]
}

@test "Claude がエラー -> 振り先も状態も変えない" {
    usage 10 10 0 10 10 0
    call
    jq '(.[] | select(.provider == "claude")) |= {provider: "claude", error: {message: "timed out"}}' \
        "$FIXTURE" > "$FIXTURE.tmp" && mv "$FIXTURE.tmp" "$FIXTURE"
    call
    [ -z "$output" ]
    [ "$(cut -d' ' -f1 "$STATE")" = split ]
}

@test "Codex が2件 -> 先頭の1件で判定する" {
    usage 10 10 0 90 10 0
    jq '[.[0]] + [.[0] | .usage.primary.usedPercent = 0] + [.[1]]' "$FIXTURE" > "$FIXTURE.tmp" \
        && mv "$FIXTURE.tmp" "$FIXTURE"
    call
    [ "$(cut -d' ' -f1 "$STATE")" = claude-only ]
}
