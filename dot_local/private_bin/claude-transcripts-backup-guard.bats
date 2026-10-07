#!/usr/bin/env bats
# claude-transcripts-backup-guard のユニットテスト。本物の restic と D ドライブは使わない。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_claude-transcripts-backup-guard"
    TMPDIR_TEST="$(mktemp -d)"
    export CLAUDE_TRANSCRIPTS_BACKUP_STATE="$TMPDIR_TEST/state"
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
    cat "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/failure"
}

@test "check: D に届かなければ失敗し、理由を書く" {
    run "$SCRIPT" check "$TMPDIR_TEST/missing" "$REPO" "$PW"
    [ "$status" -ne 0 ]
    [[ "$(failure)" == *"D ドライブに届かない"* ]]
}

@test "check: 退避先のリポジトリが無ければ失敗し、新しく作らない" {
    rm -- "$REPO/config"
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -ne 0 ]
    [[ "$(failure)" == *"退避先のリポジトリが無い"* ]]
    [ ! -s "$RESTIC_LOG" ]
}

@test "check: パスワードが無ければ失敗する" {
    run "$SCRIPT" check "$MOUNT" "$REPO" "$TMPDIR_TEST/no-pw"
    [ "$status" -ne 0 ]
    [[ "$(failure)" == *"パスワードが無い"* ]]
}

@test "check: 未復元なら最新の世代を上書きせずに戻し、印を付ける" {
    export FAKE_SNAPSHOTS='[{"id":"abc"}]'
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -eq 0 ]
    grep -q "restore latest --target $CLAUDE_TRANSCRIPTS_RESTORE_TARGET --overwrite never" "$RESTIC_LOG"
    [ -e "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/restored" ]
}

@test "check: 世代が一つも無ければ戻さずに印だけ付ける" {
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -eq 0 ]
    run grep -q " restore " "$RESTIC_LOG"
    [ "$status" -ne 0 ]
    [ -e "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/restored" ]
}

@test "check: 復元に失敗したら印を付けずに失敗する" {
    export FAKE_SNAPSHOTS='[{"id":"abc"}]' FAKE_RESTORE_EXIT=1
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -ne 0 ]
    [[ "$(failure)" == *"復元に失敗"* ]]
    [ ! -e "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/restored" ]
}

@test "check: 復元済みなら restic を呼ばない" {
    mkdir -p "$CLAUDE_TRANSCRIPTS_BACKUP_STATE"
    touch "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/restored"
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -eq 0 ]
    [ ! -s "$RESTIC_LOG" ]
}

@test "check: forget の前では戻さない" {
    export PROFILE_COMMAND=forget FAKE_SNAPSHOTS='[{"id":"abc"}]'
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -eq 0 ]
    [ ! -s "$RESTIC_LOG" ]
    [ ! -e "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/restored" ]
}

@test "ok: 失敗の理由を消し、成功の時刻を残す" {
    mkdir -p "$CLAUDE_TRANSCRIPTS_BACKUP_STATE"
    echo "前の失敗" > "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/failure"
    run "$SCRIPT" ok
    [ "$status" -eq 0 ]
    [ ! -s "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/failure" ]
    [ -e "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/last-success" ]
}

@test "fail: restic が失敗したら終了コードつきで書く" {
    ERROR_MESSAGE="backup on profile 'claude-transcripts': exit status 10" ERROR_EXIT_CODE=10 \
        run "$SCRIPT" fail
    [ "$status" -eq 0 ]
    [[ "$(failure)" == *"restic backup が失敗（終了コード 10）"* ]]
}

@test "fail: run-before の失敗では、確認が書いた理由を残す" {
    mkdir -p "$CLAUDE_TRANSCRIPTS_BACKUP_STATE"
    echo "D ドライブに届かない" > "$CLAUDE_TRANSCRIPTS_BACKUP_STATE/failure"
    ERROR_MESSAGE="run-before backup on profile 'claude-transcripts': exit status 1" ERROR_EXIT_CODE=1 \
        run "$SCRIPT" fail
    [ "$status" -eq 0 ]
    [ "$(failure)" = "D ドライブに届かない" ]
}
