#!/usr/bin/env bats
# claude-transcripts-backup-status.sh（ステータスラインの枠）のユニットテスト。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_claude-transcripts-backup-status.sh"
    TMPDIR_TEST="$(mktemp -d)"
    STATE="$TMPDIR_TEST/state"
    mkdir -p "$STATE"
    export CLAUDE_TRANSCRIPTS_BACKUP_STATE="$STATE"
    export CLAUDE_TRANSCRIPTS_BACKUP_TIMER="$TMPDIR_TEST/backup.timer"
    : > "$CLAUDE_TRANSCRIPTS_BACKUP_TIMER"
    # 起動から 10 時間たった扱い
    export CLAUDE_TRANSCRIPTS_UPTIME_FILE="$TMPDIR_TEST/uptime"
    echo "36000.00 0.00" > "$CLAUDE_TRANSCRIPTS_UPTIME_FILE"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

@test "失敗している間は理由を出す" {
    touch "$STATE/last-success"
    echo "D ドライブに届かない" > "$STATE/failure-env"
    run "$SCRIPT"
    [ "$output" = "⚠ 退避失敗: D ドライブに届かない" ]
}

@test "最後の成功から 3 時間を超えたら止まっていると出す" {
    touch -d '5 hours ago' "$STATE/last-success"
    run "$SCRIPT"
    [ "$output" = "⚠ 退避が 5 時間止まっている" ]
}

@test "検査の失敗は、backup が成功していても出す" {
    touch "$STATE/last-success"
    echo "restic check が失敗（終了コード 1）" > "$STATE/failure-check"
    run "$SCRIPT"
    [ "$output" = "⚠ 退避失敗: restic check が失敗（終了コード 1）" ]
}

@test "タイマーを入れてから一度も成功しないまま 3 時間を超えたら出す" {
    touch -d '5 hours ago' "$CLAUDE_TRANSCRIPTS_BACKUP_TIMER"
    run "$SCRIPT"
    [ "$output" = "⚠ 退避がまだ一度も成功していない" ]
}
