#!/usr/bin/env bats
# mutation-target: dot_claude/compact-plus-backend/executable_backend-codex-mini.sh
# backend-codex-mini.sh のユニットテスト。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_backend-codex-mini.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    mkdir -p "$TMPDIR_TEST/claude-compact-state"

    # 偽codexを作りPATHへ前置する。実APIを叩かない。
    CODEX_BIN="$TMPDIR_TEST/codex"
    cat > "$CODEX_BIN" <<'CODEX_SCRIPT'
#!/bin/bash
# Fake codex that outputs a canned compact-prep state
cat <<'STATE'
# Compact Prep State

This is a test output from fake codex.
STATE
CODEX_SCRIPT
    chmod +x "$CODEX_BIN"
    export PATH="$TMPDIR_TEST:$PATH"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

@test "fresh manual marker -> codexを呼ばず既存stateがecho" {
    SID="okid"
    printf '# Compact Prep State\nKEEP-MANUAL\n' > "$TMPDIR_TEST/claude-compact-state/$SID.md"
    touch "$TMPDIR_TEST/claude-compact-state/$SID.manual"
    run env SESSION_ID="$SID" SYSTEM_PROMPT="test" bash "$SCRIPT" <<< "prompt"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "KEEP-MANUAL"
}

@test "対象スクリプトにgpt-5.4-miniとsedパターンが埋め込まれている" {
    grep -q 'gpt-5.4-mini' "$SCRIPT"
    grep -q "sed -n '/^# Compact Prep State/,\$p'" "$SCRIPT"
}

@test "session_idにパストラバーサル文字列 -> /tmp/evilに副作用なし" {
    run env SESSION_ID='../../evil' SYSTEM_PROMPT="test" bash "$SCRIPT" <<< "test"
    [ ! -e /tmp/evil ]
}
