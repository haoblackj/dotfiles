#!/usr/bin/env bash
# Claude Code のトランスクリプトの退避（haoblackj/dotfiles#42、#45）が失敗しているか止まっている間だけ、
# ステータスラインに出す。正常なら何も出さない。状態は claude-transcripts-backup-guard が書く。
set -uo pipefail

STATE="${CLAUDE_TRANSCRIPTS_BACKUP_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-transcripts-backup}"
TIMER="${CLAUDE_TRANSCRIPTS_BACKUP_TIMER:-$HOME/.config/systemd/user/resticprofile-backup@profile-claude-transcripts.timer}"
UPTIME_FILE="${CLAUDE_TRANSCRIPTS_UPTIME_FILE:-/proc/uptime}"
STALE_SECONDS=$((3 * 3600))

# タイマーを入れていないマシン（D ドライブが無い等）では見張らない
[ -e "$TIMER" ] || exit 0

# 原因に近いものから出す。環境（D、リポジトリ、パスワード）が欠けると backup も check も落ちる
for kind in env backup check forget; do
    if [ -s "$STATE/failure-$kind" ]; then
        printf '⚠ 退避失敗: %s' "$(head -n 1 "$STATE/failure-$kind")"
        exit 0
    fi
done

# WSL が止まっている間はタイマーも止まる。起動して間もないうちは、次の毎時の回を待つ
uptime=$(awk '{printf "%d", $1}' "$UPTIME_FILE")
[ "$uptime" -gt "$STALE_SECONDS" ] || exit 0

now=$(date +%s)
if [ -e "$STATE/last-success" ]; then
    age=$((now - $(stat -c %Y "$STATE/last-success")))
    [ "$age" -gt "$STALE_SECONDS" ] && printf '⚠ 退避が %d 時間止まっている' $((age / 3600))
elif [ $((now - $(stat -c %Y "$TIMER"))) -gt "$STALE_SECONDS" ]; then
    printf '⚠ 退避がまだ一度も成功していない'
fi
exit 0
