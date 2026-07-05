#!/bin/bash
# PostCompact hook: 圧縮発生を marker file に記録する。
# PostCompact は additionalContext を返せない仕様のため、
# 実際の context 注入は UserPromptSubmit hook (userpromptsubmit-compaction-recovery.sh) が行う。
# fail-open (常に exit 0)

set -uo pipefail

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# session_id は英数字・ドット・アンダースコア・ハイフンのみ許可(パストラバーサル対策)。
# 空文字列もこの正規表現には一致しないため空チェックを兼ねる。
[[ "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

# trigger (manual/auto) はベストエフォートの付帯情報。フィールド名は
# 公式ドキュメントで確定できなかったため、複数候補を試し、無ければ unknown とする。
TRIGGER=$(printf '%s' "$INPUT" | jq -r '.trigger // .matcher // empty' 2>/dev/null)

MARKER_DIR="${TMPDIR:-/tmp}/claude-compacted"
mkdir -p "$MARKER_DIR" 2>/dev/null || true
printf '%s %s\n' "$(date +%s)" "${TRIGGER:-unknown}" > "$MARKER_DIR/$SESSION_ID" 2>/dev/null || true

# compact が実行されたら閾値警告の cooldown をリセットする
WARN_DIR="${TMPDIR:-/tmp}/claude-compact-warned"
rm -f "$WARN_DIR/$SESSION_ID" 2>/dev/null || true

exit 0
