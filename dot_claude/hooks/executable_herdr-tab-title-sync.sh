#!/bin/bash
# herdr のタブ名を、そのタブで動く Claude Code の session_name に揃える
# （haoblackj/dotfiles#11）。statusline-context-window.sh がバックグラウンドで呼ぶ。
#
# herdr はタブ名をターミナルタイトルへ追従させる機能を持たない（herdrdev/herdr#4359 は
# not_planned）。statusline の入力の session_name は custom-title があればそれ、
# 無ければ ai-title なので、/rename にもそのまま追従する。
#
# 値が変わったときだけ rename する。前回値は ${TMPDIR:-/tmp}/herdr-tab-title/<pane_id>
# に置き、rename が成功したときだけ書く。statusline の実行が打ち切られても、
# 次の実行で書き直せる。herdr 側で手で付けたタブ名は、次に session_name が変わるまで残る。
#
# 1つのタブに複数のペインがあるときは、どのセッション名を使うか決まらないので何もしない。
# herdr tab rename はタブIDより後ろの引数をすべてラベルとして扱い、-- も文字どおり
# ラベルに入る（0.9.1 で実測）。ラベルは1引数で渡し、-- を挟まない。
#
# fail-open: 常に exit 0。stdout には何も出さない。

set -uo pipefail

[[ "${HERDR_ENV:-}" == 1 ]] || exit 0

TAB_ID="${HERDR_TAB_ID:-}"
PANE_ID="${HERDR_PANE_ID:-}"
# herdr の ID（w9:p6 の形）以外は受け付けない（パストラバーサル対策）。
valid_id() { [[ "$1" =~ ^[A-Za-z0-9:._-]+$ && "$1" != *..* ]]; }
valid_id "$TAB_ID" && valid_id "$PANE_ID" || exit 0

NAME=$(jq -r '.session_name // empty' 2>/dev/null) || exit 0
[[ -n "$NAME" ]] || exit 0

STATE_DIR="${TMPDIR:-/tmp}/herdr-tab-title"
STATE="$STATE_DIR/$PANE_ID"
[[ -f "$STATE" && "$(cat -- "$STATE" 2>/dev/null)" == "$NAME" ]] && exit 0

PANE_COUNT=$(herdr tab get "$TAB_ID" 2>/dev/null | jq -r '.result.tab.pane_count // empty' 2>/dev/null)
[[ "$PANE_COUNT" == 1 ]] || exit 0

herdr tab rename "$TAB_ID" "$NAME" >/dev/null 2>&1 || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s' "$NAME" > "$STATE" 2>/dev/null
exit 0
