#!/usr/bin/env bats
# loop-handoff.sh のユニットテスト。herdr は PATH の先頭に置いた偽物に差し替え、受けた引数を記録させる。
# 偽物の tab create の応答は、herdr の公式の文書（cli reference）の形（.result.tab.tab_id、
# .result.root_pane.pane_id）に合わせてある。
bats_require_minimum_version 1.5.0
set -u

URL="https://github.com/haoblackj/dotfiles/issues/69#issuecomment-6406782062"

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_loop-handoff.sh"
    TMPDIR_TEST="$(mktemp -d)"
    BIN="$TMPDIR_TEST/bin"
    CALLS="$TMPDIR_TEST/calls"
    mkdir -p "$BIN"
    cat > "$BIN/herdr" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$1 \$2" in
  "tab create") [ -n "\${FAKE_TAB_FAIL:-}" ] && { echo '{"error":{"code":"x"}}'; exit 1; }
                echo '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p42"}}}' ;;
  "agent start") [ -n "\${FAKE_START_FAIL:-}" ] && { echo '{"error":{"code":"agent_not_ready"}}'; exit 1; }
                 echo '{"result":{"agent":{"name":"x"}}}' ;;
  "agent prompt") echo '{"result":{"submitted":true}}' ;;
esac
EOF
    chmod +x "$BIN/herdr"
    export PATH="$BIN:$PATH"
    export HERDR_ENV=1 HERDR_WORKSPACE_ID=w1
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

handoff() { run bash "$SCRIPT" --state-url "$URL" --model opus --effort medium "$@" -- "/loop CI を見て、赤なら直す"; }

@test "タブを同じワークスペースと cwd に作り、そのペインで claude を起動し、引き継ぎを渡す" {
    handoff
    [ "$status" -eq 0 ]
    [ "$(jq -r .agent <<< "$output")" != "" ]
    [ "$(jq -r .pane <<< "$output")" = "w1:p42" ]
    run cat "$CALLS"
    [[ "${lines[0]}" == "tab create --workspace w1 --cwd $PWD --no-focus" ]]
    [[ "${lines[1]}" == "agent start loop-"*" --kind claude --pane w1:p42 -- --model opus --effort medium" ]]
    [[ "${lines[2]}" == "agent prompt loop-"*" /loop CI を見て、赤なら直す" ]]
    grep -qF "$URL" "$CALLS"
}

@test "prompt に --wait を付けない" {
    handoff
    run ! grep -q -- "--wait" "$CALLS"
}

@test "/loop を付け忘れても、付けて渡す" {
    run bash "$SCRIPT" --state-url "$URL" --model opus --effort medium -- "CI を見る"
    [ "$status" -eq 0 ]
    grep -q "^agent prompt loop-[0-9]* /loop CI を見る" "$CALLS"
}

@test "状態コメントへのリンクでなければ止まり、herdr を呼ばない" {
    run bash "$SCRIPT" --state-url "https://github.com/haoblackj/dotfiles/issues/69" --model opus --effort medium -- "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"## 状態"* ]]
    [ ! -e "$CALLS" ]
}

@test "モデルかエフォートが無ければ止まる" {
    run bash "$SCRIPT" --state-url "$URL" --effort medium -- "x"
    [ "$status" -eq 1 ]
    run bash "$SCRIPT" --state-url "$URL" --model opus --effort huge -- "x"
    [ "$status" -eq 1 ]
    [ ! -e "$CALLS" ]
}

@test "ループの指示が空なら止まる" {
    run bash "$SCRIPT" --state-url "$URL" --model opus --effort medium -- "/loop "
    [ "$status" -eq 1 ]
    [ ! -e "$CALLS" ]
}

@test "Herdr の外では止まる" {
    unset HERDR_ENV
    handoff
    [ "$status" -eq 1 ]
    [[ "$output" == *"HERDR_ENV"* ]]
}

@test "tab create が失敗したら、そこで止まる" {
    FAKE_TAB_FAIL=1 handoff
    [ "$status" -eq 1 ]
    [[ "$output" == *"tab create"* ]]
    [ "$(wc -l < "$CALLS")" -eq 1 ]
}

@test "agent start が失敗したら、ペインを残したことを返して止まる" {
    FAKE_START_FAIL=1 handoff
    [ "$status" -eq 1 ]
    [[ "$output" == *"w1:p42"* ]]
    run ! grep -q "^agent prompt" "$CALLS"
}

@test "--dry-run は herdr を呼ばずにコマンドを出す" {
    unset HERDR_ENV HERDR_WORKSPACE_ID
    handoff --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"tab create --workspace"* ]]
    [[ "$output" == *"agent start loop-"* ]]
    [ ! -e "$CALLS" ]
}
