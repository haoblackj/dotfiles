#!/usr/bin/env bash
# claude-private-sync.sh push処理のユニットテスト(メッセージdrain機構)。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/executable_claude-private-sync.sh"
pass=0
fail=0

check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf 'ok   - %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL - %s\n   expected: [%s]\n   actual:   [%s]\n' "$1" "$2" "$3"
  fi
}

setup_fake_home() {
  local h
  h="$(mktemp -d)"
  mkdir -p "$h/.local/share/claude-private"
  git -C "$h/.local/share/claude-private" init -q
  printf '.pending-commit-message.*\n' > "$h/.local/share/claude-private/.gitignore"
  git -C "$h/.local/share/claude-private" add .gitignore
  git -C "$h/.local/share/claude-private" -c user.name=test -c user.email=test@example.com \
    commit -q -m "initial"
  printf '%s\n' "$h"
}

# --- 1. メッセージファイル無し -> 従来通りsync:フォールバック ---
HOME1="$(setup_fake_home)"
echo "content" > "$HOME1/.local/share/claude-private/dummy.txt"
HOME="$HOME1" bash "$SCRIPT" push >/dev/null 2>&1
msg1="$(git -C "$HOME1/.local/share/claude-private" log -1 --format=%s)"
check "メッセージ無し -> sync:接頭辞" "sync:" "${msg1:0:5}"

# --- 2. メッセージファイル1件(他にも差分あり) -> そのままコミットメッセージに使われ、ファイルは消える ---
HOME2="$(setup_fake_home)"
echo "content2" > "$HOME2/.local/share/claude-private/dummy2.txt"
echo "chore(memory): 棚卸し実行(24.5KB->15.2KB)" > "$HOME2/.local/share/claude-private/.pending-commit-message.aaa"
HOME="$HOME2" bash "$SCRIPT" push >/dev/null 2>&1
msg2="$(git -C "$HOME2/.local/share/claude-private" log -1 --format=%s)"
check "1件のメッセージがそのまま使われる" "chore(memory): 棚卸し実行(24.5KB->15.2KB)" "$msg2"
check "消費後にファイルが消える" "0" "$(find "$HOME2/.local/share/claude-private" -maxdepth 1 -name '.pending-commit-message.*' | wc -l | tr -d ' ')"

# --- 3. メッセージファイル2件(同時実行を模擬、他にも差分あり) -> 両方が結合される ---
HOME3="$(setup_fake_home)"
echo "content3" > "$HOME3/.local/share/claude-private/dummy3.txt"
echo "chore(memory): 棚卸しA" > "$HOME3/.local/share/claude-private/.pending-commit-message.bbb"
echo "chore(other): 変更B" > "$HOME3/.local/share/claude-private/.pending-commit-message.ccc"
HOME="$HOME3" bash "$SCRIPT" push >/dev/null 2>&1
msg3="$(git -C "$HOME3/.local/share/claude-private" log -1 --format=%B)"
check "1件目のメッセージを含む" "1" "$(printf '%s' "$msg3" | grep -c '棚卸しA')"
check "2件目のメッセージも含む" "1" "$(printf '%s' "$msg3" | grep -c '変更B')"

# --- 4. .pending-commit-message.* がコミットに混入しない(ゴーストコミット無し) ---
HOME4="$(setup_fake_home)"
echo "content4" > "$HOME4/.local/share/claude-private/dummy4.txt"
echo "chore(memory): テスト" > "$HOME4/.local/share/claude-private/.pending-commit-message.ddd"
HOME="$HOME4" bash "$SCRIPT" push >/dev/null 2>&1
files_in_commit="$(git -C "$HOME4/.local/share/claude-private" show --stat --format= HEAD)"
check "メッセージファイル自体はコミットされない" "0" "$(printf '%s' "$files_in_commit" | grep -c 'pending-commit-message')"

# --- 5. メッセージファイルのみ(他に差分無し) -> コミットは作られず、メッセージファイルは残る(消えない) ---
HOME5="$(setup_fake_home)"
echo "chore(memory): 孤立メッセージ" > "$HOME5/.local/share/claude-private/.pending-commit-message.eee"
commit_count_before="$(git -C "$HOME5/.local/share/claude-private" rev-list --count HEAD)"
HOME="$HOME5" bash "$SCRIPT" push >/dev/null 2>&1
commit_count_after="$(git -C "$HOME5/.local/share/claude-private" rev-list --count HEAD)"
check "他に差分が無ければ新規コミットは作られない" "$commit_count_before" "$commit_count_after"
check "差分が無い間、メッセージファイルは消えずに残る" "1" "$(find "$HOME5/.local/share/claude-private" -maxdepth 1 -name '.pending-commit-message.*' | wc -l | tr -d ' ')"

for h in "$HOME1" "$HOME2" "$HOME3" "$HOME4" "$HOME5"; do rm -rf "$h"; done

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
