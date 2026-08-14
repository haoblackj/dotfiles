#!/bin/bash
# PostToolUse: chezmoi のソースとターゲットのどちらを編集しても取り残しが出ないようにする。
#   (A) ソース側 dot_claude/ を編集 -> chezmoi apply でターゲットへ反映
#   (B) 管理下のターゲットを直接編集 -> re-add が要ることをモデルに知らせる

input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -z "$file_path" ] && exit 0
case "$file_path" in
  /*) ;;
  *) exit 0 ;;
esac

src="${CHEZMOI_SOURCE_DIR:-$HOME/.local/share/chezmoi}"
[ -d "$src" ] || exit 0

case "$file_path" in
  "$src"/dot_claude/*)
    # (A) 従来動作
    if out=$(chezmoi apply "$HOME/.claude/" 2>&1); then
      jq -n '{"suppressOutput": true}'
    else
      jq -n --arg msg "chezmoi apply failed: $out" '{"systemMessage": $msg}'
    fi
    exit 0
    ;;
  "$src"/*)
    exit 0
    ;;
esac

# (B) 管理対象かどうかは managed 一覧のキャッシュで判定する。
# chezmoi の起動は 0.3 秒かかるので、毎回の Edit で呼ばないよう 60 分キャッシュする。
cache="${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi-managed-targets"
if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +60 2>/dev/null)" ]; then
  mkdir -p "$(dirname "$cache")"
  if chezmoi managed --path-style=absolute >"$cache.tmp" 2>/dev/null; then
    mv "$cache.tmp" "$cache"
  else
    rm -f "$cache.tmp"
    exit 0
  fi
fi
grep -qxF "$file_path" "$cache" || exit 0

srcfile=$(chezmoi source-path "$file_path" 2>/dev/null) || exit 0
jq -n --arg f "$file_path" --arg s "$srcfile" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("編集した \($f) は chezmoi 管理下(source: \($s))。この変更はソース側に未反映で、次の chezmoi apply で失われる。`chezmoi re-add \($f)` でソースへ取り込み、chezmoi リポジトリ側でコミットすること。")
  }
}'
