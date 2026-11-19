#!/usr/bin/env bats
# session-handoff.sh のユニットテスト。herdr は PATH の先頭の偽物で確かめる。
bats_require_minimum_version 1.5.0
set -u

URL="https://github.com/haoblackj/dotfiles/issues/69#issuecomment-6406782062"  # 受け付けないことを確かめる用

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_session-handoff.sh"
    TMPDIR_TEST="$(mktemp -d)"
    BIN="$TMPDIR_TEST/bin"
    CALLS="$TMPDIR_TEST/calls"
    PRTS_CALLS="$TMPDIR_TEST/prts-calls"
    export HOME="$TMPDIR_TEST/home"
    mkdir -p "$BIN" "$HOME"
    cat > "$BIN/herdr" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$1 \$2" in
  "pane current") [ -n "\${FAKE_NO_CURRENT:-}" ] && exit 1
                  echo '{"result":{"type":"pane_current","pane":{"pane_id":"w3:p1","workspace_id":"w3","tab_id":"w3:t1","cwd":"'"\$FAKE_CWD"'","focused":true,"agent_status":"working","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"from-pane"},"revision":1,"terminal_id":"x"}}}' ;;
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
    cat > "$BIN/prts" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$PRTS_CALLS"
echo 標準出力へ出る文
[ -z "\${FAKE_PRTS_FAIL:-}" ]
EOF
    chmod +x "$BIN/prts"
    export PATH="$BIN:$PATH"
    export HERDR_ENV=1 HERDR_WORKSPACE_ID=w1
    unset CLAUDE_CODE_SESSION_ID
    export FAKE_CWD="$TMPDIR_TEST"
    REPO="$TMPDIR_TEST/repo"
    mkdir -p "$REPO/.git" "$REPO/docs/work"
    STATEF="$REPO/docs/work/sess.md"
    echo s > "$STATEF"
    STATEF=$(realpath -e "$STATEF")
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

handoff() { run bash "$SCRIPT" --title "タブ名の付け方" --model opus --effort medium "$@"; }

@test "作業記録で、指定の cwd に新しいタブを立てて渡す" {
    handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    grep -q -- "tab create --workspace w3 --cwd $FAKE_CWD --no-focus" "$CALLS"
    grep -q -- "agent start chat-.* --kind claude --pane w1:p42 --timeout 120000 -- --model opus --effort medium --name タブ名の付け方" "$CALLS"
    [ "$(jq -r .pane <<< "$output")" = "w1:p42" ]
    [ "$(jq -r .tab <<< "$output")" = "w1:t9" ]
    [ "$(jq -r .handed_off <<< "$output")" = true ]
    [ "$(jq -r .state <<< "$output")" = "$STATEF" ]
}
@test "作業記録は git の作業コピーの docs/work/ 直下の .md だけを受け付ける" {
    echo s > "$TMPDIR_TEST/x.md"
    handoff --state "$TMPDIR_TEST/x.md" --cwd "$FAKE_CWD"; [ "$status" -eq 1 ]
    [[ "$output" == *"作業記録はリポジトリの docs/work/ 直下に置く"* ]]
    mkdir -p "$REPO/docs/work/sub"; echo s > "$REPO/docs/work/sub/y.md"
    handoff --state "$REPO/docs/work/sub/y.md" --cwd "$FAKE_CWD"; [ "$status" -eq 1 ]
    echo s > "$REPO/docs/work/z.txt"
    handoff --state "$REPO/docs/work/z.txt" --cwd "$FAKE_CWD"; [ "$status" -eq 1 ]
    mkdir -p "$TMPDIR_TEST/nogit/docs/work"; echo s > "$TMPDIR_TEST/nogit/docs/work/a.md"
    handoff --state "$TMPDIR_TEST/nogit/docs/work/a.md" --cwd "$FAKE_CWD"; [ "$status" -eq 1 ]
    [[ "$output" == *"git の作業コピーの中に無い"* ]]
    [ ! -e "$CALLS" ]
}
@test "issue のコメントの URL は受け付けず、herdr を呼ばない" {
    handoff --state "$URL" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--state は作業記録"* ]]
    [ ! -e "$CALLS" ]
}
@test "相対パスの state と cwd は解決済みの絶対パスで渡す" {
    mkdir -p "$REPO/docs/work/sub" "$TMPDIR_TEST/work"
    cd "$TMPDIR_TEST"
    handoff --state "repo/docs/work/sub/../sess.md" --cwd "work/../work"
    [ "$status" -eq 0 ]
    state_path=$(realpath -e "$REPO/docs/work/sess.md")
    cwd_path=$(realpath -e "$TMPDIR_TEST/work")
    [ "$(jq -r .state <<< "$output")" = "$state_path" ]
    grep -Fq "最初に作業記録 $state_path を全部読み" "$CALLS"
    grep -Fx "tab create --workspace w3 --cwd $cwd_path --no-focus" "$CALLS"
}
@test "tab_id が無くても対話と loop の引き継ぎを続ける" {
    FAKE_NO_TAB_ID=1 handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    [ "$(jq -r .tab <<< "$output")" = "" ]
    [ "$(jq -r .pane <<< "$output")" = "w1:p42" ]
    grep -q '^agent prompt chat-' "$CALLS"
    FAKE_NO_TAB_ID=1 run bash "$BATS_TEST_DIRNAME/executable_loop-handoff.sh" \
        --state "$STATEF" --title "CI の赤の修正" --model opus --effort medium -- "/loop CI を見る"
    [ "$status" -eq 0 ]
    [ "$(jq -r .pane <<< "$output")" = "w1:p42" ]
    grep -q '^agent prompt loop-' "$CALLS"
}
@test "引き継ぎの文面は、作業記録を読んで次の一手から続け、案を決定として扱わないよう言い、/loop を付けない" {
    handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    expected="前のセッションからの引き継ぎ。最初に作業記録 $STATEF を全部読み、そこに書かれたブランチ、issue と PR を確かめてから「次に Claude がすること」から続ける。決めたこととして扱うのは「判断の経緯」で状態が有効の物だけで、「リーダーに決めてほしいこと」にある Claude の案は、リーダーの答えが出るまで決定として扱わない。このあとリーダーが言ったことが記録と食い違えば、リーダーの言ったことに従い、記録に変更として書く。記録の書き方はスキル work-record。"
    grep -Fx "agent prompt $(jq -r .agent <<< "$output") $expected" "$CALLS"
    prompt=$(grep "agent prompt" "$CALLS")
    run ! grep -q "/loop" <<< "$prompt"
}
@test "名前は 1 つの引数のまま claude の --name へ渡る" {
    handoff --state "$STATEF" --cwd "$FAKE_CWD" --title '-x "引用" と 空白' --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"--name -x\\ \\\"引用\\\"\\ と\\ 空白"* ]]
}
@test "名前が無いか、引き継ぎの語を含むか、20 文字を超えるか、改行を含めば止まり、herdr を呼ばない" {
    run bash "$SCRIPT" --model opus --effort medium --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--title"* ]]
    for bad in "prts issue #7 の引き継ぎ" "あいうえおかきくけこさしすせそたちつてとな" $'一行目\n二行目' "   "; do
        handoff --state "$STATEF" --cwd "$FAKE_CWD" --title "$bad"
        [ "$status" -eq 1 ]
    done
    [ ! -e "$CALLS" ]
}
@test "20 文字ちょうどの名前は通す" {
    handoff --state "$STATEF" --cwd "$FAKE_CWD" --title "あいうえおかきくけこさしすせそたちつてと"
    [ "$status" -eq 0 ]
}
@test "cwd にスペースがあっても渡る" { d="$TMPDIR_TEST/a b"; mkdir -p "$d"; handoff --state "$STATEF" --cwd "$d" --dry-run; [[ "$output" == *"a\\ b"* ]]; }
@test "cwd が無いディレクトリなら止まる" { handoff --state "$STATEF" --cwd /nonexistent; [ "$status" -eq 1 ]; }
@test "Herdr の外なら止まる" { unset HERDR_ENV; handoff --state "$STATEF" --cwd "$FAKE_CWD"; [ "$status" -eq 1 ]; }

@test "cwd は pane current の値ではなく指定した場所を使う" {
    d="$TMPDIR_TEST/selected"; mkdir -p "$d"
    handoff --state "$STATEF" --cwd "$d"
    [ "$status" -eq 0 ]
    grep -Fx "tab create --workspace w3 --cwd $d --no-focus" "$CALLS"
}
@test "作業記録の親参照や外への symlink は受け付けない" {
    echo s > "$REPO/docs/outside.md"
    ln -s "$REPO/docs/outside.md" "$REPO/docs/work/link.md"
    handoff --state "$REPO/docs/work/../outside.md" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    handoff --state "$REPO/docs/work/link.md" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    [ ! -e "$CALLS" ]
}
@test "tab create と agent start の失敗では次の手順へ進まない" {
    FAKE_TAB_FAIL=1 handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 1 ]
    [[ "$output" == *"tab create"* ]]
    run ! grep -q '^agent' "$CALLS"
    FAKE_START_FAIL=1 handoff --state "$STATEF" --cwd "$FAKE_CWD"
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
    handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    grep -qx '5 herdr pane current --current' "$TIMEOUT_CALLS"
    grep -Fx "tab create --workspace w1 --cwd $FAKE_CWD --no-focus" "$CALLS"
    run ! grep -q '^pane current' "$CALLS"
    unset HERDR_WORKSPACE_ID
    handoff --state "$STATEF" --cwd "$FAKE_CWD"
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
            --state "$STATEF" --cwd "$FAKE_CWD" --title "タブ名の付け方" --model opus --effort medium --dry-run
        [ "$status" -eq 1 ]
        [ -z "$output" ]
        [[ "$stderr" == *"session-handoff: 共通部分 herdr-start-claude.sh を読み込めない"* ]]
    done
    run ! test -e "$CALLS"
}

@test "引き継ぎ先の枠を prts に書き、応答の JSON は崩さない" {
    handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    [ "$(cat "$PRTS_CALLS")" = "wish moved --from-session from-pane --pane w1:p42" ]
    [ "$(jq -r .pane <<< "$output")" = "w1:p42" ]
}

@test "pane current が使えなければ、CLAUDE_CODE_SESSION_ID を元のセッションにする" {
    FAKE_NO_CURRENT=1 CLAUDE_CODE_SESSION_ID=from-env handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    [ "$(cat "$PRTS_CALLS")" = "wish moved --from-session from-env --pane w1:p42" ]
}

@test "元のセッションが分からなければ prts を呼ばない" {
    FAKE_NO_CURRENT=1 handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    [ ! -e "$PRTS_CALLS" ]
}

@test "prts が失敗しても引き継ぎは成功にする" {
    FAKE_PRTS_FAIL=1 handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    [ -e "$PRTS_CALLS" ]
    [ "$(jq -r .handed_off <<< "$output")" = true ]
}

@test "prts が無くても引き継ぎは成功にする" {
    mv "$BIN/prts" "$TMPDIR_TEST/prts-moved-away"
    ln -s "$(command -v jq)" "$BIN/jq"
    PATH="$BIN:/usr/bin:/bin" handoff --state "$STATEF" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    [ "$(jq -r .handed_off <<< "$output")" = true ]
}
