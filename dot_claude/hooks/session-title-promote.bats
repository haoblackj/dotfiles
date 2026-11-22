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
    mkdir -p "$TMPDIR_TEST/bin"
    cat > "$TMPDIR_TEST/bin/claude" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGS"
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

ups_input() { # session_id [transcript_path] [prompt]
    jq -nc --arg s "$1" --arg t "${2:-$TRANSCRIPT}" --arg p "${3:-x}" \
        '{session_id:$s,hook_event_name:"UserPromptSubmit",transcript_path:$t,prompt:$p}'
}

@test "Haikuには「#数字」と「引き継ぎ」を禁じたスキーマを渡し、それを含む答えは使わない" {
    add_ai_title "タブ名の付け方"
    FAKE_CLAUDE_NAME="issue #91 の引き継ぎ" run bash "$SCRIPT" <<< "$(ups_input sess-u12)"
    [ "$status" -eq 0 ]
    [ "$(title_of "$output")" = "タブ名の付け方" ]
    grep -qF -- '--json-schema' "$FAKE_CLAUDE_ARGS"
    grep -qF '(?!.*引き継ぎ)(?!.*#[0-9])' "$FAKE_CLAUDE_ARGS"
}

title_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.sessionTitle'; }

add_ai_title() { # title
    jq -nc --arg t "$1" '{type:"ai-title",aiTitle:$t,sessionId:"sess"}' >> "$TRANSCRIPT"
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
    # 子の claude はフックを読まない設定で立てる（読むとこのフックが子の中で繰り返し動く）。
    grep -A1 -xF -- "--setting-sources" "$FAKE_CLAUDE_ARGS" | sed -n 2p | grep -qx ''
    marked sess-u1
}

