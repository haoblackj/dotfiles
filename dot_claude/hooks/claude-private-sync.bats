#!/usr/bin/env bats
# claude-private-sync.sh push処理のユニットテスト。
#   A. コミットメッセージのdrain機構
#   B. 自動コミット対象を memory 配下へ絞り込む挙動
set -u

# 偽のHOMEを作る。フィクスチャは必ずmktemp -dの下に置き、本番の$HOMEには触れない。
setup_fake_home() {
  local h root
  h="$(mktemp -d)"
  root="$h/.local/share/claude-private"
  mkdir -p "$root" "$h/.claude/skills" "$h/.claude/projects"
  git -C "$root" init -q
  printf '.pending-commit-message.*\n' > "$root/.gitignore"
  git -C "$root" add .gitignore
  # 自動コミットの対象は memory 配下だけなので、差分はここへ置く。
  mkdir -p "$root/memory/proj"
  printf 'base\n' > "$root/memory/proj/base.md"
  git -C "$root" add memory
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

@test "A2. メッセージファイル1件(他にも差分あり) -> そのまま使われ、ファイルは消える" {
    H="$(setup_fake_home)"; R="$H/.local/share/claude-private"
    echo "content2" > "$R/memory/proj/a.md"
    echo "chore(memory): 棚卸し実行(24.5KB->15.2KB)" > "$R/.pending-commit-message.aaa"
    run_push "$H" >/dev/null
    [ "$(git -C "$R" log -1 --format=%s)" = "chore(memory): 棚卸し実行(24.5KB->15.2KB)" ]
    [ "$(find "$R" -maxdepth 1 -name '.pending-commit-message.*' | wc -l | tr -d ' ')" = "0" ]
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
