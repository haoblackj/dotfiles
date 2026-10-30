#!/bin/bash
# ループ（/loop）を、Herdr の新しいタブの新しいセッションへ引き継ぐ（haoblackj/dotfiles#69）。
# loop-guard.sh がコンテキストの二段目で予約を deny したとき、その理由の文面でこれを呼ばせる。
# Claude が決めるのは、状態コメントの場所、モデルとエフォート、ループの指示だけ。
# タブの作成、agent の起動、引き継ぎの文面は、ここが決まった形で行う。
#
# 使い方:
#   loop-handoff.sh --state-url <状態コメントの URL> --model <モデル> --effort <エフォート> [--dry-run] -- <ループの指示>
#
# 状態コメントの URL は、GitHub の issue か PR のコメントへのリンク（#issuecomment-<数字>）だけを受け付ける。
# 引き継ぎの前に状態が書かれていることを、形の上で確かめるため。
# 新しいタブは、呼んだペインと同じワークスペースに、同じ cwd で作る（1 セッション 1 リポジトリ）。
# ワークスペースと cwd は herdr pane current --current から取る。HERDR_WORKSPACE_ID は起動した時点の
# 値で、ペインを別のワークスペースへ移したあとは古い。$PWD は Bash ツールが cd した先のことがある。
# 失敗したら、どの手順で止まったかを標準エラーに出して exit 1。作ったタブは閉じない（中を見て判断する）。
# --dry-run は herdr を呼ばず、呼ぶはずのコマンドを 1 行ずつ出す。

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/herdr-start-claude.sh"

die() { printf 'loop-handoff: %s\n' "$1" >&2; exit 1; }

STATE_URL="" MODEL="" EFFORT="" DRY=0
while (( $# > 0 )); do
  case "$1" in
    --state-url) STATE_URL="${2:-}"; shift 2 || die "--state-url に値が無い" ;;
    --model) MODEL="${2:-}"; shift 2 || die "--model に値が無い" ;;
    --effort) EFFORT="${2:-}"; shift 2 || die "--effort に値が無い" ;;
    --dry-run) DRY=1; shift ;;
    --) shift; break ;;
    *) die "知らない引数: $1" ;;
  esac
done
INSTRUCTION="$*"

[[ "$STATE_URL" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/(issues|pull)/[0-9]+#issuecomment-[0-9]+$ ]] ||
  die "--state-url は状態コメントへのリンク（https://github.com/<owner>/<repo>/issues/<番号>#issuecomment-<数字>）にする。先に issue へ \`## 状態\` を書く"
# opus、claude-opus-5-5、opus[1m] の形を通す。[ と ] は角括弧の式の先頭に置く（バックスラッシュでは閉じない）
MODEL_RE='^[][A-Za-z0-9._-]+$'
[[ "$MODEL" =~ $MODEL_RE ]] || die "--model が無いか、形が違う"
[[ "$EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]] || die "--effort は low、medium、high、xhigh、max のどれか"
INSTRUCTION="${INSTRUCTION#/loop }"
[[ -n "${INSTRUCTION// /}" ]] || die "ループの指示が空"

if (( DRY == 0 )); then
  [[ "${HERDR_ENV:-}" == 1 ]] || die "Herdr のペインの中で呼ぶ（HERDR_ENV が無い）"
  command -v herdr >/dev/null 2>&1 || die "herdr が無い"
  command -v jq >/dev/null 2>&1 || die "jq が無い"
fi
WS="${HERDR_WORKSPACE_ID:-}"
DIR="$PWD"
if (( DRY == 0 )); then
  CUR=$(herdr pane current --current 2>/dev/null) || CUR=""
  W=$(jq -r '.result.pane.workspace_id // empty' <<< "$CUR" 2>/dev/null)
  C=$(jq -r '.result.pane.cwd // .result.pane.foreground_cwd // empty' <<< "$CUR" 2>/dev/null)
  [[ -n "$W" ]] && WS="$W"
  [[ -n "$C" && -d "$C" ]] && DIR="$C"
fi
(( DRY == 1 )) && WS="${WS:-<workspace>}"
[[ -n "$WS" ]] || die "ワークスペースが分からない（pane current も HERDR_WORKSPACE_ID も無い）"

NAME="loop-$(date +%m%d%H%M%S)"
PROMPT="/loop $INSTRUCTION

（前のセッションからの引き継ぎ。毎回の最初に状態コメント $STATE_URL と、それより新しい \`## 状態\` を読み、「次の一手」から続ける。）"

STARTED=$(start_claude_in_new_tab "$WS" "$DIR" "$MODEL" "$EFFORT" "$NAME" "$PROMPT") || exit 1
(( DRY == 1 )) && { printf '%s' "$STARTED"; exit 0; }
PANE=$(jq -r .pane <<< "$STARTED")

jq -nc --arg name "$NAME" --arg pane "$PANE" --arg url "$STATE_URL" \
  '{handed_off: true, agent: $name, pane: $pane, state_url: $url}'
