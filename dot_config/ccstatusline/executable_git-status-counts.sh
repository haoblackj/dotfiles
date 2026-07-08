#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
cwd="$(printf '%s' "$input" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("cwd") or d.get("workspace", {}).get("current_dir") or ".")')"

cd "$cwd" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

git status --porcelain 2>/dev/null | awk '
{
  x = substr($0, 1, 1)
  y = substr($0, 2, 1)
  if (x == "?" && y == "?") { untracked++; next }
  if (x != " ") staged++
  if (y != " ") unstaged++
}
END {
  out = ""
  if (staged > 0) out = out "staged " staged " "
  if (unstaged > 0) out = out "unstaged " unstaged " "
  if (untracked > 0) out = out "untracked " untracked
  printf "%s", out
}'
