#!/usr/bin/env bats
# usage-route.sh のユニットテスト。本物の codexbar serve は呼ばず、file:// の JSON を読ませる。
set -u

NOW=1790000000

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_usage-route.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    export XDG_STATE_HOME="$TMPDIR_TEST/state"
    export USAGE_ROUTE_NOW="$NOW"
    FIXTURE="$TMPDIR_TEST/usage.json"
    export USAGE_ROUTE_URL="file://$FIXTURE"
    STATE="$TMPDIR_TEST/claude-usage-route/sess"
    LOG="$XDG_STATE_HOME/claude-usage-route/transitions.log"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

# usage <claude5h> <claude週> <claudeペース差> <codex5h> <codex週> <codexペース差> [<claude5hのリセットまでの分>]
# ペース差に - を渡すと pace を省く。リセットまでの分の既定は 120。
usage() {
    jq -n --argjson c5 "$1" --argjson cw "$2" --arg cd "$3" \
          --argjson x5 "$4" --argjson xw "$5" --arg xd "$6" \
          --argjson now "$NOW" --argjson left "${7:-120}" '
      def e($p; $h; $w; $d; $reset): {provider: $p, source: "oauth",
        usage: {primary: {usedPercent: $h, resetsAt: ($reset | todate)},
                secondary: {usedPercent: $w, resetsAt: "2026-10-08T07:59:59Z"}}}
        + (if $d == "-" then {} else {pace: {secondary: {deltaPercent: ($d | tonumber)}}} end);
      [e("codex"; $x5; $xw; $xd; $now + 7200), e("claude"; $c5; $cw; $cd; $now + $left * 60)]' > "$FIXTURE"
}

call() {
    run bash "$SCRIPT" <<< '{"session_id":"sess","hook_event_name":"PostToolUse","tool_name":"Bash"}'
}

# サブエージェントのツール呼び出し（入力に agent_id が付く）
call_sub() {
    run bash "$SCRIPT" <<< '{"session_id":"sess","agent_id":"sub1","hook_event_name":"PostToolUse","tool_name":"Bash"}'
}

# 失敗したツール呼び出し（PostToolUse の代わりに PostToolUseFailure が届く）
call_fail() {
    run bash "$SCRIPT" <<< '{"session_id":"sess","hook_event_name":"PostToolUseFailure","tool_name":"Bash"}'
}

context_of() { jq -r '.hookSpecificOutput.additionalContext // empty' <<< "$output"; }
route_of() { cut -d' ' -f1 "$STATE"; }

codex_error() {
    jq '(.[] | select(.provider == "codex")) |= {provider: "codex", error: {message: "x"}}' \
        "$FIXTURE" > "$FIXTURE.tmp" && mv "$FIXTURE.tmp" "$FIXTURE"
}

# --- 読めないときは黙る（fail-open） ---

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
    usage 95 10 0 0 10 0
    run bash "$SCRIPT" <<< '{"session_id":"../x"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Claude がエラー -> 振り先も状態も変えない" {
    usage 75 10 0 10 10 0
    call
    jq '(.[] | select(.provider == "claude")) |= {provider: "claude", error: {message: "timed out"}}' \
        "$FIXTURE" > "$FIXTURE.tmp" && mv "$FIXTURE.tmp" "$FIXTURE"
    call
    [ -z "$output" ]
    [ "$(route_of)" = offload ]
}

# --- normal ---

@test "初回で Claude に余裕 -> 黙って normal を記録" {
    usage 10 10 0 10 10 0
    call
    [ -z "$output" ]
    [ "$(route_of)" = normal ]
}

@test "Claude に余裕なら Codex が尽きていても normal（Codex へは投げないので知らせない）" {
    usage 10 10 0 95 95 30
    call
    [ -z "$output" ]
    [ "$(route_of)" = normal ]
}

@test "Claude に余裕で Codex が読めない -> normal" {
    usage 10 10 0 10 10 0
    codex_error
    call
    [ -z "$output" ]
    [ "$(route_of)" = normal ]
}

@test "振り先が同じ -> 黙る" {
    usage 75 10 0 10 10 0
    call
    [ -n "$(context_of)" ]
    call
    [ -z "$output" ]
}

# --- offload（5時間枠） ---

@test "Claude の5時間枠 69% -> normal" {
    usage 69 10 0 10 10 0
    call
    [ "$(route_of)" = normal ]
}

@test "Claude の5時間枠 70%、リセットまで100分 -> offload を知らせ、要約に Claude のリセットまでの分" {
    usage 70 10 0 10 10 0 100
    call
    [ "$(route_of)" = offload ]
    [[ "$(context_of)" == *"codex-delegate.sh"* ]]
    [[ "$(context_of)" == *"Claude 5時間枠 70%（リセットまで 100 分）"* ]]
}

@test "Claude の5時間枠 80%、リセットまで44分 -> 退避せず normal" {
    usage 80 10 0 10 10 0 44
    call
    [ "$(route_of)" = normal ]
}

@test "offload 中に5時間枠 85% のままリセットまで30分 -> offload のまま（45分の条件は入るときだけ）" {
    usage 85 10 0 10 10 0 120
    call
    usage 85 10 0 10 10 0 30
    call
    [ -z "$output" ]
    [ "$(route_of)" = offload ]
}

@test "stop 中に5時間枠 79%、リセットまで30分 -> offload（逼迫のまま）" {
    usage 92 10 0 10 10 0 30
    call
    usage 79 10 0 10 10 0 30
    call
    [ "$(route_of)" = offload ]
}

@test "Claude の5時間枠 80%、リセットまで30分 -> 退避せず normal" {
    usage 80 10 0 10 10 0 30
    call
    [ "$(route_of)" = normal ]
}

@test "Claude の5時間枠 80%、リセットまで45分 -> offload" {
    usage 80 10 0 10 10 0 45
    call
    [ "$(route_of)" = offload ]
}

@test "offload 中に 5時間枠 60% -> offload のまま、59% -> normal を知らせる" {
    usage 75 10 0 10 10 0
    call
    usage 60 10 0 10 10 0
    call
    [ -z "$output" ]
    [ "$(route_of)" = offload ]
    usage 59 10 0 10 10 0
    call
    [ "$(route_of)" = normal ]
    [[ "$(context_of)" == *"実装は Claude"* ]]
}

@test "normal から 5時間枠 65% -> normal のまま（入りは 70%）" {
    usage 10 10 0 10 10 0
    call
    usage 65 10 0 10 10 0
    call
    [ "$(route_of)" = normal ]
}

# --- offload（週枠） ---

@test "Claude の週のペース差 +10 -> offload" {
    usage 10 40 10 10 10 0
    call
    [ "$(route_of)" = offload ]
}

@test "Claude の週のペース差 +9、使用率 74% -> normal" {
    usage 10 74 9 10 10 0
    call
    [ "$(route_of)" = normal ]
}

@test "Claude の週枠の使用率 75%（ペース差 -5） -> offload" {
    usage 10 75 -5 10 10 0
    call
    [ "$(route_of)" = offload ]
}

@test "Claude の週のペース差 +25、使用率 80% -> stop ではなく offload" {
    usage 10 80 25 10 10 0
    call
    [ "$(route_of)" = offload ]
}

@test "週で offload 中: ペース差 +1 -> offload のまま、ペース差 0 で使用率 69% -> normal" {
    usage 10 50 12 10 10 0
    call
    usage 10 50 1 10 10 0
    call
    [ "$(route_of)" = offload ]
    usage 10 69 0 10 10 0
    call
    [ "$(route_of)" = normal ]
}

@test "週で offload 中: ペース差 0 でも使用率 70% -> offload のまま" {
    usage 10 76 0 10 10 0
    call
    usage 10 70 0 10 10 0
    call
    [ "$(route_of)" = offload ]
}

@test "pace が無い -> 使用率だけで判定する" {
    usage 10 50 - 10 10 -
    call
    [ "$(route_of)" = normal ]
    usage 10 75 - 10 10 -
    call
    [ "$(route_of)" = offload ]
}

# --- lean（Claude が逼迫、Codex も逼迫か読めない） ---

@test "Claude 逼迫で Codex の5時間枠 70% -> lean を知らせる" {
    usage 75 10 0 70 10 0
    call
    [ "$(route_of)" = lean ]
    [[ "$(context_of)" == *"退避しない"* ]]
}

@test "Claude 逼迫で Codex の週枠 85% -> lean" {
    usage 75 10 0 10 85 0
    call
    [ "$(route_of)" = lean ]
}

@test "Claude 逼迫で Codex の週のペース差 +15 -> lean、+14 -> offload" {
    usage 75 10 0 10 50 15
    call
    [ "$(route_of)" = lean ]
    usage 75 10 0 10 50 14
    call
    [ "$(route_of)" = offload ]
}

@test "Claude 逼迫で Codex が読めない -> lean で、要約に Codex 読めず" {
    usage 75 10 0 10 10 0
    codex_error
    call
    [ "$(route_of)" = lean ]
    [[ "$(context_of)" == *"Codex 読めず"* ]]
}

@test "Claude 逼迫で Codex のエントリーが無い -> lean" {
    usage 75 10 0 10 10 0
    jq '[.[] | select(.provider == "claude")]' "$FIXTURE" > "$FIXTURE.tmp" && mv "$FIXTURE.tmp" "$FIXTURE"
    call
    [ "$(route_of)" = lean ]
}

@test "配列にオブジェクトでない要素が混ざっても判定する" {
    usage 95 10 0 10 10 0
    jq '["junk", 3] + .' "$FIXTURE" > "$FIXTURE.tmp" && mv "$FIXTURE.tmp" "$FIXTURE"
    call
    [ "$(route_of)" = stop ]
}

@test "同じセッションの並列の呼び出しでは、遷移を一度だけ知らせ、ログも1行" {
    usage 75 10 0 10 10 0
    for i in 1 2 3 4 5 6 7 8; do
        bash "$SCRIPT" <<< '{"session_id":"sess","hook_event_name":"PostToolUse","tool_name":"Bash"}' \
            > "$TMPDIR_TEST/out.$i" &
    done
    wait
    [ "$(cat "$TMPDIR_TEST"/out.* | grep -c additionalContext)" -eq 1 ]
    [ "$(wc -l < "$LOG")" -eq 1 ]
    [ "$(route_of)" = offload ]
}

@test "Codex が2件 -> 先頭の1件で判定する" {
    usage 75 10 0 90 10 0
    jq '[.[0]] + [.[0] | .usage.primary.usedPercent = 0] + [.[1]]' "$FIXTURE" > "$FIXTURE.tmp" \
        && mv "$FIXTURE.tmp" "$FIXTURE"
    call
    [ "$(route_of)" = lean ]
}

@test "lean 中に Claude の5時間枠 65% -> lean のまま（出るのは 60% 未満）" {
    usage 75 10 0 90 10 0
    call
    usage 65 10 0 90 10 0
    call
    [ "$(route_of)" = lean ]
}

@test "lean から Codex に余裕が戻る -> offload を知らせる" {
    usage 75 10 0 90 10 0
    call
    usage 75 10 0 10 10 0
    call
    [ "$(route_of)" = offload ]
    [ -n "$(context_of)" ]
}

# --- stop ---

@test "Claude の5時間枠 90% -> stop を知らせ、その後は何度呼んでも黙る" {
    usage 10 10 0 10 10 0
    call
    usage 90 10 0 10 10 0
    call
    [ "$(route_of)" = stop ]
    [[ "$(context_of)" == *"issue に状態"* ]]
    for _ in 1 2 3 4 5 6 7; do
        call
        [ -z "$output" ]
    done
}

@test "Claude の5時間枠 90% はリセット間際（10分）でも stop" {
    usage 90 10 0 10 10 0 10
    call
    [ "$(route_of)" = stop ]
}

@test "Claude の週枠 95% -> stop" {
    usage 10 95 0 10 10 0
    call
    [ "$(route_of)" = stop ]
}

@test "Claude の週枠 94% -> stop ではなく offload" {
    usage 10 94 0 10 10 0
    call
    [ "$(route_of)" = offload ]
}

@test "Codex が読めず Claude の週枠 95% -> stop" {
    usage 10 95 0 10 10 0
    codex_error
    call
    [ "$(route_of)" = stop ]
    [[ "$(context_of)" == *"Codex 読めず"* ]]
}

@test "stop 中に5時間枠 85% -> stop のまま、79% -> offload を知らせる" {
    usage 92 10 0 10 10 0
    call
    usage 85 10 0 10 10 0
    call
    [ "$(route_of)" = stop ]
    usage 79 10 0 10 10 0
    call
    [ "$(route_of)" = offload ]
    [ -n "$(context_of)" ]
}

@test "stop 中に週枠 91% -> stop のまま、89% -> offload（週の使用率 70% 以上なので逼迫のまま）" {
    usage 10 96 0 10 10 0
    call
    usage 10 91 0 10 10 0
    call
    [ "$(route_of)" = stop ]
    usage 10 89 0 10 10 0
    call
    [ "$(route_of)" = offload ]
}

@test "stop から一気に余裕が戻る -> normal を知らせる" {
    usage 95 10 0 10 10 0
    call
    usage 10 10 0 10 10 0
    call
    [ "$(route_of)" = normal ]
    [[ "$(context_of)" == *"余裕が戻った"* ]]
}

@test "stop から normal に戻り、再び入ったらもう一度知らせる" {
    usage 95 10 0 10 10 0
    call
    usage 10 10 0 10 10 0
    call
    usage 95 10 0 10 10 0
    call
    [ "$(route_of)" = stop ]
    [ -n "$(context_of)" ]
}

# --- サブエージェント ---

@test "サブエージェントの呼び出し -> 判定も状態の更新もせず黙る" {
    usage 75 10 0 10 10 0
    call_sub
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE" ]
}

@test "サブエージェントが先に呼ばれても、親の次の呼び出しで遷移を知らせる" {
    usage 10 10 0 10 10 0
    call
    usage 75 10 0 10 10 0
    call_sub
    [ -z "$output" ]
    [ "$(route_of)" = normal ]
    call
    [ "$(route_of)" = offload ]
    [ -n "$(context_of)" ]
}

# --- イベント名 ---

@test "PostToolUseFailure -> 知らせのイベント名を入力に合わせ、何度呼んでも黙る" {
    usage 10 95 0 10 10 0
    call_fail
    [ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" = PostToolUseFailure ]
    [ -n "$(context_of)" ]
    for _ in 1 2 3 4 5 6 7; do
        call_fail
        [ -z "$output" ]
    done
}

@test "PostToolUse の知らせのイベント名は PostToolUse" {
    usage 10 95 0 10 10 0
    call
    [ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" = PostToolUse ]
}

# --- 前の版の状態ファイル ---

@test "前の版の状態 split -> 方針が変わったことを一度だけ知らせて normal を記録" {
    usage 10 10 0 10 10 0
    mkdir -p "$(dirname "$STATE")"
    echo split > "$STATE"
    call
    [[ "$(context_of)" == *"平常は Claude が実装"* ]]
    [ "$(route_of)" = normal ]
    call
    [ -z "$output" ]
}

@test "前の版の状態 claude-only -> normal として読み、黙って normal を記録" {
    usage 10 10 0 10 10 0
    mkdir -p "$(dirname "$STATE")"
    echo claude-only > "$STATE"
    call
    [ -z "$output" ]
    [ "$(route_of)" = normal ]
}

@test "前の版の状態 split で Claude が逼迫 -> offload を知らせる" {
    usage 75 10 0 10 10 0
    mkdir -p "$(dirname "$STATE")"
    echo split > "$STATE"
    call
    [ "$(route_of)" = offload ]
    [[ "$(context_of)" == *"codex-delegate.sh"* ]]
}

@test "前の版の状態 stop-5h / stop-weekly（打ち切りの数つき） -> stop として読み、黙る" {
    usage 10 95 0 10 10 0
    mkdir -p "$(dirname "$STATE")"
    for old in "stop-5h" "stop-weekly 4 0" "stop-weekly 5 2"; do
        echo "$old" > "$STATE"
        call
        [ -z "$output" ]
        [ "$(route_of)" = stop ]
    done
}

# --- 遷移のログ ---

@test "遷移のたびにログへ1行、変わらなければ書かない" {
    usage 10 10 0 10 10 0
    call
    call
    usage 75 10 0 10 10 0
    call
    call
    [ "$(wc -l < "$LOG")" -eq 2 ]
    [[ "$(sed -n 1p "$LOG")" == *$'\tsess\t\tnormal\t'* ]]
    [[ "$(sed -n 2p "$LOG")" == *$'\tsess\tnormal\toffload\t'* ]]
}

@test "ログに書けなくても知らせは出る" {
    export XDG_STATE_HOME="/proc/nonexistent"
    usage 75 10 0 10 10 0
    call
    [ "$status" -eq 0 ]
    [ "$(route_of)" = offload ]
    [ -n "$(context_of)" ]
}
