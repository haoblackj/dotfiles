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

@test "版が違う -> codexbar-serve を再起動する" {
    health 0.70.0
    export FAKE_INSTALLED=0.71.0
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$SYSTEMCTL_LOG")" = "--user restart codexbar-serve" ]
    [[ "$output" == *"0.70.0"*"0.71.0"* ]]
}

