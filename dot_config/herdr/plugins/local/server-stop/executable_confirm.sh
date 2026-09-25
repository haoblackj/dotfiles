#!/usr/bin/env bash
# Pane `local.server-stop.confirm`: y/N を聞き、y のときだけ herdr server stop を実行する。
#
# ポップアップ（実 TTY）の中で走る。y 以外のキー（Enter、Esc を含む）は取り消しで、
# スクリプトが終わればポップアップは自動で閉じる。y のときはサーバーが止まるので
# ポップアップもペインもまとめて消える。
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

printf 'herdr サーバーを停止します。\n'
printf '全ペインのプロセス（エージェントを含む）が終了します。\n\n'
printf '停止しますか？ [y/N] '
read -r -n1 answer
printf '\n'

case "$answer" in
  y|Y) exec "$herdr_bin" server stop ;;
  *) exit 0 ;;
esac
