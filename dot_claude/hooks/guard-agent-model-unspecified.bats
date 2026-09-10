#!/usr/bin/env bats
# guard-agent-model-unspecified.sh のユニットテスト。
#
# Agent ツールの起動で model が指定されていない場合だけ deny することを確かめる。
# 判定は「出力に permissionDecision:deny が含まれるか」で見る。フックの終了コードは
# 常に 0 (fail-open) なので、終了コードで判定すると全部通ってしまう。
set -u

decide() { # <JSON payload>
  local payload="$1" out
  out=$(printf '%s' "$payload" | bash "$SCRIPT" 2>/dev/null)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    printf 'deny'
  else
    printf 'allow'
  fi
}

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/guard-agent-model-unspecified.sh"
}

@test "対象・未指定: general-purpose に model が無ければ deny" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}'
    [ "$output" = "deny" ]
}

@test "対象・未指定: subagent_type そのものが無くても deny" {
    run decide '{"tool_name":"Agent","tool_input":{}}'
    [ "$output" = "deny" ]
}

@test "対象・未指定: subagent_type が null でも deny" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":null}}'
    [ "$output" = "deny" ]
}

@test "対象・未指定: model が null でも deny" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","model":null}}'
    [ "$output" = "deny" ]
}

@test "対象・指定あり: general-purpose に model があれば素通り" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","model":"sonnet"}}'
    [ "$output" = "allow" ]
}

@test "境界の外: 名前付きの型は model が無くても素通り" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":"claude-code-guide"}}'
    [ "$output" = "allow" ]
}

@test "別のツール: Bash は素通り" {
    run decide '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
    [ "$output" = "allow" ]
}

@test "壊れた入力: 不正な JSON は素通り(fail-open)" {
    run decide 'not json'
    [ "$output" = "allow" ]
}

# 目印は transcript の集計が拒否を数えるときの照合に使う。文字列を変えると
# 過去の記録と突き合わせられなくなるので、このテストで固定する(issue #44 の条件7)。
@test "deny の理由文に集計用の目印が入っている" {
    run bash -c "printf '%s' '{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\"}}' | bash '$BATS_TEST_DIRNAME/guard-agent-model-unspecified.sh'"
    [[ "$output" == *"[guard-agent-model-unspecified]"* ]]
}
