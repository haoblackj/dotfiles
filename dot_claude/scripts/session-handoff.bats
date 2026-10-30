#!/usr/bin/env bats
# session-handoff.sh のユニットテスト。herdr は PATH の先頭の偽物で確かめる。
bats_require_minimum_version 1.5.0
set -u

URL="https://github.com/haoblackj/dotfiles/issues/69#issuecomment-6406782062"

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_session-handoff.sh"
    TMPDIR_TEST="$(mktemp -d)"
    BIN="$TMPDIR_TEST/bin"
    CALLS="$TMPDIR_TEST/calls"
    export HOME="$TMPDIR_TEST/home"
    mkdir -p "$BIN" "$HOME"
    cat > "$BIN/herdr" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$1 \$2" in
  "pane current") [ -n "\${FAKE_NO_CURRENT:-}" ] && exit 1
                  echo '{"result":{"type":"pane_current","pane":{"pane_id":"w3:p1","workspace_id":"w3","tab_id":"w3:t1","cwd":"'"\$FAKE_CWD"'","focused":true,"agent_status":"working","revision":1,"terminal_id":"x"}}}' ;;
  "pane wait-output") echo '{"result":{"matched":true}}' ;;
  "tab create") [ -n "\${FAKE_TAB_FAIL:-}" ] && { echo '{"error":{"code":"x"}}'; exit 1; }
                [ -n "\${FAKE_NO_TAB_ID:-}" ] && { echo '{"result":{"root_pane":{"pane_id":"w1:p42"}}}'; exit 0; }
                echo '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p42"}}}' ;;
  "agent start") [ -n "\${FAKE_START_FAIL:-}" ] && { echo '{"error":{"code":"agent_not_ready"}}'; exit 1; }
                 echo '{"result":{"agent":{"name":"x"}}}' ;;
  "agent prompt") echo '{"result":{"submitted":true}}' ;;
esac
EOF
    chmod +x "$BIN/herdr"
    export PATH="$BIN:$PATH"
    export HERDR_ENV=1 HERDR_WORKSPACE_ID=w1
    export FAKE_CWD="$TMPDIR_TEST"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

handoff() { run bash "$SCRIPT" --model opus --effort medium "$@"; }

@test "状態のコメントの URL で、指定の cwd に新しいタブを立てて渡す" {
    handoff --state "$URL" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    grep -q -- "tab create --workspace w3 --cwd $FAKE_CWD --no-focus" "$CALLS"
    grep -q -- "agent start chat-.* --kind claude --pane w1:p42 --timeout 120000 -- --model opus --effort medium" "$CALLS"
    [ "$(jq -r .pane <<< "$output")" = "w1:p42" ]
    [ "$(jq -r .tab <<< "$output")" = "w1:t9" ]
    [ "$(jq -r .handed_off <<< "$output")" = true ]
    [ "$(jq -r .state <<< "$output")" = "$URL" ]
}
@test "状態のファイルは ~/.cache/claude-handoff/ の下だけを受け付ける" {
    mkdir -p "$HOME/.cache/claude-handoff"; f="$HOME/.cache/claude-handoff/x.md"; echo s > "$f"
    handoff --state "$f" --cwd "$FAKE_CWD"; [ "$status" -eq 0 ]
    echo s > "$TMPDIR_TEST/x.md"
    handoff --state "$TMPDIR_TEST/x.md" --cwd "$FAKE_CWD"; [ "$status" -eq 1 ]
    [[ "$output" == *"状態のファイルは ~/.cache/claude-handoff/ 下に置く"* ]]
}
@test "相対パスの state と cwd は解決済みの絶対パスで渡す" {
    mkdir -p "$HOME/.cache/claude-handoff/sub" "$TMPDIR_TEST/work"
    echo s > "$HOME/.cache/claude-handoff/x.md"
    cd "$TMPDIR_TEST"
    handoff --state "home/.cache/claude-handoff/sub/../x.md" --cwd "work/../work"
    [ "$status" -eq 0 ]
    state_path=$(realpath -e "$HOME/.cache/claude-handoff/x.md")
    cwd_path=$(realpath -e "$TMPDIR_TEST/work")
    [ "$(jq -r .state <<< "$output")" = "$state_path" ]
    grep -Fq "最初に状態 $state_path を読み" "$CALLS"
    grep -Fx "tab create --workspace w3 --cwd $cwd_path --no-focus" "$CALLS"
}
@test "tab_id が無くても対話と loop の引き継ぎを続ける" {
    FAKE_NO_TAB_ID=1 handoff --state "$URL" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    [ "$(jq -r .tab <<< "$output")" = "" ]
    [ "$(jq -r .pane <<< "$output")" = "w1:p42" ]
    grep -q '^agent prompt chat-' "$CALLS"
    FAKE_NO_TAB_ID=1 run bash "$BATS_TEST_DIRNAME/executable_loop-handoff.sh" \
        --state-url "$URL" --model opus --effort medium -- "/loop CI を見る"
    [ "$status" -eq 0 ]
    [ "$(jq -r .pane <<< "$output")" = "w1:p42" ]
    grep -q '^agent prompt loop-' "$CALLS"
}
@test "引き継ぎの文面は、状態の在りかを読んで次の一手から続けるよう言い、/loop を付けない" {
    handoff --state "$URL" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    grep "agent prompt" "$CALLS" | grep -q "$URL"
    expected="前のセッションからの引き継ぎ。最初に状態 $URL を読み（issue のコメントなら、それより新しい \`## 状態\` も）、そこに書かれた作業フォルダ、ワークツリー、ブランチ、issue と PR を確かめてから「次の一手」から続ける。"
    grep -Fx "agent prompt $(jq -r .agent <<< "$output") $expected" "$CALLS"
    prompt=$(grep "agent prompt" "$CALLS")
    run ! grep -q "/loop" <<< "$prompt"
}
@test "cwd にスペースがあっても渡る" { d="$TMPDIR_TEST/a b"; mkdir -p "$d"; handoff --state "$URL" --cwd "$d" --dry-run; [[ "$output" == *"a\\ b"* ]]; }
@test "cwd が無いディレクトリなら止まる" { handoff --state "$URL" --cwd /nonexistent; [ "$status" -eq 1 ]; }
@test "Herdr の外なら止まる" { unset HERDR_ENV; handoff --state "$URL" --cwd "$FAKE_CWD"; [ "$status" -eq 1 ]; }

@test "cwd は pane current の値ではなく指定した場所を使う" {
    d="$TMPDIR_TEST/selected"; mkdir -p "$d"
    handoff --state "$URL" --cwd "$d"
    [ "$status" -eq 0 ]
    grep -Fx "tab create --workspace w3 --cwd $d --no-focus" "$CALLS"
}
@test "状態のファイルの親参照や外への symlink は受け付けない" {
    mkdir -p "$HOME/.cache/claude-handoff"
    echo s > "$HOME/.cache/outside.md"
    ln -s "$HOME/.cache/outside.md" "$HOME/.cache/claude-handoff/link.md"
    handoff --state "$HOME/.cache/claude-handoff/../outside.md" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    handoff --state "$HOME/.cache/claude-handoff/link.md" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    [ ! -e "$CALLS" ]
}
@test "tab create と agent start の失敗では次の手順へ進まない" {
    FAKE_TAB_FAIL=1 handoff --state "$URL" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"tab create"* ]]
    run ! grep -q '^agent' "$CALLS"
    FAKE_START_FAIL=1 handoff --state "$URL" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"agent start"* ]]
    run ! grep -q '^agent prompt' "$CALLS"
}

@test "pane current が 5 秒でタイムアウトしたら環境変数のワークスペースを使う" {
    export TIMEOUT_CALLS="$TMPDIR_TEST/timeout-calls"
    cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TIMEOUT_CALLS"
[[ "$*" == "5 herdr pane current --current" ]] || exit 1
exit 124
EOF
    chmod +x "$BIN/timeout"
    handoff --state "$URL" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    grep -qx '5 herdr pane current --current' "$TIMEOUT_CALLS"
    grep -Fx "tab create --workspace w1 --cwd $FAKE_CWD --no-focus" "$CALLS"
    run ! grep -q '^pane current' "$CALLS"
    unset HERDR_WORKSPACE_ID
    handoff --state "$URL" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ワークスペースが分からない"* ]]
}

@test "共通部分が無いか読み込みに失敗したら理由を標準エラーに出して止まる" {
    isolated="$TMPDIR_TEST/isolated"
    mkdir -p "$isolated"
    cp "$SCRIPT" "$isolated/handoff.sh"
    for helper in absent failed; do
        if [[ "$helper" == failed ]]; then
            echo 'return 1' > "$isolated/herdr-start-claude.sh"
        fi
        run --separate-stderr bash "$isolated/handoff.sh" \
            --state "$URL" --cwd "$FAKE_CWD" --model opus --effort medium --dry-run
        [ "$status" -eq 1 ]
        [ -z "$output" ]
        [[ "$stderr" == *"session-handoff: 共通部分 herdr-start-claude.sh を読み込めない"* ]]
    done
    run ! test -e "$CALLS"
}
