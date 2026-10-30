#!/bin/bash
# 対話の状態を、Herdr の新しいタブの新しいセッションへ引き継ぐ。
# 状態の URL か ~/.cache/claude-handoff/ 下のファイルと、作業する cwd を指定する。
# ワークスペースは pane current から取り、cwd は --cwd の値を使う。
# 失敗した手順を標準エラーに出して exit 1。作ったタブは閉じない。
# --dry-run は herdr を呼ばず、呼ぶはずのコマンドを出す。
#
# 使い方:
#   session-handoff.sh --state <状態の場所> --cwd <dir> --model <モデル> --effort <エフォート> [--dry-run]

set -uo pipefail

die() { printf 'session-handoff: %s\n' "$1" >&2; exit 1; }

# shellcheck source=dot_claude/scripts/herdr-start-claude.sh
source "$(dirname "${BASH_SOURCE[0]}")/herdr-start-claude.sh" || die "共通部分 herdr-start-claude.sh を読み込めない"

STATE="" DIR="" MODEL="" EFFORT="" DRY=0
while (( $# > 0 )); do
  case "$1" in
    --state) STATE="${2:-}"; shift 2 || die "--state に値が無い" ;;
    --cwd) DIR="${2:-}"; shift 2 || die "--cwd に値が無い" ;;
    --model) MODEL="${2:-}"; shift 2 || die "--model に値が無い" ;;
    --effort) EFFORT="${2:-}"; shift 2 || die "--effort に値が無い" ;;
    --dry-run) DRY=1; shift ;;
    *) die "知らない引数: $1" ;;
  esac
done

if [[ ! "$STATE" =~ ^https?://[^[:space:]]+$ ]]; then
  # 親参照や symlink を解決して、保存先の外にあるファイルを受け付けない。
  [[ -f "$STATE" ]] || die "--state は URL か ~/.cache/claude-handoff/ 下のファイルにする"
  STATE_PATH=$(realpath -e -- "$STATE" 2>/dev/null) || die "状態のファイルの場所が分からない"
  STATE_ROOT=$(realpath -e -- "$HOME/.cache/claude-handoff" 2>/dev/null) || die "状態の保存先が無い"
  [[ "$STATE_PATH" == "$STATE_ROOT/"* ]] || die "状態のファイルは ~/.cache/claude-handoff/ 下に置く"
  STATE="$STATE_PATH"
fi
[[ -n "$DIR" && -d "$DIR" ]] || die "--cwd は存在するディレクトリにする"
DIR=$(realpath -e -- "$DIR" 2>/dev/null) || die "作業ディレクトリの場所が分からない"
MODEL_RE='^[][A-Za-z0-9._-]+$'
[[ "$MODEL" =~ $MODEL_RE ]] || die "--model が無いか、形が違う"
[[ "$EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]] || die "--effort は low、medium、high、xhigh、max のどれか"

if (( DRY == 0 )); then
  [[ "${HERDR_ENV:-}" == 1 ]] || die "Herdr のペインの中で呼ぶ（HERDR_ENV が無い）"
  command -v herdr >/dev/null 2>&1 || die "herdr が無い"
  command -v jq >/dev/null 2>&1 || die "jq が無い"
fi
WS="${HERDR_WORKSPACE_ID:-}"
if (( DRY == 0 )); then
  CUR=$(timeout 5 herdr pane current --current 2>/dev/null) || CUR=""
  W=$(jq -r '.result.pane.workspace_id // empty' <<< "$CUR" 2>/dev/null)
  [[ -n "$W" ]] && WS="$W"
fi
(( DRY == 1 )) && WS="${WS:-<workspace>}"
[[ -n "$WS" ]] || die "ワークスペースが分からない（pane current も HERDR_WORKSPACE_ID も無い）"

NAME="chat-$(date +%m%d%H%M%S)"
PROMPT="前のセッションからの引き継ぎ。最初に状態 $STATE を読み（issue のコメントなら、それより新しい \`## 状態\` も）、そこに書かれた作業フォルダ、ワークツリー、ブランチ、issue と PR を確かめてから「次の一手」から続ける。"
STARTED=$(start_claude_in_new_tab "$WS" "$DIR" "$MODEL" "$EFFORT" "$NAME" "$PROMPT") || exit 1
(( DRY == 1 )) && { printf '%s' "$STARTED"; exit 0; }

jq -nc --arg name "$NAME" --arg state "$STATE" --argjson started "$STARTED" \
  '{handed_off: true, agent: $name, tab: $started.tab, pane: $started.pane, state: $state}'
