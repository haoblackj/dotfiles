#!/bin/bash
# SessionStart: ~/.claude/settings.json が、ソースの linked/claude/settings.json への
# symlink のままかを確かめ、外れていたら画面と Claude に知らせる。
# 調べるだけで、何も書き換えない（直すのはリーダーの判断を経てから）。
# 2026-11-21 に Orca の Windows 側のアプリが symlink を通常のファイルで置き換えた
# （docs/work/settings-symlink.md）。
set -u

# クラウドのセッションでは install-cloud.sh が通常のファイルとして写すので、それが正しい
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && exit 0

target="${SETTINGS_SYMLINK_GUARD_TARGET:-$HOME/.claude/settings.json}"
expected="${SETTINGS_SYMLINK_GUARD_EXPECTED:-${CHEZMOI_SOURCE_DIR:-$HOME/.local/share/chezmoi}/linked/claude/settings.json}"

if [ -L "$target" ]; then
    if [ ! -e "$target" ]; then
        state="リンク先が無い symlink になっている（$(readlink -- "$target")）"
    elif [ "$(realpath -- "$target")" = "$(realpath -- "$expected")" ]; then
        exit 0
    else
        state="別の場所への symlink になっている（$(realpath -- "$target")）"
    fi
elif [ -e "$target" ]; then
    state="通常のファイルになっている"
else
    state="無い"
fi

msg="$target が $state。ソースの $expected への symlink でないので、Claude Code や Orca が書き戻した中身がソースへ届かない。"
ctx="$msg リーダーに伝え、作業記録 docs/work/settings-symlink.md（dotfiles）を読んで、ソースとの差（diff）を確かめてから直し方をリーダーに仰ぐこと。$target も、ソースも、この知らせだけを理由に書き換えない。"

jq -n --arg msg "$msg" --arg ctx "$ctx" '{
  systemMessage: $msg,
  hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: $ctx }
}'
exit 0
