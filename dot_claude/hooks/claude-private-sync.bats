#!/usr/bin/env bats
# mutation-target: dot_claude/hooks/executable_claude-private-sync.sh
# claude-private-sync.sh push処理のユニットテスト。
#   A. コミットメッセージのdrain機構
#   B. 自動コミット対象を memory 配下へ絞り込む挙動
#   C. memory/ が無いリポジトリでの堅牢性
set -u

# 偽のHOMEを作る。フィクスチャは必ずmktemp -dの下に置き、本番の$HOMEには触れない。
# $1 に nomemory を渡すと memory/ を持たないリポジトリになる(条件C用)。
setup_fake_home() {
  local h root
  h="$(mktemp -d)"
  root="$h/.local/share/claude-private"
  mkdir -p "$root" "$h/.claude/skills" "$h/.claude/projects"
  git -C "$root" init -q
  printf '.pending-commit-message.*\n' > "$root/.gitignore"
  git -C "$root" add .gitignore
  if [ "${1:-}" != "nomemory" ]; then
    # 自動コミットの対象は memory 配下だけなので、差分はここへ置く。
    mkdir -p "$root/memory/proj"
    printf 'base\n' > "$root/memory/proj/base.md"
    git -C "$root" add memory
  fi
  git -C "$root" -c user.name=test -c user.email=test@example.com commit -q -m "initial"
  printf '%s\n' "$h"
}

run_push() { # fake_home -> stdout捨て、stderrを返す
  { HOME="$1" bash "$SCRIPT" push >/dev/null; } 2>&1
}

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_claude-private-sync.sh"
}

teardown() {
    rm -rf -- "$H"
}

# =========================================================================
# A. コミットメッセージのdrain機構
# =========================================================================

@test "A1. メッセージファイル無し -> 従来通りsync:フォールバック" {
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    echo "content" > "$R/memory/proj/a.md"
    run_push "$H" >/dev/null
    [ "$(git -C "$R" log -1 --format=%s | cut -c1-5)" = "sync:" ]
}

@test "A2. メッセージファイル1件(他にも差分あり) -> そのまま使われ、ファイルは消える" {
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    echo "content2" > "$R/memory/proj/a.md"
    echo "chore(memory): 棚卸し実行(24.5KB->15.2KB)" > "$R/.pending-commit-message.aaa"
    run_push "$H" >/dev/null
    [ "$(git -C "$R" log -1 --format=%s)" = "chore(memory): 棚卸し実行(24.5KB->15.2KB)" ]
    [ "$(find "$R" -maxdepth 1 -name '.pending-commit-message.*' | wc -l | tr -d ' ')" = "0" ]
}

@test "A3. メッセージファイル2件(同時実行を模擬) -> 両方が結合される" {
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    echo "content3" > "$R/memory/proj/a.md"
    echo "chore(memory): 棚卸しA" > "$R/.pending-commit-message.bbb"
    echo "chore(other): 変更B" > "$R/.pending-commit-message.ccc"
    run_push "$H" >/dev/null
    msg3="$(git -C "$R" log -1 --format=%B)"
    [ "$(printf '%s' "$msg3" | grep -c '棚卸しA')" = "1" ]
    [ "$(printf '%s' "$msg3" | grep -c '変更B')" = "1" ]
}

@test "A4. .pending-commit-message.* がコミットに混入しない" {
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    echo "content4" > "$R/memory/proj/a.md"
    echo "chore(memory): テスト" > "$R/.pending-commit-message.ddd"
    run_push "$H" >/dev/null
    stat4="$(git -C "$R" show --stat --format= HEAD)"
    [ "$(printf '%s' "$stat4" | grep -c 'memory/proj/a.md')" = "1" ]
    [ "$(printf '%s' "$stat4" | grep -c 'pending-commit-message')" = "0" ]
}

@test "A5. メッセージファイルのみ(他に差分無し) -> コミットは作られず、ファイルは残る" {
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    echo "chore(memory): 孤立メッセージ" > "$R/.pending-commit-message.eee"
    before="$(git -C "$R" rev-list --count HEAD)"
    run_push "$H" >/dev/null
    [ "$(git -C "$R" rev-list --count HEAD)" = "$before" ]
    [ "$(find "$R" -maxdepth 1 -name '.pending-commit-message.*' | wc -l | tr -d ' ')" = "1" ]
}

# =========================================================================
# B. 自動コミット対象の絞り込み
# =========================================================================

@test "B1. memory配下(md/.embeddings.json)は入り、skills配下は入らず警告になる" {
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    echo "note" > "$R/memory/proj/note.md"
    echo '{"v":1}' > "$R/memory/proj/.embeddings.json"
    mkdir -p "$R/skills/bug-note"
    echo "skill body" > "$R/skills/bug-note/SKILL.md"
    err_b1="$(run_push "$H")"
    stat_b1="$(git -C "$R" show --stat --format= HEAD)"
    [ "$(printf '%s' "$stat_b1" | grep -c 'memory/proj/note.md')" = "1" ]
    [ "$(printf '%s' "$stat_b1" | grep -c 'memory/proj/.embeddings.json')" = "1" ]
    [ "$(printf '%s' "$stat_b1" | grep -c 'skills')" = "0" ]
    [ "$(printf '%s' "$err_b1" | grep -c '^?? skills/$')" = "1" ]
}

@test "B2. skills配下の同梱データ(*.json)が対象に入らない" {
    # パススペックへ '*.json' を足すと戻る回帰。独立したケースとして持つ。
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    mkdir -p "$R/skills/mulmoterminal-xxx"
    echo '{"palette":"old"}' > "$R/skills/mulmoterminal-xxx/palettes.json"
    git -C "$R" add skills
    git -C "$R" -c user.name=test -c user.email=test@example.com commit -q -m "add skill data"
    echo '{"palette":"new"}' > "$R/skills/mulmoterminal-xxx/palettes.json"
    echo "note" > "$R/memory/proj/note.md"
    run_push "$H" >/dev/null
    stat_b2="$(git -C "$R" show --stat --format= HEAD)"
    [ "$(printf '%s' "$stat_b2" | grep -c 'memory/proj/note.md')" = "1" ]
    [ "$(printf '%s' "$stat_b2" | grep -c 'palettes.json')" = "0" ]
}

@test "B3. MIGRATED=1 の回は skills も含め全体が対象になる" {
    # 偽HOMEの.claude/skills配下にシンボリックリンクでない実ディレクトリを置くと
    # migrate_new が走る(.git を含むディレクトリはスキップされるので入れない)。
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    mkdir -p "$H/.claude/skills/migrated-skill"
    echo "migrated body" > "$H/.claude/skills/migrated-skill/SKILL.md"
    run_push "$H" >/dev/null
    stat_b3="$(git -C "$R" show --stat --format= HEAD)"
    [ "$(printf '%s' "$stat_b3" | grep -c 'skills/migrated-skill/SKILL.md')" = "1" ]
}

@test "B4. 対象外に変更が無いときは警告が出ない" {
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    echo "note" > "$R/memory/proj/note.md"
    err_b4="$(run_push "$H")"
    [ "$(printf '%s' "$err_b4" | grep -c '自動コミットしていない変更があります')" = "0" ]
}

# =========================================================================
# C. memory/ が無いリポジトリでの堅牢性
# =========================================================================

@test "C1. memory/ が無くても add がfatalを吐かない" {
    H="$(setup_fake_home nomemory)"; R="$H/.local/share/claude-private"
    echo "outside" > "$R/dummy.txt"
    err_c1="$(run_push "$H")"
    [ "$(printf '%s' "$err_c1" | grep -c 'fatal:')" = "0" ]
}
