#!/usr/bin/env bash
# Pane `local.open-github.picker`: 現在ブランチの issue と PR を fzf で選び、ブラウザで開く。
#
# オーバーレイ（実 TTY）の中で走る。cwd は open.sh がフォーカス中ペインの cwd を渡す。
# 候補は「ブランチ名の issue 番号」（~/.config/ccstatusline/github-refs.sh、ステータスラインと
# 同じ取り方）と「現在ブランチの open な PR」（gh pr view）。候補が1つでも選ばせる。
# 開くのは gh の --web と同じ経路（xdg-open → wslview → Windows のブラウザ）。
# このスクリプトが終わればオーバーレイは自動で閉じる。
set -uo pipefail

# herdr はプラグインを最小の PATH で走らせるので、道具のある場所を後ろに足す
PATH="$PATH:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"

pause_and_exit() {
  echo "open-github: $*" >&2
  sleep 2
  exit 1
}

for tool in fzf jq gh git xdg-open; do
  command -v "$tool" >/dev/null 2>&1 || pause_and_exit "$tool が無い"
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || pause_and_exit "git リポジトリでない: $(pwd)"

# shellcheck source=/dev/null
. "$HOME/.config/ccstatusline/github-refs.sh"

candidates=()

branch="$(git branch --show-current 2>/dev/null || true)"
issue="$(issue_number_from_branch "$branch")"
if [[ -n "$issue" ]]; then
  origin="$(git remote get-url origin 2>/dev/null || true)"
  origin="${origin%.git}"
  repo_url=""
  if [[ "$origin" =~ ^[A-Za-z0-9._-]+@([^:/]+):(.+)$ ]]; then
    repo_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$origin" =~ ^[a-z+]+://([A-Za-z0-9._-]+@)?([^:/]+)(:[0-9]+)?/(.+)$ ]]; then
    repo_url="https://${BASH_REMATCH[2]}/${BASH_REMATCH[4]}"
  fi
  if [[ -n "$repo_url" ]]; then
    title="$(gh issue view "$issue" --json title -q .title 2>/dev/null || true)"
    candidates+=("Issue #$issue	${title:-（タイトル取得不可）}	$repo_url/issues/$issue")
  fi
fi

pr_json="$(gh pr view --json number,title,url 2>/dev/null || true)"
if [[ -n "$pr_json" ]]; then
  pr_number="$(printf '%s' "$pr_json" | jq -r .number)"
  pr_title="$(printf '%s' "$pr_json" | jq -r .title)"
  pr_url="$(printf '%s' "$pr_json" | jq -r .url)"
  candidates+=("PR #$pr_number	$pr_title	$pr_url")
fi

[[ ${#candidates[@]} -gt 0 ]] || pause_and_exit "ブランチ '$branch' に issue 番号も open な PR も無い"

selected="$(
  printf '%s\n' "${candidates[@]}" \
    | fzf --delimiter='\t' --with-nth=1,2 --prompt="open on GitHub> " --reverse \
          --header='enter: ブラウザで開く · esc: やめる'
)" || exit 0
[[ -n "$selected" ]] || exit 0

url="${selected##*	}"
xdg-open "$url" >/dev/null 2>&1 &
disown
exit 0
