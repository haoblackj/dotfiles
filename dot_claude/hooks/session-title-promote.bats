#!/usr/bin/env bats
# session-title-promote.sh のユニットテスト。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_session-title-promote.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    TRANSCRIPT="$TMPDIR_TEST/transcript.jsonl"
    : > "$TRANSCRIPT"
    export FAKE_CLAUDE_ARGS="$TMPDIR_TEST/claude-args"
    # 偽の claude（Haiku）。本物は 1 回 2〜5 秒かかり、push のたびに利用枠を使う。
    # 受け取った引数を 1 行ずつ FAKE_CLAUDE_ARGS へ書き、FAKE_CLAUDE_NAME を名前として返す。
    # FAKE_CLAUDE_HANG があれば答えずに固まる。exec で置き換えるので、timeout が止めた後に
    # sleep が出力の管を持ち続けない。
    mkdir -p "$TMPDIR_TEST/bin"
    cat > "$TMPDIR_TEST/bin/claude" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGS"
[ -n "${FAKE_CLAUDE_HANG:-}" ] && exec sleep 30
jq -nc --arg n "${FAKE_CLAUDE_NAME-短い名前}" '{structured_output:{name:$n}}'
FAKE
    chmod +x "$TMPDIR_TEST/bin/claude"
    export PATH="$TMPDIR_TEST/bin:$PATH"
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

@test "Haikuには「#数字」と「引き継ぎ」を禁じたスキーマを渡し、それを含む答えは使わない" {
    add_ai_title "タブ名の付け方"
    FAKE_CLAUDE_NAME="issue #91 の引き継ぎ" run bash "$SCRIPT" <<< "$(ups_input sess-u12)"
    [ "$status" -eq 0 ]
    [ "$(title_of "$output")" = "タブ名の付け方" ]
    grep -qF -- '--json-schema' "$FAKE_CLAUDE_ARGS"
    grep -qF '(?!.*引き継ぎ)(?!.*#[0-9])' "$FAKE_CLAUDE_ARGS"
}

@test "Haikuの答えが20文字を超える -> 答えを使わず元の題を出す" {
    add_ai_title "元の題"
    FAKE_CLAUDE_NAME="一二三四五六七八九十一二三四五六七八九十一" run bash "$SCRIPT" <<< "$(ups_input sess-u13)"
    [ "$status" -eq 0 ]
    [ "$(title_of "$output")" = "元の題" ]
}

title_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.sessionTitle'; }

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

@test "UserPromptSubmitでai-titleが複数 -> 最後のaiTitleをHaikuで縮めてsessionTitleとして出し、印を置く" {
    add_ai_title "猫の写真フォルダの整理"
    add_ai_title "専用の Ubuntu 推論サーバーの構築と性能測定"
    run bash "$SCRIPT" <<< "$(ups_input sess-u1)"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "UserPromptSubmit" ]
    [ "$(title_of "$output")" = "短い名前" ]
    grep -qF "題: 専用の Ubuntu 推論サーバーの構築と性能測定" "$FAKE_CLAUDE_ARGS"
    ! grep -qF "猫" "$FAKE_CLAUDE_ARGS" || false
    grep -qxF -- "haiku" "$FAKE_CLAUDE_ARGS"
    marked sess-u1
}

@test "Haikuの答えがちょうど20文字 -> その名前を出す" {
    add_ai_title "AGENTS.md (画像生成) の複数ホスト対応"
    FAKE_CLAUDE_NAME="一二三四五六七八九十一二三四五六七八九十" run bash "$SCRIPT" <<< "$(ups_input sess-u9)"
    [ "$status" -eq 0 ]
    [ "$(title_of "$output")" = "一二三四五六七八九十一二三四五六七八九十" ]
}

@test "Haikuが時間内に答えない -> ai-titleをそのまま出す" {
    add_ai_title "AGENTS.md (画像生成) の複数ホスト対応"
    FAKE_CLAUDE_HANG=1 CLAUDE_TITLE_SHORTEN_TIMEOUT=0.1 run bash "$SCRIPT" <<< "$(ups_input sess-u10)"
    [ "$status" -eq 0 ]
    [ "$(title_of "$output")" = "AGENTS.md (画像生成) の複数ホスト対応" ]
    marked sess-u10
}

@test "子のclaudeの中（CLAUDE_TITLE_SHORTEN_CHILDあり） -> 何も出さず、印も置かない" {
    add_ai_title "タイトル"
    CLAUDE_TITLE_SHORTEN_CHILD=1 run bash "$SCRIPT" <<< "$(ups_input sess-u11)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-u11 || false
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
    [ "$(title_of "$output")" = "短い名前" ]
    grep -qF "題: 正しいタイトル" "$FAKE_CLAUDE_ARGS"
}

@test "タイトルと名前に引用符やバックスラッシュ -> Haikuへそのまま渡り、出力が妥当なJSONで名前が入る" {
    add_ai_title 'say "hi" \ 日本語'
    FAKE_CLAUDE_NAME='say "hi" \ 日' run bash "$SCRIPT" <<< "$(ups_input sess-u7)"
    [ "$status" -eq 0 ]
    [ "$(title_of "$output")" = 'say "hi" \ 日' ]
    grep -qF '題: say "hi" \ 日本語' "$FAKE_CLAUDE_ARGS"
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

@test "clear後の最初のプロンプト -> 引き継いだcustom-titleを無視し、プロンプトからHaikuで題を作って印を置く" {
    jq -nc '{type:"custom-title",customTitle:"引き継いだ名前",sessionId:"sess"}' >> "$TRANSCRIPT"
    bash "$SCRIPT" <<< "$(ss_clear_input sess-c2)"
    run bash "$SCRIPT" <<< "$(ups_input sess-c2 "$TRANSCRIPT" "Issue12に取り掛かろう")"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "UserPromptSubmit" ]
    [ "$(title_of "$output")" = "短い名前" ]
    grep -qF "最初の発言: Issue12に取り掛かろう" "$FAKE_CLAUDE_ARGS"
    ! grep -qF "引き継いだ名前" "$FAKE_CLAUDE_ARGS" || false
    marked sess-c2
}

@test "clear後の題 -> Haikuが時間内に答えなければ、最初の空でない行を、空白を詰めて先頭30文字に切る" {
    bash "$SCRIPT" <<< "$(ss_clear_input sess-c3)"
    prompt=$'\n   \n  あいうえお   かきくけこ\tさしすせそたちつてとなにぬねのはひふへほ\n二行目'
    FAKE_CLAUDE_HANG=1 CLAUDE_TITLE_SHORTEN_TIMEOUT=0.1 run bash "$SCRIPT" <<< "$(ups_input sess-c3 "$TRANSCRIPT" "$prompt")"
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
