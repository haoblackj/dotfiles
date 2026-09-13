#!/usr/bin/env bash
# Issue と PR をステータスラインにクリック可能なリンクで出す。
# 元: https://qiita.com/kuma_3838/items/00cb0b8d61ca76769c88 の節2。
#   - Issue 番号はブランチ名から取る（記事は `#123` の形。ここでは `issue-62` / `issue/10` も拾う）
#   - PR は stdin JSON の pr.number / pr.url（Claude Code が現在ブランチの open な PR を入れる）
#   - リンク先の URL は同じ JSON の workspace.repo（host / owner / name）から組む
#   - リンク化は OSC 8（終端は BEL）。色は実バイトで持ち、出力は %s に統一する
# ccstatusline の custom-command から呼ぶ。preserveColors を有効にしないと OSC 8 ごと剥がされる。
set -euo pipefail

input="$(cat)"

mapfile -t f < <(printf '%s' "$input" | jq -r '
  .workspace.repo.host // "",
  .workspace.repo.owner // "",
  .workspace.repo.name // "",
  .pr.number // "",
  .pr.url // "",
  .worktree.branch // "",
  (.cwd // .workspace.current_dir // "")
')
host="${f[0]}" owner="${f[1]}" name="${f[2]}"
pr_number="${f[3]}" pr_url="${f[4]}" branch="${f[5]}" cwd="${f[6]}"

if [[ -z "$branch" && -n "$cwd" ]]; then
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
fi

# ccstatusline は workspace を current_dir だけに作り直して渡すので workspace.repo が届かない。
# 公式は workspace.repo を「origin リモートから解析した値」と定義しているので、同じ元から組む。
# 対応する形: git@github.com:owner/name.git / ssh://git@github.com/owner/name.git / https://github.com/owner/name(.git)
if [[ -z "$host" && -n "$cwd" ]]; then
  origin="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
  origin="${origin%.git}"
  if [[ "$origin" =~ ^[A-Za-z0-9._-]+@([^:/]+):(.+)/([^/]+)$ ]]; then
    host="${BASH_REMATCH[1]}" owner="${BASH_REMATCH[2]}" name="${BASH_REMATCH[3]}"
  elif [[ "$origin" =~ ^[a-z+]+://([A-Za-z0-9._-]+@)?([^:/]+)(:[0-9]+)?/(.+)/([^/]+)$ ]]; then
    host="${BASH_REMATCH[2]}" owner="${BASH_REMATCH[4]}" name="${BASH_REMATCH[5]}"
  fi
fi

issue_number_from_branch() {
  printf '%s' "$1" | sed -n -e 's/.*#\([0-9][0-9]*\).*/\1/p' -e 's,.*issue[-/_]\([0-9][0-9]*\).*,\1,p' | head -n1
}

osc8_link() {
  # 終端は BEL（\a）。記事は ST（ESC \）だが、Claude Code 公式の statusLine の例は BEL で、
  # ST 終端では文字だけ残ってリンクにならなかった（herdr 0.9.0、2026-09-13 実機）。
  printf '\033]8;;%s\a%s\033]8;;\a' "$1" "$2"
}

color=$'\033[38;2;238;100;172m'
reset=$'\033[0m'
out=()

issue="$(issue_number_from_branch "$branch")"
if [[ -n "$issue" && -n "$host" && -n "$owner" && -n "$name" ]]; then
  out+=("$(osc8_link "https://$host/$owner/$name/issues/$issue" "Issue#$issue")")
fi

if [[ -n "$pr_number" && -n "$pr_url" ]]; then
  out+=("$(osc8_link "$pr_url" "PR#$pr_number")")
fi

if [[ ${#out[@]} -gt 0 ]]; then
  printf '%s%s%s' "$color" "${out[*]}" "$reset"
fi
