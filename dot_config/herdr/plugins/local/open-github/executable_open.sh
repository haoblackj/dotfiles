#!/usr/bin/env bash
# Action `local.open-github.open`: フォーカス中ペインの cwd を渡して picker のポップアップを開く。
#
# herdr のサーバー側で走る（TTY 無し）ので、ここでは cwd を取り出して
# ポップアップを開くだけ。選択と起動は picker.sh（実 TTY）がやる。
# cwd は HERDR_PLUGIN_CONTEXT_JSON の focused_pane_cwd（herdr-api-notes.md、0.7.1 で確認）。
set -uo pipefail

# herdr はプラグインを最小の PATH で走らせるので、jq のある場所を後ろに足す
PATH="$PATH:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"
herdr_bin="${HERDR_BIN_PATH:-herdr}"

ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"
pane_id="$(printf '%s' "$ctx" | jq -r '.focused_pane_id // empty' 2>/dev/null)"
workspace_id="$(printf '%s' "$ctx" | jq -r '.workspace_id // empty' 2>/dev/null)"

# focused_pane_cwd はペインのシェルの cwd で、Claude Code がワークツリーへ chdir しても
# 追随しない（起動時の main のまま）。pane list の foreground_cwd が前面プロセスの
# 実 cwd なので、そちらを優先し、取れなければ focused_pane_cwd に落とす。
cwd=""
if [[ -n "$pane_id" ]]; then
  cwd="$("$herdr_bin" pane list ${workspace_id:+--workspace "$workspace_id"} 2>/dev/null \
    | jq -r --arg id "$pane_id" '.result | .. | objects | select(.pane_id? == $id) | .foreground_cwd // .cwd // empty' 2>/dev/null \
    | head -n1)"
fi
[[ -n "$cwd" ]] || cwd="$(printf '%s' "$ctx" | jq -r '.focused_pane_cwd // empty' 2>/dev/null)"

# placement と寸法はマニフェスト側（popup、80% × 10 行）に任せる
args=(--plugin local.open-github --entrypoint picker --focus)
[[ -n "$cwd" ]] && args+=(--cwd "$cwd")

exec "$herdr_bin" plugin pane open "${args[@]}"
