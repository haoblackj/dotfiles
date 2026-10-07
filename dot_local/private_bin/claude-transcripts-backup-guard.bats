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

@test "check: パスワードが無ければ失敗する" {
    run "$SCRIPT" check "$MOUNT" "$REPO" "$TMPDIR_TEST/no-pw"
    [ "$status" -ne 0 ]
    [[ "$(failure env)" == *"パスワードが無い"* ]]
}

@test "check: 環境が揃えば、前の環境の失敗を消す" {
    mkdir -p "$STATE"
    touch "$STATE/restored"
    echo "D ドライブに届かない" > "$STATE/failure-env"
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -eq 0 ]
    [ ! -s "$STATE/failure-env" ]
}

@test "check: 未復元なら最新の世代を上書きせずに戻し、印を付ける" {
    export FAKE_SNAPSHOTS='[{"id":"abc"}]'
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -eq 0 ]
    grep -q "restore latest --target $CLAUDE_TRANSCRIPTS_RESTORE_TARGET --overwrite never" "$RESTIC_LOG"
    [ -e "$STATE/restored" ]
}

@test "check: 世代が一つも無ければ戻さずに印だけ付ける" {
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -eq 0 ]
    run grep -q " restore " "$RESTIC_LOG"
    [ "$status" -ne 0 ]
    [ -e "$STATE/restored" ]
}

@test "check: 復元に失敗したら印を付けずに、backup の失敗として書く" {
    export FAKE_SNAPSHOTS='[{"id":"abc"}]' FAKE_RESTORE_EXIT=1
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -ne 0 ]
    [[ "$(failure backup)" == *"復元に失敗"* ]]
    [ ! -e "$STATE/restored" ]
}

@test "check: 復元済みなら restic を呼ばない" {
    mkdir -p "$STATE"
    touch "$STATE/restored"
    run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
    [ "$status" -eq 0 ]
    [ ! -s "$RESTIC_LOG" ]
}

@test "check: backup 以外の前では戻さない" {
    export FAKE_SNAPSHOTS='[{"id":"abc"}]'
    for cmd in forget check; do
        PROFILE_COMMAND=$cmd run "$SCRIPT" check "$MOUNT" "$REPO" "$PW"
        [ "$status" -eq 0 ]
    done
    [ ! -s "$RESTIC_LOG" ]
    [ ! -e "$STATE/restored" ]
}

@test "ok: backup の成功は backup の失敗だけを消し、成功の時刻を残す" {
    mkdir -p "$STATE"
    echo "前の失敗" > "$STATE/failure-backup"
    echo "壊れている" > "$STATE/failure-check"
    run "$SCRIPT" ok
    [ "$status" -eq 0 ]
    [ ! -s "$STATE/failure-backup" ]
    [ "$(failure check)" = "壊れている" ]
    [ -e "$STATE/last-success" ]
}

@test "ok: check の成功は check の失敗を消し、成功の時刻は動かさない" {
    mkdir -p "$STATE"
    echo "壊れている" > "$STATE/failure-check"
    PROFILE_COMMAND=check run "$SCRIPT" ok
    [ "$status" -eq 0 ]
    [ ! -s "$STATE/failure-check" ]
    [ ! -e "$STATE/last-success" ]
}

@test "fail: restic が失敗したら、そのコマンドの失敗として終了コードつきで書く" {
    PROFILE_COMMAND=check ERROR_MESSAGE="check on profile 'claude-transcripts': exit status 1" ERROR_EXIT_CODE=1 \
        run "$SCRIPT" fail
    [ "$status" -eq 0 ]
    [[ "$(failure check)" == *"restic check が失敗（終了コード 1）"* ]]
}

@test "fail: run-before の失敗では何も書かない（check が理由を書いている）" {
    ERROR_MESSAGE="run-before backup on profile 'claude-transcripts': exit status 1" ERROR_EXIT_CODE=1 \
        run "$SCRIPT" fail
    [ "$status" -eq 0 ]
    [ ! -s "$STATE/failure-backup" ]
}

@test "systemd-fail: その回に理由が書かれていなければ、ユニットの失敗として書く" {
    CLAUDE_TRANSCRIPTS_UNIT_STARTED=$(date +%s)
    export CLAUDE_TRANSCRIPTS_UNIT_STARTED
    run "$SCRIPT" systemd-fail resticprofile-backup
    [ "$status" -eq 0 ]
    [[ "$(failure backup)" == *"backup のユニットが失敗"* ]]
}

@test "systemd-fail: その回に書かれた理由は残す" {
    mkdir -p "$STATE"
    export CLAUDE_TRANSCRIPTS_UNIT_STARTED=$(($(date +%s) - 60))
    echo "D ドライブに届かない" > "$STATE/failure-env"
    run "$SCRIPT" systemd-fail resticprofile-backup
    [ "$status" -eq 0 ]
    [ ! -s "$STATE/failure-backup" ]
}

@test "systemd-fail: 前の回より古い理由しか無ければ、ユニットの失敗として書く" {
    mkdir -p "$STATE"
    echo "前の回の失敗" > "$STATE/failure-env"
    touch -d '2 hours ago' "$STATE/failure-env"
    export CLAUDE_TRANSCRIPTS_UNIT_STARTED=$(($(date +%s) - 60))
    run "$SCRIPT" systemd-fail resticprofile-forget
    [ "$status" -eq 0 ]
    [[ "$(failure forget)" == *"forget のユニットが失敗"* ]]
}
