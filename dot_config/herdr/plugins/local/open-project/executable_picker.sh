#!/usr/bin/env bash
# Pane `local.open-project.picker`: the interactive fzf project picker.
#
# Runs inside an overlay pane (real TTY). Lists project directories under
# PROJECTS_ROOT, lets the user fuzzy-pick one, creates a new workspace for it,
# and starts Claude Code there. When this script exits the overlay closes on
# its own, so there is no tab/pane cleanup to do here.
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"
PROJECTS_ROOT="$HOME/repo/github.com/haoblackj"

command -v fzf >/dev/null 2>&1 || { echo "open-project: fzf not found" >&2; sleep 2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "open-project: jq not found" >&2; sleep 2; exit 1; }

selected="$(
  find "$PROJECTS_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | sort \
    | fzf --prompt="open project> " --reverse --header='enter: open in new workspace · esc: cancel'
)" || true

[ -n "$selected" ] || exit 0

target_path="$PROJECTS_ROOT/$selected"

result="$("$herdr_bin" workspace create --cwd "$target_path" --label "$selected")"
pane_id="$(printf '%s' "$result" | jq -r '.result.root_pane.pane_id')"

"$herdr_bin" pane run "$pane_id" claude
