#!/usr/bin/env bats
# mutation-target: dot_claude/hooks/executable_guard-destructive-git.sh
# guard-destructive-git.sh のユニットテスト。
#
# 危険なコマンドは一切実行しない。フックへ入力 JSON を与え、返る判定だけを見る。
set -u

# コマンド文字列を PreToolUse の入力 JSON に載せてフックへ流し、判定を返す。
decide() {
  local cmd="$1" payload out code
  payload=$(jq -nc --arg c "$cmd" \
    '{session_id:"test",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')
  out=$(printf '%s' "$payload" | bash "$SCRIPT" 2>/dev/null)
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

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_guard-destructive-git.sh"
}

@test "塞ぐべき形: git reset --hard" {
    local cmd
    for cmd in \
        'git reset --hard' \
        'git reset --hard HEAD~1' \
        'git reset --hard origin/main' \
        'git -C /tmp/x reset --hard' \
        'git -c user.name=x reset --hard' \
        'cd /tmp/x && git reset --hard' \
        'git status; git reset --hard' \
        '/usr/bin/git reset --hard'; do
        run decide "$cmd"
        [ "$output" = "deny" ]
    done
}

@test "塞ぐべき形: git push --force" {
    local cmd
    for cmd in \
        'git push --force' \
        'git push -f' \
        'git push --force origin main' \
        'git push origin main -f' \
        'git push -fu origin main' \
        'git -C /tmp/x push --force' \
        'git push --force-with-lease --force'; do
        run decide "$cmd"
        [ "$output" = "deny" ]
    done
}

@test "塞ぐべき形: git clean -f" {
    local cmd
    for cmd in \
        'git clean -f' \
        'git clean --force' \
        'git clean -fd' \
        'git clean -xdf' \
        'git clean -df -e node_modules' \
        'git -C /tmp/x clean --force' \
        'git --git-dir=/tmp/x/.git clean -f'; do
        run decide "$cmd"
        [ "$output" = "deny" ]
    done
}

@test "塞ぐべき形: git branch -D" {
    local cmd
    for cmd in \
        'git branch -D feature' \
        'git branch --delete --force feature' \
        'git branch -d --force feature' \
        'git branch --force --delete feature' \
        'git branch --delete -f feature' \
        'git -C /tmp/x branch --delete --force feature'; do
        run decide "$cmd"
        [ "$output" = "deny" ]
    done
}

@test "塞ぐべき形: git checkout --" {
    local cmd
    for cmd in \
        'git checkout -- .' \
        'git checkout -- src/file.txt' \
        'git checkout HEAD -- src/file.txt' \
        'git -C /tmp/x checkout -- .'; do
        run decide "$cmd"
        [ "$output" = "deny" ]
    done
}

@test "塞いではいけない形: --force-with-lease" {
    local cmd
    for cmd in \
        'git push --force-with-lease' \
        'git push --force-with-lease=main:abc1234' \
        'git push --force-with-lease --force-if-includes' \
        'git -C /tmp/x push --force-with-lease origin main'; do
        run decide "$cmd"
        [ "$output" = "allow" ]
    done
}

@test "塞いではいけない形: git clean の dry-run" {
    local cmd
    for cmd in \
        'git clean -n' \
        'git clean --dry-run' \
        'git clean -nd' \
        'git clean -xdn' \
        'git clean --dry-run --force'; do
        run decide "$cmd"
        [ "$output" = "allow" ]
    done
}

@test "塞いではいけない形: 安全な巻き戻しと日常操作" {
    local cmd
    for cmd in \
        'git reset --soft HEAD~1' \
        'git reset HEAD file.txt' \
        'git reset --mixed' \
        'git restore .' \
        'git restore --staged --worktree src/file.txt' \
        'git checkout main' \
        'git checkout -b feature' \
        'git branch -d feature' \
        'git branch --delete feature' \
        'git branch -a' \
        'git push origin main' \
        'git push -u origin feature' \
        'git status' \
        'git log --oneline -20' \
        'git diff -- src/' \
        'git stash' \
        'git worktree list' \
        'ls -la'; do
        run decide "$cmd"
        [ "$output" = "allow" ]
    done
}

@test "塞いではいけない形: 文字列として現れるだけ" {
    local cmd
    for cmd in \
        'echo "git reset --hard は使わない"' \
        'git commit -m "git reset --hard を提案しない旨を追記"' \
        'grep -n "git clean -f" docs/rules.md' \
        'git config --global alias.nuke "reset --hard"'; do
        run decide "$cmd"
        [ "$output" = "allow" ]
    done
}
