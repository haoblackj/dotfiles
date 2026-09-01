#!/usr/bin/env bash
# pretooluse-codex-cost-gate.py の判定が実際に効いていることを確かめる。
#
# 判定 1 件につき「止まるもの」と「通るもの」を対で置く。片方だけだと、判定が
# 何も見ていなくても緑になる。
#
# 使い方: ~/.claude/hooks/pretooluse-codex-cost-gate.test.sh
set -uo pipefail

HOOK="$(dirname "${BASH_SOURCE[0]}")/pretooluse-codex-cost-gate.py"
FAILED=0

pass() { echo "  OK   $*"; }
fail() { echo "  NG   $*" >&2; FAILED=1; }

# コマンド文字列を渡し、確認 (ask) が出るかどうかを返す。
decide() {
  local cmd="$1" tool="${2:-Bash}"
  python3 -c "
import json,sys
print(json.dumps({'tool_name': sys.argv[1], 'tool_input': {'command': sys.argv[2]}}))
" "$tool" "$cmd" | python3 "$HOOK"
}

expect_ask() {
  local label="$1" cmd="$2"
  local out; out="$(decide "$cmd")"
  case "$out" in
    *'"permissionDecision": "ask"'*|*'"permissionDecision":"ask"'*) pass "$label" ;;
    *) fail "$label (確認が出ていない: ${out:-空})" ;;
  esac
}

expect_allow() {
  local label="$1" cmd="$2"
  local out; out="$(decide "$cmd")"
  [ -z "$out" ] && pass "$label" || fail "$label (通るはずが出力があった: $out)"
}

M=CODEX_DELEGATION_OK=1
C='node /home/u/.claude/plugins/cache/openai-codex/codex/1.0.6/scripts/codex-companion.mjs'
W='scripts/codex-task.sh'
D='/home/yagu001/.codex/codex-delegate.sh'

echo "=== 1. 枠を使う三つは、印が無ければ確認を出す ==="
expect_ask   "task (ラッパー)"                "$W task --write --background --prompt-file b.md"
expect_ask   "adversarial-review (今回の事故)" "$W adversarial-review --base HEAD"
expect_ask   "review"                          "$W review"
expect_ask   "task (実体を直に)"               "$C task --write"
expect_ask   "adversarial-review (実体を直に)" "$C adversarial-review --base HEAD"

echo "=== 2. 印があれば通す ==="
expect_allow "task に印"               "$M $W task --write --background --prompt-file b.md"
expect_allow "adversarial-review に印" "$M $W adversarial-review --base HEAD"
expect_allow "実体を直に叩く形でも印があれば" "$M $C task --write"

echo "=== 3. 枠を使わないものは印が無くても通す ==="
expect_allow "status (引数なし)" "$W status"
expect_allow "status (job id)"   "$W status task-abc --json"
expect_allow "result"            "$W result task-abc"
expect_allow "cancel"            "$W cancel task-abc"
expect_allow "setup"             "$C setup --json"

echo "=== 4. 内省の口は通す (--print-flags の値を task と読み違えない) ==="
expect_allow "--print-flags task"      "$W --print-flags task"
expect_allow "--print-flags review"    "$W --print-flags review"
expect_allow "--print-companion"       "$W --print-companion"

echo "=== 5. codex と無関係な Bash は素通し ==="
expect_allow "git status"        "git status --short"
expect_allow "紛らわしい語を含む" "grep -n 'adversarial-review' notes.md"
expect_allow "Bash 以外のツール"  "$(: )"

echo "=== 6. 判定できない綴りは確認を出す (fail-closed) ==="
expect_ask   "サブコマンドが読めない" "$W --write --background"

echo "=== 7. ツールが Bash でなければ何もしない ==="
out="$(decide "$W task --write" Edit)"
[ -z "$out" ] && pass "Edit ツールには関与しない" || fail "Edit ツールに反応した: $out"

echo "=== 8. 委譲のラッパーは、印が無ければ確認を出す ==="
expect_ask   "codex-delegate.sh (ブリーフを渡す)" "$D /tmp/brief.md"
expect_allow "codex-delegate.sh に印"             "$M $D /tmp/brief.md"
expect_allow "--print-command は通る"             "$D --print-command /tmp/brief.md"

echo
[ "$FAILED" -eq 0 ] && echo "すべて通った。" || { echo "落ちた判定がある。" >&2; exit 1; }
