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
# 手順は herdr の公式の文書（agent automation、cli reference）に従う:
#   tab create は .result.root_pane.pane_id を返す。
#   agent start はシェルがフォアグラウンドにいるペインを求めるので、作った直後のシェルが何かを
#   描くまで pane wait-output で待つ。agent start 自体は、起動の待ちを既定の 30 秒から延ばす
#   （SessionStart のフックで起動が遅れることがある）。再試行はしない。一度目が claude を打ち込んで
#   いれば、二度目は起動中の claude に打ち込むことになるため。
#   agent prompt は --wait を付けない（相手の応答が落ち着くまでブロックするため。グローバルの CLAUDE.md）。
# 失敗したら、どの手順で止まったかを標準エラーに出して exit 1。作ったタブは閉じない（中を見て判断する）。
# --dry-run は herdr を呼ばず、呼ぶはずのコマンドを 1 行ずつ出す。

set -uo pipefail

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

run() {
  if (( DRY == 1 )); then printf '%q ' "$@"; printf '\n'; return 0; fi
  "$@"
}

CREATED=$(run herdr tab create --workspace "$WS" --cwd "$DIR" --no-focus) || die "tab create で失敗: $CREATED"
if (( DRY == 1 )); then
  printf '%s' "$CREATED"
  PANE="<root_pane>"
else
  PANE=$(jq -r '.result.root_pane.pane_id // empty' <<< "$CREATED" 2>/dev/null)
  [[ -n "$PANE" ]] || die "tab create の応答に root_pane.pane_id が無い: $CREATED"
fi

# 待ちが切れても先へ進む（プロンプトの形は人の設定しだいで、何も描かないシェルもありうる）
run herdr pane wait-output "$PANE" --regex '\S' --timeout 15000 >/dev/null 2>&1

OUT=$(run herdr agent start "$NAME" --kind claude --pane "$PANE" --timeout 120000 -- --model "$MODEL" --effort "$EFFORT") ||
  die "agent start で失敗（ペイン $PANE は残してある）: $OUT"
(( DRY == 1 )) && printf '%s' "$OUT"

OUT=$(run herdr agent prompt "$NAME" "$PROMPT") || die "agent prompt で失敗（agent $NAME は起動済み）: $OUT"
(( DRY == 1 )) && { printf '%s' "$OUT"; exit 0; }

jq -nc --arg name "$NAME" --arg pane "$PANE" --arg url "$STATE_URL" \
  '{handed_off: true, agent: $name, pane: $pane, state_url: $url}'
