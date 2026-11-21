#!/bin/bash
# herdr のタブ名を、そのタブで動く Claude Code の session_name に揃える
# （haoblackj/dotfiles#11）。statusline-context-window.sh がバックグラウンドで呼ぶ。
#
# herdr はタブ名をターミナルタイトルへ追従させる機能を持たない（herdrdev/herdr#4359 は
# not_planned）。statusline の入力の session_name は custom-title があればそれ、
# 無ければ ai-title なので、/rename にもそのまま追従する。
#
# 手で付けたタブ名は上書きしない（haoblackj/dotfiles#91）。付け直すのは、タブの今の名前が
# 次のどれかのときだけ:
#   - herdr の既定の名前（ワークスペースの中の位置の番号。数字だけ）
#   - session_name と同じ
#   - このスクリプトが前に付けた名前（タブごとの記録か、セッションごとの記録にある）
# それ以外の名前は手で付けたものとみなす。導入した時点で記録が無いタブも、名前が番号でも
# session_name でもなければ手の名前として残す。
#
# 記録は ${XDG_STATE_HOME:-~/.local/state}/herdr-tab-title/ に置く。/tmp に置くと WSL の
# 再起動で消え、起動直後にすべてのタブを付け直していた。
#   tab/<tab_id>          1 行目: 前回見た session_name、2 行目: このタブに付けた名前
#   session/<session_id>  このセッションのタブに付けた名前
# タブの記録は /clear（session_id が変わる）の後の追従に、セッションの記録は herdr の
# 再起動（タブの ID が変わる）の後の追従に使う。前回見た session_name が今と同じなら
# herdr を呼ばずに抜ける。rename が失敗したときは記録を書かず、次の実行で書き直す。
#
# 1つのタブに複数のペインがあるときは、どのセッション名を使うか決まらないので何もしない。
# herdr tab rename はタブIDより後ろの引数をすべてラベルとして扱い、-- も文字どおり
# ラベルに入る（0.9.1 で実測）。ラベルは1引数で渡し、-- を挟まない。
#
# fail-open: 常に exit 0。stdout には何も出さない。
#
# herdr サーバーが生きたまま応答しない場合に備え、herdr 呼び出しは timeout 5 で括る。
# 括らないと statusline が呼ばれるたび（毎応答・30秒ごと）に子プロセスが終わらずに積み上がる。

set -uo pipefail

[[ "${HERDR_ENV:-}" == 1 ]] || exit 0

TAB_ID="${HERDR_TAB_ID:-}"
# herdr の ID（w9:t6 の形）と session_id 以外は受け付けない（パストラバーサル対策）。
valid_id() { [[ "$1" =~ ^[A-Za-z0-9:._-]+$ && "$1" != *..* ]]; }
valid_id "$TAB_ID" || exit 0

INPUT=$(cat)
NAME=$(jq -r '.session_name // empty' <<< "$INPUT" 2>/dev/null) || exit 0
SESSION_ID=$(jq -r '.session_id // empty' <<< "$INPUT" 2>/dev/null) || exit 0
[[ -n "$NAME" ]] && valid_id "$SESSION_ID" || exit 0

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-tab-title"
TAB_STATE="$STATE_DIR/tab/$TAB_ID"
SESSION_STATE="$STATE_DIR/session/$SESSION_ID"

SEEN="" TAB_OURS="" SESSION_OURS=""
if [[ -f "$TAB_STATE" ]]; then
  { IFS= read -r SEEN; IFS= read -r TAB_OURS; } < "$TAB_STATE" 2>/dev/null
fi
[[ "$SEEN" == "$NAME" ]] && exit 0
[[ -f "$SESSION_STATE" ]] && SESSION_OURS=$(cat -- "$SESSION_STATE" 2>/dev/null)

TAB=$(timeout 5 herdr tab get "$TAB_ID" 2>/dev/null) || exit 0
PANE_COUNT=$(jq -r '.result.tab.pane_count // empty' <<< "$TAB" 2>/dev/null)
[[ "$PANE_COUNT" == 1 ]] || exit 0
LABEL=$(jq -r '.result.tab.label // empty' <<< "$TAB" 2>/dev/null)
[[ -n "$LABEL" ]] || exit 0

# 閉じたセッションを新しいタブで戻すと（claude --resume）、タブは既定の番号の名前で始まる。
# 前のタブに手で付けた名前があっても、上の記録はフックが付けた名前しか持たないので、
# そのままでは session_name で上書きしていた（2026-11-18、手で付けた作業の名前が
# 引き継ぎの定型の名前に変わった）。herdr の保存記録はタブごとに custom_name と
# そのタブのセッションの ID を持つので、新しい順に見て、このセッションが前にいたタブの名前を探す。
# 名前の無いタブ（今の番号のタブ自身）は飛ばし、壊れた記録も飛ばす。
# 見つけた名前が番号か、このフックが付けた名前なら、手の名前ではないので使わない。
SNAPSHOT_DIR="${HERDR_TAB_TITLE_SNAPSHOT_DIR:-$HOME/.config/herdr/session-snapshots}"
previous_hand_label() {
  local f name
  [[ -d "$SNAPSHOT_DIR" ]] || return 1
  while IFS= read -r f; do
    name=$(jq -r --arg s "$SESSION_ID" '
      first(.workspaces[]?.tabs[]?
            | select(any(.panes[]?; .agent_session.value? == $s))
            | .custom_name // empty | select(. != "")) // empty' -- "$f" 2>/dev/null) || continue
    [[ -n "$name" ]] || continue
    [[ "$name" =~ ^[0-9]+$ || "$name" == "$NAME" ||
       ( -n "$SESSION_OURS" && "$name" == "$SESSION_OURS" ) ]] && return 1
    printf '%s' "$name"
    return 0
  done < <(ls -t -- "$SNAPSHOT_DIR"/*.json 2>/dev/null)
  return 1
}

if [[ "$LABEL" =~ ^[0-9]+$ ]] && HAND=$(previous_hand_label); then
  timeout 5 herdr tab rename "$TAB_ID" "$HAND" >/dev/null 2>&1 || exit 0
  # 手の名前として扱う。このタブに付けた名前の記録は空にし、セッションの記録も書かない。
  mkdir -p "$STATE_DIR/tab" 2>/dev/null && printf '%s\n%s\n' "$NAME" "" > "$TAB_STATE" 2>/dev/null
  exit 0
fi

OURS="$TAB_OURS"
if [[ "$LABEL" =~ ^[0-9]+$ || "$LABEL" == "$NAME" ||
      ( -n "$TAB_OURS" && "$LABEL" == "$TAB_OURS" ) ||
      ( -n "$SESSION_OURS" && "$LABEL" == "$SESSION_OURS" ) ]]; then
  if [[ "$LABEL" != "$NAME" ]]; then
    timeout 5 herdr tab rename "$TAB_ID" "$NAME" >/dev/null 2>&1 || exit 0
  fi
  OURS="$NAME"
  mkdir -p "$STATE_DIR/session" 2>/dev/null && printf '%s' "$OURS" > "$SESSION_STATE" 2>/dev/null
fi
mkdir -p "$STATE_DIR/tab" 2>/dev/null && printf '%s\n%s\n' "$NAME" "$OURS" > "$TAB_STATE" 2>/dev/null
exit 0
