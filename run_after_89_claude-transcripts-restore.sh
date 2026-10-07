#!/bin/bash
set -eu

# WSL を入れ直した後の最初の apply で、トランスクリプトを戻す（haoblackj/dotfiles#42）。
# 戻すのは backup の前に claude-transcripts-backup-guard が行うので、ここでは backup を一回走らせるだけ。
# 毎時のタイマーを待たずに戻すために置く。claude-private（パスワード）は導入手順の後半の apply で
# 届くので、run_onchange ではなく毎回の apply で「未復元でパスワードが届いている」かを見る。
SERVICE=resticprofile-backup@profile-claude-transcripts.service
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/claude-transcripts-backup"

[ -e "$HOME/.config/systemd/user/$SERVICE" ] || exit 0
[ -e "$STATE/restored" ] && exit 0
[ -r "$HOME/.local/share/claude-private/secrets/restic-claude-transcripts" ] || exit 0

systemctl --user start --no-block "$SERVICE"
echo "トランスクリプトの復元と退避を始めた。進み具合は journalctl --user -u $SERVICE -f"
