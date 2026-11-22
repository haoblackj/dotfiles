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

context_of() { jq -r '.hookSpecificOutput.additionalContext // empty' <<< "$output"; }
route_of() { cut -d' ' -f1 "$STATE"; }

# --- offload（5時間枠） ---

@test "Claude の5時間枠 70%、リセットまで100分 -> offload を知らせ、要約に Claude のリセットまでの分" {
    usage 70 10 0 10 10 0 100
    call
    [ "$(route_of)" = offload ]
    [[ "$(context_of)" == *"codex-delegate.sh"* ]]
    [[ "$(context_of)" == *"スキル codex-delegate"* ]]
    [[ "$(context_of)" == *"Claude 5時間枠 使用 70%（リセットまで 100 分）"* ]]
    [[ "$(context_of)" == *"実装でない作業"*"縮めずに続ける"* ]]
}

# --- stop ---

@test "Claude の5時間枠 90% -> stop を知らせ、その後は何度呼んでも黙る" {
    usage 10 10 0 10 10 0
    call
    usage 90 10 0 10 10 0
    call
    [ "$(route_of)" = stop ]
    [[ "$(context_of)" == *"作業記録"* ]]
    for _ in 1 2 3 4 5 6 7; do
        call
        [ -z "$output" ]
    done
}

