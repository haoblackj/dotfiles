#!/usr/bin/env bash
# Action `local.open-github.open`: フォーカス中ペインの cwd を渡して picker のオーバーレイを開く。
#
# herdr のサーバー側で走る（TTY 無し）ので、ここでは cwd を取り出して
# オーバーレイを開くだけ。選択と起動は picker.sh（実 TTY）がやる。
# cwd は HERDR_PLUGIN_CONTEXT_JSON の focused_pane_cwd（herdr-api-notes.md、0.7.1 で確認）。
set -uo pipefail

# herdr はプラグインを最小の PATH で走らせるので、jq のある場所を後ろに足す
PATH="$PATH:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"
herdr_bin="${HERDR_BIN_PATH:-herdr}"

cwd="$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-}" | jq -r '.focused_pane_cwd // empty' 2>/dev/null)"

args=(--plugin local.open-github --entrypoint picker --placement overlay --focus)
[[ -n "$cwd" ]] && args+=(--cwd "$cwd")

exec "$herdr_bin" plugin pane open "${args[@]}"
