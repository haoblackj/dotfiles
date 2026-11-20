#!/usr/bin/env bats
# settings-symlink-guard.sh のユニットテスト。本物の ~/.claude/settings.json とソースは使わない。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_settings-symlink-guard.sh"
    T="$(mktemp -d)"
    mkdir -p "$T/src/linked/claude" "$T/home/.claude"
    echo '{}' > "$T/src/linked/claude/settings.json"
    export SETTINGS_SYMLINK_GUARD_TARGET="$T/home/.claude/settings.json"
    export SETTINGS_SYMLINK_GUARD_EXPECTED="$T/src/linked/claude/settings.json"
    unset CLAUDE_CODE_REMOTE
}

teardown() {
    rm -rf -- "$T"
}

# 出力が JSON で、画面向けと Claude 向けの両方に、壊れ方の語が入っていることを確かめる
assert_warns() {
    local word="$1"
    python3 -I - "$output" "$word" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); word = sys.argv[2]
msg = d["systemMessage"]
ctx = d["hookSpecificOutput"]["additionalContext"]
assert d["hookSpecificOutput"]["hookEventName"] == "SessionStart"
assert word in msg, msg
assert word in ctx, ctx
assert "docs/work/settings-symlink.md" in ctx, ctx
PY
}

@test "正しい symlink なら何も出さない" {
    ln -s "$SETTINGS_SYMLINK_GUARD_EXPECTED" "$SETTINGS_SYMLINK_GUARD_TARGET"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "相対パスでも、たどった先が正しければ何も出さない" {
    ln -s "../../src/linked/claude/settings.json" "$SETTINGS_SYMLINK_GUARD_TARGET"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "通常のファイルなら知らせる" {
    echo '{}' > "$SETTINGS_SYMLINK_GUARD_TARGET"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_warns "通常のファイル"
}

@test "別の場所への symlink なら知らせる" {
    echo '{}' > "$T/other.json"
    ln -s "$T/other.json" "$SETTINGS_SYMLINK_GUARD_TARGET"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_warns "別の場所"
}

@test "リンク先が無い symlink なら知らせる" {
    ln -s "$T/missing.json" "$SETTINGS_SYMLINK_GUARD_TARGET"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_warns "リンク先が無い"
}

@test "ファイルが無ければ知らせる" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_warns "無い"
}

@test "クラウドのセッションでは通常のファイルでも黙る" {
    echo '{}' > "$SETTINGS_SYMLINK_GUARD_TARGET"
    CLAUDE_CODE_REMOTE=true run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "知らせるときも対象のファイルを書き換えない" {
    echo '{"a":1}' > "$SETTINGS_SYMLINK_GUARD_TARGET"
    before="$(stat -c '%i %Y %s' "$SETTINGS_SYMLINK_GUARD_TARGET")"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(stat -c '%i %Y %s' "$SETTINGS_SYMLINK_GUARD_TARGET")" = "$before" ]
    [ ! -L "$SETTINGS_SYMLINK_GUARD_TARGET" ]
}
