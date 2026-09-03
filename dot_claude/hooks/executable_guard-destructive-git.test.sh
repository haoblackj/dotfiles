#!/usr/bin/env bash
# guard-destructive-git.sh のユニットテスト。
#
# 危険なコマンドは一切実行しない。フックへ入力 JSON を与え、返る判定だけを見る。
#
# フック本体の名前は置き場所で変わる。chezmoi のソース側では
# executable_guard-destructive-git.sh、ターゲット（~/.claude/hooks/）では
# guard-destructive-git.sh。どちらでも動くよう両方を試す。
# 既存のテストはこれを怠って配置先で exit 127 になり、何も検証していなかった。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK=""
for cand in "$HERE/guard-destructive-git.sh" "$HERE/executable_guard-destructive-git.sh"; do
  if [ -f "$cand" ]; then HOOK="$cand"; break; fi
done
if [ -z "$HOOK" ]; then
  echo "フック本体が見つからない: $HERE/guard-destructive-git.sh も executable_guard-destructive-git.sh も無い" >&2
  exit 1
fi

pass=0
fail=0

# コマンド文字列を PreToolUse の入力 JSON に載せてフックへ流し、判定を返す。
decide() {
  local cmd="$1" payload out code
  payload=$(jq -nc --arg c "$cmd" \
    '{session_id:"test",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')
  out=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)
  code=$?
  if [ "$code" -ne 0 ]; then
    printf 'hook-exit-%s' "$code"
    return
  fi
  if [ -z "$out" ]; then
    printf 'allow'
    return
  fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"'
}

expect_deny() {
  local cmd="$1" got
  got=$(decide "$cmd")
  if [ "$got" = "deny" ]; then
    pass=$((pass + 1)); printf 'ok   - deny  : %s\n' "$cmd"
  else
    fail=$((fail + 1)); printf 'FAIL - deny  : %s\n   expected: [deny]\n   actual:   [%s]\n' "$cmd" "$got"
  fi
}

expect_allow() {
  local cmd="$1" got
  got=$(decide "$cmd")
  if [ "$got" = "allow" ]; then
    pass=$((pass + 1)); printf 'ok   - allow : %s\n' "$cmd"
  else
    fail=$((fail + 1)); printf 'FAIL - allow : %s\n   expected: [allow]\n   actual:   [%s]\n' "$cmd" "$got"
  fi
}

echo "== 塞ぐべき形: git reset --hard =="
expect_deny 'git reset --hard'
expect_deny 'git reset --hard HEAD~1'
expect_deny 'git reset --hard origin/main'
expect_deny 'git -C /tmp/x reset --hard'
expect_deny 'git -c user.name=x reset --hard'
expect_deny 'cd /tmp/x && git reset --hard'
expect_deny 'git status; git reset --hard'
expect_deny '/usr/bin/git reset --hard'

echo "== 塞ぐべき形: git push --force =="
expect_deny 'git push --force'
expect_deny 'git push -f'
expect_deny 'git push --force origin main'
expect_deny 'git push origin main -f'
expect_deny 'git push -fu origin main'
expect_deny 'git -C /tmp/x push --force'
expect_deny 'git push --force-with-lease --force'

echo "== 塞ぐべき形: git clean -f =="
expect_deny 'git clean -f'
expect_deny 'git clean --force'
expect_deny 'git clean -fd'
expect_deny 'git clean -xdf'
expect_deny 'git clean -df -e node_modules'
expect_deny 'git -C /tmp/x clean --force'
expect_deny 'git --git-dir=/tmp/x/.git clean -f'

echo "== 塞ぐべき形: git branch -D =="
expect_deny 'git branch -D feature'
expect_deny 'git branch --delete --force feature'
expect_deny 'git branch -d --force feature'
expect_deny 'git branch --force --delete feature'
expect_deny 'git branch --delete -f feature'
expect_deny 'git -C /tmp/x branch --delete --force feature'

echo "== 塞ぐべき形: git checkout -- =="
expect_deny 'git checkout -- .'
expect_deny 'git checkout -- src/file.txt'
expect_deny 'git checkout HEAD -- src/file.txt'
expect_deny 'git -C /tmp/x checkout -- .'

echo "== 塞いではいけない形: --force-with-lease =="
expect_allow 'git push --force-with-lease'
expect_allow 'git push --force-with-lease=main:abc1234'
expect_allow 'git push --force-with-lease --force-if-includes'
expect_allow 'git -C /tmp/x push --force-with-lease origin main'

echo "== 塞いではいけない形: git clean の dry-run =="
expect_allow 'git clean -n'
expect_allow 'git clean --dry-run'
expect_allow 'git clean -nd'
expect_allow 'git clean -xdn'
expect_allow 'git clean --dry-run --force'

echo "== 塞いではいけない形: 安全な巻き戻しと日常操作 =="
expect_allow 'git reset --soft HEAD~1'
expect_allow 'git reset HEAD file.txt'
expect_allow 'git reset --mixed'
expect_allow 'git restore .'
expect_allow 'git restore --staged --worktree src/file.txt'
expect_allow 'git checkout main'
expect_allow 'git checkout -b feature'
expect_allow 'git branch -d feature'
expect_allow 'git branch --delete feature'
expect_allow 'git branch -a'
expect_allow 'git push origin main'
expect_allow 'git push -u origin feature'
expect_allow 'git status'
expect_allow 'git log --oneline -20'
expect_allow 'git diff -- src/'
expect_allow 'git stash'
expect_allow 'git worktree list'
expect_allow 'ls -la'

echo "== 塞いではいけない形: 文字列として現れるだけ =="
expect_allow 'echo "git reset --hard は使わない"'
expect_allow 'git commit -m "git reset --hard を提案しない旨を追記"'
expect_allow 'grep -n "git clean -f" docs/rules.md'
expect_allow 'git config --global alias.nuke "reset --hard"'

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
