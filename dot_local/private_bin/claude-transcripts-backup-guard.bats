#!/usr/bin/env bats
# claude-transcripts-backup-guard のユニットテスト。本物の restic、systemctl と D ドライブは使わない。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_claude-transcripts-backup-guard"
    TMPDIR_TEST="$(mktemp -d)"
    STATE="$TMPDIR_TEST/state"
    export CLAUDE_TRANSCRIPTS_BACKUP_STATE="$STATE"
    export CLAUDE_TRANSCRIPTS_RESTORE_TARGET="$TMPDIR_TEST/target"
    MOUNT="$TMPDIR_TEST/d"
    REPO="$MOUNT/claude-transcripts-backup/restic"
    PW="$TMPDIR_TEST/pw"
    mkdir -p "$REPO"
    : > "$REPO/config"
    echo secret > "$PW"
    export PROFILE_COMMAND=backup

    # 偽の restic。引数を記録し、snapshots には FAKE_SNAPSHOTS を返す
    FAKE_BIN="$TMPDIR_TEST/fakebin"
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/restic" <<'EOS'
#!/bin/bash
echo "$*" >> "$RESTIC_LOG"
case " $* " in
  *" snapshots "*) echo "${FAKE_SNAPSHOTS:-[]}"; exit "${FAKE_SNAPSHOTS_EXIT:-0}" ;;
  *" restore "*) exit "${FAKE_RESTORE_EXIT:-0}" ;;
esac
EOS
    chmod +x "$FAKE_BIN/restic"
    export PATH="$FAKE_BIN:$PATH"
    export RESTIC_LOG="$TMPDIR_TEST/restic.log"
    : > "$RESTIC_LOG"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

failure() {
    cat "$STATE/failure-$1"
}

@test "check: D に届かなければ失敗し、環境の失敗として書く" {
    run "$SCRIPT" check "$TMPDIR_TEST/missing" "$REPO" "$PW"
    [ "$status" -ne 0 ]
    [[ "$(failure env)" == *"D ドライブに届かない"* ]]
}

@test "check: 退避先のリポジトリが無ければ失敗し、新しく作らない" {
    rm -- "$REPO/config"
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -ne 0 ]
    [[ "$(failure env)" == *"退避先のリポジトリが無い"* ]]
    [ ! -s "$RESTIC_LOG" ]
}

@test "check: 未復元なら最新の世代を上書きせずに戻し、印を付ける" {
    export FAKE_SNAPSHOTS='[{"id":"abc"}]'
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -eq 0 ]
    grep -q "restore latest --target $CLAUDE_TRANSCRIPTS_RESTORE_TARGET --overwrite never" "$RESTIC_LOG"
    [ -e "$STATE/restored" ]
}

@test "check: 復元に失敗したら印を付けずに、backup の失敗として書く" {
    export FAKE_SNAPSHOTS='[{"id":"abc"}]' FAKE_RESTORE_EXIT=1
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -ne 0 ]
    [[ "$(failure backup)" == *"復元に失敗"* ]]
    [ ! -e "$STATE/restored" ]
}

@test "fail: restic が失敗したら、そのコマンドの失敗として終了コードつきで書く" {
    PROFILE_COMMAND=check ERROR_MESSAGE="check on profile 'claude-transcripts': exit status 1" ERROR_EXIT_CODE=1 \
        run "$SCRIPT" fail
    [ "$status" -eq 0 ]
    [[ "$(failure check)" == *"restic check が失敗（終了コード 1）"* ]]
}

@test "systemd-fail: その回に理由が書かれていなければ、ユニットの失敗として書く" {
    CLAUDE_TRANSCRIPTS_UNIT_STARTED=$(date +%s)
    export CLAUDE_TRANSCRIPTS_UNIT_STARTED
    run "$SCRIPT" systemd-fail resticprofile-backup
    [ "$status" -eq 0 ]
    [[ "$(failure backup)" == *"backup のユニットが失敗"* ]]
}

