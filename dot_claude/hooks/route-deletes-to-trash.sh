#!/usr/bin/env bash
# 削除を止めて、ゴミ箱（trash-cli）へ回させる PreToolUse フック。
#
# 2026-08-30、cwd を取り違えたまま掃除のつもりで `rm -rf` を打ち、同じ階層にあった
# 別の作業の記録ごと消す事故があった。
#
# 最初は「再帰削除だけ禁止」にしたが、それは対症療法だった。単一ファイルの削除を
# 並べても `find -delete` を使っても同じ結果になるし、そもそも根本原因は削除ではなく
# cwd の取り違えである。禁止で穴を塞ぐのをやめ、削除を可逆にすることで
# 「消えたら戻らない」という被害の性質そのものを取り除く。
#
# 判定はコマンド境界に立つ `rm` / `shred` と、`find ... -delete`。
# `git rm`（履歴に残るので可逆）、`rmdir`（空ディレクトリのみ）、`grep -r` は通す。
# 前方一致の permissions.deny と違い、複合コマンド（`cd a && rm -rf b`）も捕まえる。
#
# 検知パターンの検証は、フック自身にブロックされないようスクリプト経由で行うこと
# （判定対象の文字列を Bash ツールのコマンドに載せると、このフックが弾く）。

set -uo pipefail

command=$(jq -r '.tool_input.command // ""')

# コマンド境界（行頭、; & | ( 、&& 、||）に立つ rm / shred / find ... -delete のみを見る。
# find も境界に限るのは誤検知を避けるため。`\bfind\b.*-delete` だと、コミットメッセージや
# 説明文に「find -delete でも同じ結果になる」と書いただけで弾かれる（実際に踏んだ）。
pattern='(^|[;&|(]|&&|\|\|)[[:space:]]*((rm|shred)[[:space:]]|find[[:space:]].*-delete)'

if printf '%s' "$command" | grep -qE "$pattern"; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"削除はフックで止めています。消す代わりに `trash-put <path>` で退避してください（間違えても `trash-restore <path>` で戻せます。一覧は `trash-list`）。過去に、cwd を取り違えたまま掃除のつもりで実行し、別の作業の記録ごと消した事故がありました。復元できない削除を残さないための仕組みなので、迂回せず trash-put を使ってください。git rm と rmdir は通ります。"}}
JSON
fi

exit 0
