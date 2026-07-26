#!/usr/bin/env bash
# Action `local.open-project.open`: open the fzf project-picker overlay.
#
# Runs on the herdr server (no TTY), so it just opens the `picker` overlay
# pane (see herdr-plugin.toml), which gets a real terminal and runs picker.sh.
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"

exec "$herdr_bin" plugin pane open \
  --plugin local.open-project \
  --entrypoint picker \
  --placement overlay \
  --focus
