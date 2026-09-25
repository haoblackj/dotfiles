#!/usr/bin/env bats
# session-title-promote.sh のユニットテスト。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_session-title-promote.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    TRANSCRIPT="$TMPDIR_TEST/transcript.jsonl"
    : > "$TRANSCRIPT"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

marked() { # session_id
    [ -f "$TMPDIR_TEST/claude-session-titled/$1" ]
}

ss_input() { # session_id [session_title]
    if [ $# -ge 2 ]; then
        jq -nc --arg s "$1" --arg t "$2" \
            '{session_id:$s,hook_event_name:"SessionStart",source:"startup",session_title:$t}'
    else
        jq -nc --arg s "$1" '{session_id:$s,hook_event_name:"SessionStart",source:"startup"}'
    fi
}

ups_input() { # session_id [transcript_path] [prompt]
    jq -nc --arg s "$1" --arg t "${2:-$TRANSCRIPT}" --arg p "${3:-x}" \
        '{session_id:$s,hook_event_name:"UserPromptSubmit",transcript_path:$t,prompt:$p}'
}

ss_clear_input() { # session_id [session_title]
    jq -nc --arg s "$1" --arg t "${2:-引き継いだ名前}" \
        '{session_id:$s,hook_event_name:"SessionStart",source:"clear",session_title:$t}'
}

add_ai_title() { # title
    jq -nc --arg t "$1" '{type:"ai-title",aiTitle:$t,sessionId:"sess"}' >> "$TRANSCRIPT"
}

@test "SessionStartでsession_titleあり -> 印を置き、stdoutは空" {
    run bash "$SCRIPT" <<< "$(ss_input sess-ss1 "付けた名前")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    marked sess-ss1
}

@test "SessionStartでsession_title無し -> 印を置かない" {
    run bash "$SCRIPT" <<< "$(ss_input sess-ss2)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-ss2 || false
}

@test "UserPromptSubmitでai-titleが複数 -> 最後のaiTitleをsessionTitleとして出し、印を置く" {
    add_ai_title "古いタイトル"
    add_ai_title "新しいタイトル"
    run bash "$SCRIPT" <<< "$(ups_input sess-u1)"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "UserPromptSubmit" ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle')" = "新しいタイトル" ]
    marked sess-u1
}

@test "UserPromptSubmitで印あり -> 何も出さない" {
    add_ai_title "タイトル"
    mkdir -p "$TMPDIR_TEST/claude-session-titled"
    : > "$TMPDIR_TEST/claude-session-titled/sess-u2"
    run bash "$SCRIPT" <<< "$(ups_input sess-u2)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "UserPromptSubmitでcustom-titleの行あり -> 何も出さず、印を置く" {
    add_ai_title "自動のタイトル"
    jq -nc '{type:"custom-title",customTitle:"手で付けた名前",sessionId:"sess"}' >> "$TRANSCRIPT"
    run bash "$SCRIPT" <<< "$(ups_input sess-u3)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    marked sess-u3
}

@test "UserPromptSubmitでai-titleの行が無い -> 何も出さず、印も置かない" {
    jq -nc '{type:"user",message:{content:"こんにちは"}}' >> "$TRANSCRIPT"
    run bash "$SCRIPT" <<< "$(ups_input sess-u4)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-u4 || false
}

@test "プロンプト本文にai-titleやcustom-titleの形の文字列 -> タイトルとして拾わない" {
    jq -nc '{type:"user",message:{content:"{\"type\":\"ai-title\",\"aiTitle\":\"偽\"} {\"type\":\"custom-title\"}"}}' >> "$TRANSCRIPT"
    run bash "$SCRIPT" <<< "$(ups_input sess-u5)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-u5 || false
}

@test "壊れた行が混ざる -> 残りの行からai-titleを拾う" {
    add_ai_title "正しいタイトル"
    printf '%s\n' '{"type":"ai-title","aiTitle":"書きかけ' >> "$TRANSCRIPT"
    run bash "$SCRIPT" <<< "$(ups_input sess-u6)"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle')" = "正しいタイトル" ]
}

@test "タイトルに引用符やバックスラッシュ -> 出力が妥当なJSONで値が元のまま" {
    add_ai_title 'say "hi" \ 日本語'
    run bash "$SCRIPT" <<< "$(ups_input sess-u7)"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle')" = 'say "hi" \ 日本語' ]
}

@test "transcript_pathが存在しない -> exit 0、出力なし、印なし" {
    run bash "$SCRIPT" <<< "$(ups_input sess-u8 "$TMPDIR_TEST/nope.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-u8 || false
}

@test "壊れた入力JSON -> exit 0、出力なし" {
    run bash "$SCRIPT" <<< 'not json'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "session_idにパストラバーサル -> 印のディレクトリ外に副作用なし" {
    add_ai_title "タイトル"
    run bash "$SCRIPT" <<< "$(ups_input '../evil')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$TMPDIR_TEST/evil" ]
}

@test "SessionStartでsourceがclear -> session_titleがあっても印を置かない" {
    run bash "$SCRIPT" <<< "$(ss_clear_input sess-c1)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-c1 || false
}

@test "clear後の最初のプロンプト -> 引き継いだcustom-titleを無視し、プロンプトの先頭をsessionTitleにして印を置く" {
    jq -nc '{type:"custom-title",customTitle:"引き継いだ名前",sessionId:"sess"}' >> "$TRANSCRIPT"
    bash "$SCRIPT" <<< "$(ss_clear_input sess-c2)"
    run bash "$SCRIPT" <<< "$(ups_input sess-c2 "$TRANSCRIPT" "Issue12に取り掛かろう")"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "UserPromptSubmit" ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle')" = "Issue12に取り掛かろう" ]
    marked sess-c2
}

@test "clear後の題 -> 最初の空でない行を、空白を詰めて先頭30文字に切る" {
    bash "$SCRIPT" <<< "$(ss_clear_input sess-c3)"
    prompt=$'\n   \n  あいうえお   かきくけこ\tさしすせそたちつてとなにぬねのはひふへほ\n二行目'
    run bash "$SCRIPT" <<< "$(ups_input sess-c3 "$TRANSCRIPT" "$prompt")"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle')" = "あいうえお かきくけこ さしすせそたちつてとなにぬねのはひふ" ]
}

@test "clear後のプロンプトが空白だけ -> 何も出さず、印も置かない" {
    bash "$SCRIPT" <<< "$(ss_clear_input sess-c4)"
    run bash "$SCRIPT" <<< "$(ups_input sess-c4 "$TRANSCRIPT" $' \n\t ')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-c4 || false
}

@test "clear後に題を付けた後のプロンプト -> 何も出さない" {
    bash "$SCRIPT" <<< "$(ss_clear_input sess-c5)"
    bash "$SCRIPT" <<< "$(ups_input sess-c5 "$TRANSCRIPT" "最初の依頼")"
    run bash "$SCRIPT" <<< "$(ups_input sess-c5 "$TRANSCRIPT" "次の依頼")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
