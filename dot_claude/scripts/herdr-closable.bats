#!/usr/bin/env bats
# herdr-closable.sh のテスト。実機の見本と同じ形の応答を、PATH の先頭の偽物から返す。
bats_require_minimum_version 1.5.0
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_herdr-closable.sh"
    TMPDIR_TEST="$(mktemp -d)"
    BIN="$TMPDIR_TEST/bin"
    export HOME="$TMPDIR_TEST/home" TMPDIR="$TMPDIR_TEST/tmp"
    export CALLS="$TMPDIR_TEST/calls" PANES="$TMPDIR_TEST/panes.json"
    export FAKE_CWD="$TMPDIR_TEST"
    mkdir -p "$BIN" "$HOME/.claude/projects/p" "$TMPDIR"
    cat > "$BIN/herdr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "pane current")
    [ -n "${FAKE_NO_CURRENT:-}" ] && exit 1
    jq -nc --arg cwd "$FAKE_CWD" '{result:{type:"pane_current",pane:{pane_id:"w3:p1",workspace_id:"w3",tab_id:"w3:t1",cwd:$cwd,focused:true,agent_status:"working",revision:1,terminal_id:"x"}}}' ;;
  "pane list")
    [ -n "${FAKE_LIST_FAIL:-}" ] && exit 1
    cat "$PANES" ;;
  "tab close")
    [ -n "${FAKE_CLOSE_FAIL:-}" ] && exit 1
    jq --arg tab "$3" '.result.panes |= map(select(.tab_id != $tab))' "$PANES" > "$PANES.next"
    mv "$PANES.next" "$PANES"
    echo '{"result":{"type":"tab_close"}}' ;;
esac
EOF
    chmod +x "$BIN/herdr"
    export PATH="$BIN:$PATH"
    export HERDR_ENV=1 HERDR_WORKSPACE_ID=w9 HERDR_PANE_ID=w9:p9
    cat > "$PANES" <<'EOF'
{"result":{"type":"pane_list","panes":[
  {"pane_id":"w3:p1","tab_id":"w3:t1","workspace_id":"w3","agent":"claude","agent_status":"working","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"self"},"terminal_title_stripped":"作業中"},
  {"pane_id":"w3:p2","tab_id":"w3:t2","workspace_id":"w3","agent":"claude","agent_status":"idle","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-2"},"terminal_title_stripped":"検証結果"}
]}}
EOF
    cat > "$HOME/.claude/projects/p/session-2.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"検証して"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"終わったよ。このタブは閉じていいよ"}]}}
EOF
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

panes_edit() {
    jq "$@" "$PANES" > "$PANES.next"
    mv "$PANES.next" "$PANES"
}

closable() {
    run bash "$SCRIPT" "$@"
    [ "$status" -eq 0 ]
}

no_close() {
    run ! grep -q '^tab close ' "$CALLS"
}

@test "list 同じワークスペースの idle の Claude を、最後の応答の文面つきで出す" {
    closable list
    [ "${#lines[@]}" -eq 1 ]
    [ "$(jq -r .last_reply <<< "$output")" = "終わったよ。このタブは閉じていいよ" ]
    [ "$(jq -c 'del(.last_reply)' <<< "$output")" = '{"pane":"w3:p2","tab":"w3:t2","session_id":"session-2","title":"検証結果"}' ]
    grep -qx 'pane current --current' "$CALLS"
    no_close
}

@test "list 他のワークスペースは出さない" {
    panes_edit '.result.panes[1].workspace_id = "w9"'
    closable list
    [ -z "$output" ]
}

@test "list 自分と --exclude-pane のペインは出さない" {
    panes_edit '.result.panes[0].agent_status = "idle"'
    cp "$HOME/.claude/projects/p/session-2.jsonl" "$HOME/.claude/projects/p/self.jsonl"
    closable list
    [ "${#lines[@]}" -eq 1 ]
    [ "$(jq -r .pane <<< "$output")" = w3:p2 ]
    closable list --exclude-pane w3:p9 --exclude-pane w3:p2
    [ -z "$output" ]
}

@test "list 値が無い --exclude-pane と知らない引数は理由を標準エラーに出して止まる" {
    run --separate-stderr bash "$SCRIPT" list --exclude-pane
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = 'herdr-closable: --exclude-pane に値が無い' ]
    [ ! -e "$CALLS" ]
    run --separate-stderr bash "$SCRIPT" list --unknown
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = 'herdr-closable: 知らない引数: --unknown' ]
    [ ! -e "$CALLS" ]
    HERDR_ENV=0 run --separate-stderr bash "$SCRIPT" list --exclude-pane --unknown
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = 'herdr-closable: --exclude-pane に値が無い' ]
    [ ! -e "$CALLS" ]
}

@test "list working のものは出さない" {
    panes_edit '.result.panes[1].agent_status = "working"'
    closable list
    [ -z "$output" ]
}

@test "list idle 以外や Claude 以外、セッション ID が無いものは出さない" {
    panes_edit '.result.panes[1].agent_status = "done"'
    closable list
    [ -z "$output" ]
    panes_edit '.result.panes[1] |= (.agent_status = "idle" | .agent = "codex")'
    closable list
    [ -z "$output" ]
    panes_edit '.result.panes[1] |= (.agent = "claude" | del(.agent_session))'
    closable list
    [ -z "$output" ]
}

@test "list ループのセッションは出さない" {
    mkdir -p "$TMPDIR/claude-loop-guard"
    touch "$TMPDIR/claude-loop-guard/session-2.prompts"
    closable list
    [ -z "$output" ]
}

@test "list transcript が無いか二つあるものは出さない" {
    mkdir -p "$HOME/.claude/projects/q"
    cp "$HOME/.claude/projects/p/session-2.jsonl" "$HOME/.claude/projects/q/session-2.jsonl"
    closable list
    [ -z "$output" ]
    rm "$HOME/.claude/projects/"{p,q}/session-2.jsonl
    closable list
    [ -z "$output" ]
}

@test "list 最後の応答のあとにユーザーの入力があるものは出さない" {
    echo '{"type":"user","message":{"content":"追加で検証して"}}' >> "$HOME/.claude/projects/p/session-2.jsonl"
    closable list
    [ -z "$output" ]
}

@test "list 最後の入力より後の複数行の text をつなぎ tool_result は入力に数えない" {
    cat > "$HOME/.claude/projects/p/session-2.jsonl" <<'EOF'
{"type":"user","message":{"content":"前の入力"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"前の応答"}]}}
{"type":"user","message":{"content":[{"type":"text","text":"今の入力"},{"type":"tool_result"}]}}
{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"考え中"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"終わったよ。"},{"type":"tool_use"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"結果"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"このタブは"},{"type":"text","text":"閉じていいよ"}]}}
{"type":"user","message":{"content":[{"type":"tool_result"}]}}
EOF
    closable list
    [ "$(jq -r .last_reply <<< "$output")" = "終わったよ。このタブは閉じていいよ" ]
}

@test "list isMeta の入力と isSidechain の行は読まない" {
    cat >> "$HOME/.claude/projects/p/session-2.jsonl" <<'EOF'
{"type":"user","isMeta":true,"message":{"content":"補足情報"}}
{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"別の応答"}]}}
{"type":"user","isSidechain":true,"message":{"content":"別の入力"}}
EOF
    closable list
    [ "$(jq -r .last_reply <<< "$output")" = "終わったよ。このタブは閉じていいよ" ]
}

@test "list 最後のユーザー入力より後に text が無ければ出さない" {
    cat >> "$HOME/.claude/projects/p/session-2.jsonl" <<'EOF'
{"type":"user","message":{"content":[{"type":"text","text":"続けて"}]}}
{"type":"assistant","message":{"content":[{"type":"thinking"},{"type":"tool_use"}]}}
EOF
    closable list
    [ -z "$output" ]
}

@test "list ユーザー入力が無い transcript や壊れた transcript は出さない" {
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"応答"}]}}' > "$HOME/.claude/projects/p/session-2.jsonl"
    closable list
    [ -z "$output" ]
    echo '{' >> "$HOME/.claude/projects/p/session-2.jsonl"
    closable list
    [ -z "$output" ]
}

@test "list タブに他のペインがあれば出さない" {
    panes_edit '.result.panes += [{pane_id:"w3:p3",tab_id:"w3:t2",workspace_id:"w3",agent_status:"unknown"}]'
    closable list
    [ -z "$output" ]
}

@test "list ワークスペースの最後のタブは出さない" {
    panes_edit '.result.panes[0].workspace_id = "w9"'
    closable list
    [ -z "$output" ]
}

@test "list 候補ごとに JSON を一行出し、文面の改行や引用符を保つ" {
    panes_edit '.result.panes += [(.result.panes[1] | .pane_id = "w3:p3" | .tab_id = "w3:t3" | .agent_session.value = "session-3")]'
    cat > "$HOME/.claude/projects/p/session-3.jsonl" <<'EOF'
{"type":"user","message":{"content":"検証して"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"結果\n\"確認\"\\済み"}]}}
EOF
    closable list
    [ "${#lines[@]}" -eq 2 ]
    [ "$(jq -sr '.[1].last_reply' <<< "$output")" = $'結果\n"確認"\\済み' ]
}

@test "list Herdr の外や現在のペインが不明なら黙って返す" {
    FAKE_NO_CURRENT=1 closable list
    [ -z "$output" ]
    rm "$CALLS"
    HERDR_ENV=0 closable list
    [ -z "$output" ]
    [ ! -e "$CALLS" ]
}

@test "list ペイン一覧が取得できないか壊れていれば黙って返す" {
    FAKE_LIST_FAIL=1 closable list
    [ -z "$output" ]
    echo '{' > "$PANES"
    closable list
    [ -z "$output" ]
}

@test "close idle で一つきりのペインのタブを閉じる" {
    closable close w3:p2
    [ "$output" = '{"pane":"w3:p2","tab":"w3:t2","result":"closed"}' ]
    grep -qx 'tab close w3:t2' "$CALLS"
    [ "$(grep -c '^pane list$' "$CALLS")" -eq 1 ]
    grep -qx 'pane current --current' "$CALLS"
}

@test "close 別のワークスペースのペインは残す" {
    panes_edit '.result.panes += [
        (.result.panes[1] | .pane_id = "w9:p2" | .tab_id = "w9:t2" | .workspace_id = "w9"),
        (.result.panes[1] | .pane_id = "w9:p3" | .tab_id = "w9:t3" | .workspace_id = "w9")
    ]'
    closable close w9:p2
    [ "$output" = '{"pane":"w9:p2","result":"kept","reason":"other_workspace"}' ]
    [ "$(jq '[.result.panes[] | select(.pane_id == "w9:p2")] | length' "$PANES")" -eq 1 ]
    no_close
}

@test "close ループのペインは残す" {
    mkdir -p "$TMPDIR/claude-loop-guard"
    touch "$TMPDIR/claude-loop-guard/session-2.prompts"
    closable close w3:p2
    [ "$output" = '{"pane":"w3:p2","result":"kept","reason":"loop"}' ]
    no_close
}

@test "close Claude 以外のペインは残す" {
    panes_edit '.result.panes[1].agent = "codex"'
    closable close w3:p2
    [ "$output" = '{"pane":"w3:p2","result":"kept","reason":"not_claude"}' ]
    no_close
}

@test "close 呼んだペイン自身は idle でも残す" {
    panes_edit '.result.panes[0].agent_status = "idle"'
    closable close w3:p1
    [ "$output" = '{"pane":"w3:p1","result":"kept","reason":"self"}' ]
    no_close
}

@test "close done も idle ではないので残す" {
    panes_edit '.result.panes[1].agent_status = "done"'
    closable close w3:p2
    [ "$output" = '{"pane":"w3:p2","result":"kept","reason":"not_idle"}' ]
    no_close
}

@test "close 直前に working なら残す" {
    closable list
    [ "$(jq -r .pane <<< "$output")" = w3:p2 ]
    panes_edit '.result.panes[1].agent_status = "working"'
    closable close w3:p2
    [ "$(jq -r .reason <<< "$output")" = not_idle ]
    [ "$(jq -r .result <<< "$output")" = kept ]
    [ "$(grep -c '^pane list$' "$CALLS")" -eq 2 ]
    no_close
}

@test "close タブに他のペインがあれば残す" {
    panes_edit '.result.panes += [{pane_id:"w3:p3",tab_id:"w3:t2",workspace_id:"w3",agent_status:"unknown"}]'
    closable close w3:p2
    [ "$(jq -r .reason <<< "$output")" = shared_tab ]
    no_close
}

@test "close ワークスペースの最後のタブは閉じない" {
    panes_edit '.result.panes[0].workspace_id = "w9"'
    closable close w3:p2
    [ "$(jq -r .reason <<< "$output")" = last_tab ]
    no_close
}

@test "close 同じタブのペインが複数でもタブ数は一つと数える" {
    panes_edit '.result.panes[0].tab_id = "w3:t2"'
    closable close w3:p2
    [ "$(jq -r .reason <<< "$output")" = shared_tab ]
    no_close
}

@test "close ペインが見つからなければ not_found で残す" {
    closable close w3:p9
    [ "$output" = '{"pane":"w3:p9","result":"kept","reason":"not_found"}' ]
    no_close
}

@test "close ペインごとに一覧を取り直して最後のタブを残す" {
    panes_edit '.result.panes[0] |= (.pane_id = "w3:p3" | .agent_status = "idle")'
    closable close w3:p2 w3:p3
    [ "${#lines[@]}" -eq 2 ]
    [ "$(jq -sr '.[0].result' <<< "$output")" = closed ]
    [ "$(jq -sr '.[1].reason' <<< "$output")" = last_tab ]
    [ "$(grep -c '^pane list$' "$CALLS")" -eq 2 ]
    [ "$(grep -c '^pane current --current$' "$CALLS")" -eq 2 ]
    [ "$(grep -c '^tab close ' "$CALLS")" -eq 1 ]
}

@test "close 一覧の取得に失敗したらペインごとに error で残す" {
    FAKE_LIST_FAIL=1 closable close w3:p2 w3:p3
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = '{"pane":"w3:p2","result":"kept","reason":"error"}' ]
    [ "${lines[1]}" = '{"pane":"w3:p3","result":"kept","reason":"error"}' ]
    no_close
}

@test "close タブの終了に失敗したら error を返す" {
    FAKE_CLOSE_FAIL=1 closable close w3:p2
    [ "$output" = '{"pane":"w3:p2","result":"kept","reason":"error"}' ]
    grep -qx 'tab close w3:t2' "$CALLS"
}

@test "close タブの終了がタイムアウトしたら error を返す" {
    export REAL_TIMEOUT
    REAL_TIMEOUT="$(command -v timeout)"
    cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
if [[ "$2 $3 $4" == "herdr tab close" ]]; then
    exit 124
fi
exec "$REAL_TIMEOUT" "$@"
EOF
    chmod +x "$BIN/timeout"
    closable close w3:p2
    [ "$output" = '{"pane":"w3:p2","result":"kept","reason":"error"}' ]
    no_close
}

@test "close jq でペインを読めなければ error を返す" {
    panes_edit '.result.panes[1].agent_session = 42'
    closable close w3:p2
    [ "$output" = '{"pane":"w3:p2","result":"kept","reason":"error"}' ]
    no_close
}

@test "close 一覧が壊れていれば閉じずに error を返す" {
    echo '{"result":{}}' > "$PANES"
    closable close w3:p2
    [ "$output" = '{"pane":"w3:p2","result":"kept","reason":"error"}' ]
    no_close
}

@test "close 現在のペインが取得できなければ error を返す" {
    FAKE_NO_CURRENT=1 closable close w3:p2
    [ "$output" = '{"pane":"w3:p2","result":"kept","reason":"error"}' ]
    no_close
}
