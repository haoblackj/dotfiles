#!/bin/bash
# UserPromptSubmit hook: threshold producer. statusLine が書いた使用率マーカーを読み、
# 閾値超過なら claude-compact-warn マーカファイルを書き込む（cooldown付き, one-shot的に1サイクル1回）。
# compact-plus プラグインの reminder hook が claude-compact-warn を消費し、ユーザーに通知する。
#
# 使用率の出所は statusline-context-window.sh が書く
#   ${TMPDIR:-/tmp}/claude-status-context-usage/$SESSION_ID   （context_window.used_percentage）
#   ${TMPDIR:-/tmp}/claude-status-context-window/$SESSION_ID  （context_window.context_window_size）
# の2つだけ。どちらも Claude Code 本体が計算した値で、/compact 直後は使用率が null になり
# マーカーが消える（次の API 呼び出しで圧縮後の値に戻る）。
#
# 以前は transcript の末尾から usage を自前で拾っていたが、/compact 直後にまだ新しい
# assistant レコードが無い時点で走ると圧縮前の最後の usage（63%）を拾い、圧縮直後に
# 「63% に達した」と誤って知らせた（2026-09-12、penguinEx issue #73）。窓幅を
# モデル名テーブルや SessionStart マーカーから推測する段も同時にやめた。statusLine が
# 動かない環境（VSCode 拡張など）では警告が出ないが、推測値で誤報するより黙る側を取る。
#
# 警告閾値の判定だけ lib/context-window.sh を使う（1M 窓なら 60%、それ未満なら 85%）。
#
# overhead: cooldown中は marker file の test -f 1回で即 exit。
# fail-open (常に exit 0)

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/context-window.sh
. "$HOOK_DIR/lib/context-window.sh" 2>/dev/null || exit 0

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# session_id は英数字・ドット・アンダースコア・ハイフンのみ許可(パストラバーサル対策)。
[[ -z "$SESSION_ID" || ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] && exit 0

# cooldown: compact-plus プラグインの reminder hook が書き込んだ claude-compact-warned を読む。
WARNED_MARKER="${TMPDIR:-/tmp}/claude-compact-warned/$SESSION_ID"
[[ -f "$WARNED_MARKER" ]] && exit 0

# 使用率マーカーが無い＝いま測れない（セッション最初の API 呼び出し前、/compact 直後、
# statusLine 未実行）。推測で埋めずに黙る。
USAGE_MARKER="${TMPDIR:-/tmp}/claude-status-context-usage/$SESSION_ID"
[[ -f "$USAGE_MARKER" ]] || exit 0
PCT_RAW=$(head -n1 "$USAGE_MARKER" 2>/dev/null)
[[ "$PCT_RAW" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 0
PCT="${PCT_RAW%%.*}"

# 窓幅は閾値（60% か 85% か）を選ぶためだけに使う。無ければ推測せず黙る。
WINDOW_MARKER="${TMPDIR:-/tmp}/claude-status-context-window/$SESSION_ID"
[[ -f "$WINDOW_MARKER" ]] || exit 0
CONTEXT_WINDOW=$(head -n1 "$WINDOW_MARKER" 2>/dev/null)
[[ "$CONTEXT_WINDOW" =~ ^[1-9][0-9]*$ ]] || exit 0

DEFAULT_THRESHOLD=$(default_threshold_for_window "$CONTEXT_WINDOW")
THRESHOLD="${CLAUDE_COMPACT_WARN_THRESHOLD:-$DEFAULT_THRESHOLD}"
[[ "$THRESHOLD" =~ ^(0|[1-9][0-9]*)$ ]] || THRESHOLD="$DEFAULT_THRESHOLD"

[[ "$PCT" -lt "$THRESHOLD" ]] && exit 0

# Marker producer: PCT を claude-compact-warn に書き込む。
# compact-plus プラグインの reminder hook がこれを読み、ユーザーに通知する。
WARN_DIR="${TMPDIR:-/tmp}/claude-compact-warn"; WARN_MARKER="$WARN_DIR/$SESSION_ID"
[[ -f "$WARN_MARKER" ]] && exit 0
mkdir -p "$WARN_DIR" 2>/dev/null || true
printf '%s\n' "$PCT" > "$WARN_MARKER" 2>/dev/null || true
exit 0
