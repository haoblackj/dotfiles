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

@test "正常なら何も出さない" {
    touch "$STATE/last-success"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "失敗している間は理由を出す" {
    touch "$STATE/last-success"
    echo "D ドライブに届かない" > "$STATE/failure-env"
    run "$SCRIPT"
    [ "$output" = "⚠ 退避失敗: D ドライブに届かない" ]
}

@test "検査の失敗は、backup が成功していても出す" {
    touch "$STATE/last-success"
    echo "restic check が失敗（終了コード 1）" > "$STATE/failure-check"
    run "$SCRIPT"
    [ "$output" = "⚠ 退避失敗: restic check が失敗（終了コード 1）" ]
}

@test "失敗が複数あれば、原因に近い環境の失敗を先に出す" {
    echo "backup のユニットが失敗" > "$STATE/failure-backup"
    echo "D ドライブに届かない" > "$STATE/failure-env"
    run "$SCRIPT"
    [ "$output" = "⚠ 退避失敗: D ドライブに届かない" ]
}

@test "最後の成功から 3 時間を超えたら止まっていると出す" {
    touch -d '5 hours ago' "$STATE/last-success"
    run "$SCRIPT"
    [ "$output" = "⚠ 退避が 5 時間止まっている" ]
}

@test "起動して間もないうちは、古い成功の時刻で騒がない" {
    touch -d '5 hours ago' "$STATE/last-success"
    echo "600.00 0.00" > "$CLAUDE_TRANSCRIPTS_UPTIME_FILE"
    run "$SCRIPT"
    [ -z "$output" ]
}

@test "タイマーを入れてから一度も成功しないまま 3 時間を超えたら出す" {
    touch -d '5 hours ago' "$CLAUDE_TRANSCRIPTS_BACKUP_TIMER"
    run "$SCRIPT"
    [ "$output" = "⚠ 退避がまだ一度も成功していない" ]
}

@test "タイマーを入れたばかりなら、成功が無くても騒がない" {
    run "$SCRIPT"
    [ -z "$output" ]
}

@test "タイマーの無いマシンでは何も出さない" {
    echo "D ドライブに届かない" > "$STATE/failure-env"
    rm -- "$CLAUDE_TRANSCRIPTS_BACKUP_TIMER"
    run "$SCRIPT"
    [ -z "$output" ]
}
