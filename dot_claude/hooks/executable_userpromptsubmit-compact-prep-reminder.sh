#!/bin/bash
# UserPromptSubmit hook: threshold producer. transcript_path の直近usage+modelからcontext使用率を自前計算し、
# 閾値超過なら claude-compact-warn マーカファイルを書き込む（cooldown付き, one-shot的に1サイクル1回）。
# compact-plus プラグインの reminder hook が claude-compact-warn を消費し、ユーザーに通知する。
#
# VSCode拡張は statusLine コマンドを未サポートのため、statusLine には依存せず
# hook入力の transcript_path だけで完結させる設計にしている。
#
# コンテキストウィンドウ/警告閾値の判定は lib/context-window.sh に切り出してある。
# 窓幅は 環境変数 > SessionStartマーカー > statusLineマーカー > transcriptのモデル名テーブル の順で決める。
#
# overhead: cooldown中は marker file の test -f 1回で即 exit。
# fail-open (常に exit 0)

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/context-window.sh
. "$HOOK_DIR/lib/context-window.sh" 2>/dev/null || exit 0

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
# session_id は英数字・ドット・アンダースコア・ハイフンのみ許可(パストラバーサル対策)。
[[ -z "$SESSION_ID" || ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ || -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

# cooldown: compact-plus プラグインの reminder hook が書き込んだ claude-compact-warned を読む。
WARNED_MARKER="${TMPDIR:-/tmp}/claude-compact-warned/$SESSION_ID"
[[ -f "$WARNED_MARKER" ]] && exit 0

# 末尾から usage を含む最初の行を1件だけ取得(cache_read_input_tokensは累積値のため
# 直近1件がその時点のcontext使用量の近似値になる)。同じ行に model も乗っている。
USAGE_LINE=$(tac "$TRANSCRIPT" 2>/dev/null | grep -m1 '"usage"')
[[ -z "$USAGE_LINE" ]] && exit 0

MODEL_NAME=$(printf '%s' "$USAGE_LINE" | jq -r '.message.model // empty' 2>/dev/null)
DEFAULT_WINDOW=$(context_window_for_model "$MODEL_NAME")

# 窓幅の決定は4段の優先順位:
#   1. CLAUDE_CONTEXT_WINDOW_TOKENS 環境変数（手動override）
#   2. SessionStart hook が書いたマーカー（transcript の model 名には [1m] が載らないため必要）
#   3. statusLine hook が書いたマーカー（実測値そのまま。SessionStartマーカーが無効な場合のみ試す）
#   4. transcript の model 名によるモデル世代テーブル
# 各段とも、非数値・0・先頭ゼロ(8進誤解釈の原因)を弾いて次の段へ落ちる。
#
# マーカーは「窓幅 モデル名」の1行(例: 1000000 claude-opus-5[1m])。
# セッション途中で /model により実際のモデルが変わると、SessionStart は再発火しないため
# マーカーは古いモデルのまま取り残される。これを見抜くため、マーカーのモデル名([1m]は除去して比較)と
# transcript の現在のモデル名を突き合わせ、食い違えばマーカーごと無効として3段目に落とす。
# モデル名が空(=モデル名を伴わない旧形式のマーカー)も同様に無効として扱う。
WINDOW_MARKER="${TMPDIR:-/tmp}/claude-context-window/$SESSION_ID"
MARKER_WINDOW=""
if [[ -f "$WINDOW_MARKER" ]]; then
  MARKER_LINE=$(head -n1 "$WINDOW_MARKER" 2>/dev/null)
  read -r MARKER_WINDOW_RAW MARKER_MODEL_RAW _ <<< "$MARKER_LINE"
  if [[ "$MARKER_WINDOW_RAW" =~ ^[1-9][0-9]*$ && -n "$MARKER_MODEL_RAW" ]]; then
    MARKER_MODEL="${MARKER_MODEL_RAW%\[1m\]}"
    [[ "$MARKER_MODEL" == "$MODEL_NAME" ]] && MARKER_WINDOW="$MARKER_WINDOW_RAW"
  fi
fi
# SessionStartマーカーが無効(欠落・モデル不一致)なときのみ、statusLineマーカーを試す。
# statusLineマーカーはClaude Code本体が計算した実測値をそのまま転記したものなので、
# モデル名との突き合わせは不要(推測が入らないため陳腐化の概念がない)。
STATUS_WINDOW=""
if [[ -z "$MARKER_WINDOW" ]]; then
  STATUS_MARKER="${TMPDIR:-/tmp}/claude-status-context-window/$SESSION_ID"
  if [[ -f "$STATUS_MARKER" ]]; then
    STATUS_WINDOW=$(head -n1 "$STATUS_MARKER" 2>/dev/null)
    [[ "$STATUS_WINDOW" =~ ^[1-9][0-9]*$ ]] || STATUS_WINDOW=""
  fi
fi

CONTEXT_WINDOW="${CLAUDE_CONTEXT_WINDOW_TOKENS:-}"
[[ "$CONTEXT_WINDOW" =~ ^[1-9][0-9]*$ ]] || CONTEXT_WINDOW="${MARKER_WINDOW:-${STATUS_WINDOW:-$DEFAULT_WINDOW}}"

USED_TOKENS=$(printf '%s' "$USAGE_LINE" | jq -r '
  (.message.usage.input_tokens // 0) +
  (.message.usage.cache_creation_input_tokens // 0) +
  (.message.usage.cache_read_input_tokens // 0)
' 2>/dev/null)
[[ -z "$USED_TOKENS" || "$USED_TOKENS" == "null" ]] && exit 0
[[ "$USED_TOKENS" =~ ^(0|[1-9][0-9]*)$ ]] || exit 0

# セッション途中のモデル切替(switchModelsOnFlag)等で窓幅の判定が古い場合の保険。
# 窓幅を超えて動作している事実は、その窓幅が正しくないことの確定的な証拠になる。
# 手動overrideにも適用する。窓幅より多く使っている状態でその窓幅を信じると
# 使用率が常に100%を超え、警告が意味を失うため。
[[ "$USED_TOKENS" -gt "$CONTEXT_WINDOW" ]] && CONTEXT_WINDOW=1000000

DEFAULT_THRESHOLD=$(default_threshold_for_window "$CONTEXT_WINDOW")
THRESHOLD="${CLAUDE_COMPACT_WARN_THRESHOLD:-$DEFAULT_THRESHOLD}"
[[ "$THRESHOLD" =~ ^(0|[1-9][0-9]*)$ ]] || THRESHOLD="$DEFAULT_THRESHOLD"

PCT=$(( USED_TOKENS * 100 / CONTEXT_WINDOW ))
[[ "$PCT" -lt "$THRESHOLD" ]] && exit 0

# Marker producer: PCT を claude-compact-warn に書き込む。
# compact-plus プラグインの reminder hook がこれを読み、ユーザーに通知する。
WARN_DIR="${TMPDIR:-/tmp}/claude-compact-warn"; WARN_MARKER="$WARN_DIR/$SESSION_ID"
[[ -f "$WARN_MARKER" ]] && exit 0
mkdir -p "$WARN_DIR" 2>/dev/null || true
printf '%s\n' "$PCT" > "$WARN_MARKER" 2>/dev/null || true
exit 0
