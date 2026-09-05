#!/usr/bin/env bash
# 隔離を通らない pytest 実行を止めて verify-tests へ回す PreToolUse フック。
#
# 事故が起きるのは実装中にテストを叩いた瞬間で、push はその後。pre-push だけでは
# 塞ぎたい経路を開けたまま後から確認する形になる。
#
# 判定対象の文字列を Bash ツールのコマンドへ載せると自分のフックに弾かれる。
# 検証はスクリプト経由で行うこと。
set -uo pipefail

payload=$(cat)
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""')

# 対象の2リポジトリの中だけで止める。ユーザースコープの配線なので、
# 絞らないと他の8リポジトリ103本のテストが走らせられなくなる。
origin=$(git -C "${cwd:-.}" remote get-url origin 2>/dev/null) || exit 0
norm=$(printf '%s' "$origin" | sed -E 's#^[a-z]+://##; s#^[^@]*@##; s#^[^/:]+[:/]##; s#\.git$##; s#/$##')
case "$norm" in
  haoblackj/penguinEx|haoblackj/dotfiles) ;;
  *) exit 0 ;;
esac

# 前置きコマンドを剥がしてから判定する。bwrap だけを名指しで塞ぐと
# env / timeout / uv run などが同じ形の抜け道になる。
strip='(env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*|timeout[[:space:]]+[0-9smh]+[[:space:]]+|nohup[[:space:]]+|bwrap[[:space:]]+.*--[[:space:]]+|uv[[:space:]]+run[[:space:]]+|poetry[[:space:]]+run[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
# ファイル名の判定は basename に当てる。`([^[:space:]]*/)?` でパス部分を先に食わせないと
# `manifest_test_helper.py` のような名前まで止まり、verify-tests の対象決定
# （test_*.py / *_test.py を basename で見る）と食い違う。
target='(python3?[[:space:]]+(-m[[:space:]]+pytest|([^[:space:]]*/)?(test_[^[:space:]/]*|[^[:space:]/]*_test)\.py)|pytest)([[:space:]]|$)'
pattern="(^|[;&|(]|&&|\|\|)[[:space:]]*${strip}${target}"

if printf '%s' "$command" | grep -qE "$pattern"; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"隔離を通らない pytest 実行はフックで止めています。`verify-tests <リポジトリ>` で全件、`verify-tests <リポジトリ> -- <pytest への引数>` で1件だけ走らせられます。テストが本番の ~/.claude/ へ書いた事故があったため、実行は bwrap のサンドボックスを通します。"}}
JSON
  exit 0
fi
exit 0
