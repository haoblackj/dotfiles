#!/usr/bin/env bats
# gh-bot-token.sh のユニットテスト。本物の gh-token、age、GitHub は呼ばない。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_gh-bot-token.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    export XDG_RUNTIME_DIR="$TMPDIR_TEST/run"
    mkdir -p "$XDG_RUNTIME_DIR"
    CACHE="$XDG_RUNTIME_DIR/claude-gh-bot"

    # 偽の token 発行。呼ばれた回数を数える。
    FAKE_BIN="$TMPDIR_TEST/fakebin"
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/mint" <<'EOS'
#!/bin/bash
echo x >> "$MINT_LOG"
[ "${FAKE_MINT_FAIL:-0}" = 1 ] && exit 1
printf 'ghs_fake%s\n' "$(wc -l < "$MINT_LOG")"
EOS
    chmod +x "$FAKE_BIN/mint"
    export CLAUDE_GH_BOT_MINT_CMD="$FAKE_BIN/mint"
    export MINT_LOG="$TMPDIR_TEST/mint.log"
    : > "$MINT_LOG"

    # 前提のファイル（鍵と age の identity）は、置き場の検査だけに使う
    export CLAUDE_GH_BOT_KEY="$TMPDIR_TEST/key.age" CLAUDE_GH_BOT_AGE_IDENTITY="$TMPDIR_TEST/key.txt"
    : > "$CLAUDE_GH_BOT_KEY"; : > "$CLAUDE_GH_BOT_AGE_IDENTITY"

    export CLAUDE_ENV_FILE="$TMPDIR_TEST/env.sh"
    : > "$CLAUDE_ENV_FILE"
    unset FAKE_MINT_FAIL GH_TOKEN
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

@test "session: 追記した行を source すると GH_TOKEN に bot の token が入る" {
    run "$SCRIPT" session
    run bash -c ". \"$CLAUDE_ENV_FILE\"; printf '%s' \"\${GH_TOKEN:-}\""
    [ "$output" = ghs_fake1 ]
}

@test "token: 50分を過ぎた token は作り直す" {
    run "$SCRIPT" token
    touch -d '-51 minutes' "$CACHE/token"
    run "$SCRIPT" token
    [ "$output" = ghs_fake2 ]
}

@test "token: 置き場は 700、token は 600" {
    run "$SCRIPT" token
    [ "$(stat -c %a "$CACHE")" = 700 ]
    [ "$(stat -c %a "$CACHE/token")" = 600 ]
}

@test "token: 置き場がシンボリックリンクなら使わずに失敗する" {
    mkdir -p "$TMPDIR_TEST/elsewhere"
    ln -s "$TMPDIR_TEST/elsewhere" "$CACHE"
    run "$SCRIPT" token
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$TMPDIR_TEST/elsewhere")" ]
}

@test "token: XDG_RUNTIME_DIR が無ければ /tmp ではなくホームの下を使う" {
    unset XDG_RUNTIME_DIR
    export HOME="$TMPDIR_TEST/home"
    mkdir -p "$HOME"
    run "$SCRIPT" token
    [ "$output" = ghs_fake1 ]
    [ -f "$HOME/.cache/claude-gh-bot/token" ]
}
