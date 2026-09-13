#!/usr/bin/env bash
# 現在ブランチの Issue と PR の番号をステータスラインに出す（表示だけ、リンクではない）。
#   - Issue 番号はブランチ名から取る（`#123` / `issue-62` / `issue/10` の形。github-refs.sh）
#   - PR は stdin JSON の pr.number（Claude Code が現在ブランチの open な PR を入れる）
# 開くのは herdr の prefix+g（local.open-github プラグイン）。OSC 8 のリンクは Claude Code の
# fullscreen 描画が剥がすので、ここでは出さない（2026-09-13 実機、リーダーの裁定）。
# ccstatusline の custom-command から呼ぶ。色は ccstatusline 側の color で付ける。
set -euo pipefail

input="$(cat)"

mapfile -t f < <(printf '%s' "$input" | jq -r '
  .pr.number // "",
  .worktree.branch // "",
  (.cwd // .workspace.current_dir // "")
')
pr_number="${f[0]}" branch="${f[1]}" cwd="${f[2]}"

if [[ -z "$branch" && -n "$cwd" ]]; then
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
fi

# shellcheck source=/dev/null
. "$(dirname "$0")/github-refs.sh"

out=()
issue="$(issue_number_from_branch "$branch")"
[[ -n "$issue" ]] && out+=("Issue#$issue")
[[ -n "$pr_number" ]] && out+=("PR#$pr_number")

if [[ ${#out[@]} -gt 0 ]]; then
  printf '%s' "${out[*]}"
fi
