#!/usr/bin/env bash
# 作業先が直前から変わったときだけ知らせる PreToolUse フック。
#
# グローバル CLAUDE.md は「ファイルを変更する前に pwd と git rev-parse --show-toplevel を
# 実行して作業先を確認する」と定めていたが、記録上4回守られなかった。Bash ツールの作業
# ディレクトリは呼び出しをまたいで持続するので cd した記憶が薄れ、しかも取り違えても大半の
# コマンドは成功するため、確認を省いたことに気づけない。
#
# そこで「確認したか」を人へ問うのをやめ、確認結果を毎回機械が計算して、変わったときだけ
# additionalContext で渡す。止めない（permissionDecision は返さない）。
#
# 設計: penguinEx docs/superpowers/specs/2026-09-04-workdir-notice-design.md
# テスト: chezmoi ソース側の executable_notify-workdir-change.test.sh
#
# 注意点。
#   - stdin はソケットで渡る。$(</dev/stdin) は ENXIO で落ちるので $(cat) を使う。
#   - git 管理外の判定に終了コードを使わない。コミットが1つも無いリポジトリは 128 を
#     返しながらトップレベルを出す。標準出力の1行目で判定する。
#   - どの分岐でも exit 0。ツール呼び出しを妨げない。

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-workdir-notice"
NOGIT='!nogit'

input=$(cat)
[ -n "$input" ] || exit 0

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
case "$tool_name" in
  Bash)       lane=1 ;;  # shell レーン
  Write|Edit) lane=2 ;;  # write レーン
  *)          exit 0 ;;
esac

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cwd" ] || exit 0

base="$cwd"

jq -nc --arg b "$base" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: ("このセッションのBash の作業ディレクトリは " + $b + " です。")
  }
}'
exit 0
