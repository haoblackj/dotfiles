#!/usr/bin/env bats
# codexbar-serve-refresh のユニットテスト。本物の serve、codexbar、systemctl は呼ばない。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_codexbar-serve-refresh"
    TMPDIR_TEST="$(mktemp -d)"
    HEALTH="$TMPDIR_TEST/health.json"
    export CODEXBAR_HEALTH_URL="file://$HEALTH"

    # 偽の codexbar（--version に FAKE_INSTALLED を返す）と systemctl（引数を記録する）
    FAKE_BIN="$TMPDIR_TEST/fakebin"
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/codexbar" <<'EOS'
#!/bin/bash
[ "$1" = --version ] && [ -n "${FAKE_INSTALLED:-}" ] && echo "CodexBar $FAKE_INSTALLED"
EOS
    cat > "$FAKE_BIN/systemctl" <<'EOS'
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
EOS
    chmod +x "$FAKE_BIN/codexbar" "$FAKE_BIN/systemctl"
    export PATH="$FAKE_BIN:$PATH"
    export SYSTEMCTL_LOG="$TMPDIR_TEST/systemctl.log"
    : > "$SYSTEMCTL_LOG"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

health() { printf '{"status":"ok","version":"%s"}' "$1" > "$HEALTH"; }

@test "動いている版と入っている版が同じ -> 再起動しない" {
    health 0.70.0
    export FAKE_INSTALLED=0.70.0
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "版が違う -> codexbar-serve を再起動する" {
    health 0.70.0
    export FAKE_INSTALLED=0.71.0
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$SYSTEMCTL_LOG")" = "--user restart codexbar-serve" ]
    [[ "$output" == *"0.70.0"*"0.71.0"* ]]
}

@test "serve が応答しない -> 何もしない" {
    export CODEXBAR_HEALTH_URL="http://127.0.0.1:1/health"
    export FAKE_INSTALLED=0.71.0
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "/health に version が無い -> 何もしない" {
    printf '{"status":"ok"}' > "$HEALTH"
    export FAKE_INSTALLED=0.71.0
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}

@test "codexbar --version が読めない -> 何もしない" {
    health 0.70.0
    unset FAKE_INSTALLED
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$SYSTEMCTL_LOG" ]
}
