#!/usr/bin/env bash
# Sync Claude private memory + copyright-sensitive skills with the
# claude-private repo (cloned to ~/.local/share/claude-private via chezmoi external).
#   pull : SessionStart  -> git pull + ensure symlinks (absorb remote / bootstrap)
#   push : Stop          -> migrate new memory + commit + push
# Secrets never touch the public dotfiles repo; transcripts (*.jsonl) stay outside.
set -u

ROOT="$HOME/.local/share/claude-private"
[ -d "$ROOT/.git" ] || exit 0

# migrate_new が実体を取り込んだかどうか。取り込んだ回は自動コミットの対象を
# 絞らない（移行そのものを落とすと、リンクだけ張られて実体が追跡されない）。
MIGRATED=0

ensure_symlinks() {
  # all skills present in the private repo
  local sk_src sk_dst sk_name
  for sk_src in "$ROOT"/skills/*/; do
    [ -d "$sk_src" ] || continue
    sk_name="$(basename "$sk_src")"
    sk_dst="$HOME/.claude/skills/$sk_name"
    if [ ! -L "$sk_dst" ]; then
      [ -e "$sk_dst" ] && rm -rf "$sk_dst"
      mkdir -p "$(dirname "$sk_dst")"
      ln -s "${sk_src%/}" "$sk_dst"
    fi
  done
  # per-project memory dirs present in the private repo
  local d proj link
  for d in "$ROOT"/memory/*/; do
    [ -d "$d" ] || continue
    proj="$(basename "$d")"
    link="$HOME/.claude/projects/$proj/memory"
    [ -L "$link" ] && continue
    # don't clobber a real dir that still holds unsynced data
    if [ -d "$link" ] && [ -n "$(ls -A "$link" 2>/dev/null)" ]; then
      continue
    fi
    mkdir -p "$HOME/.claude/projects/$proj"
    [ -e "$link" ] && rm -rf "$link"
    ln -s "${d%/}" "$link"
  done
}

migrate_new() {
  # Capture real (non-symlinked) skill dirs into the private repo.
  local sk name dest
  for sk in "$HOME"/.claude/skills/*/; do
    [ -d "$sk" ] || continue
    [ -L "${sk%/}" ] && continue
    # Skip chezmoi git-repo externals (e.g. book-to-skill): they have their own
    # .git and are managed publicly via .chezmoiexternal.toml, not the private repo.
    [ -d "${sk}.git" ] && continue
    name="$(basename "$sk")"
    dest="$ROOT/skills/$name"
    mkdir -p "$dest"
    cp -a "$sk". "$dest"/ 2>/dev/null || true
    rm -rf "$dest/.git"
    rm -rf "${sk%/}"
    ln -s "$dest" "${sk%/}"
    MIGRATED=1
  done
  # Capture real (non-symlinked) memory dirs holding markdown into the repo.
  local link proj
  for link in "$HOME"/.claude/projects/*/memory; do
    [ -e "$link" ] || continue
    [ -L "$link" ] && continue
    [ -d "$link" ] || continue
    ls "$link"/*.md >/dev/null 2>&1 || continue
    proj="$(basename "$(dirname "$link")")"
    dest="$ROOT/memory/$proj"
    mkdir -p "$dest"
    cp -a "$link"/. "$dest"/ 2>/dev/null || true
    rm -rf "$link"
    ln -s "$dest" "$link"
    MIGRATED=1
  done
}

case "${1:-pull}" in
  pull)
    git -C "$ROOT" pull --ff-only >/dev/null 2>&1 || true
    ensure_symlinks
    ;;
  push)
    git -C "$ROOT" pull --ff-only >/dev/null 2>&1 || true
    migrate_new
    ensure_symlinks
    # 自動コミットの対象は memory 配下だけ。メモリ本体と埋め込みキャッシュ
    # (memory/<project>/.embeddings.json) がここに入る。skills のように
    # 「何をしたか」が残るべき変更は sync: <日時> に飲み込ませず、人が明示的に
    # コミットする。実例: bug-note スキルの追加が sync: に飲まれ、履歴の
    # 書き換えが要った（2026-09-06）。
    #
    # パススペックに '*.json' を足さないこと。埋め込みは memory 配下なので
    # 足す必要が無く、足すと skills/mulmoterminal-*/palettes.json などの
    # 同梱データまで自動コミットの対象へ戻る。
    #
    # 移行が走った回だけは全体を対象にする（リンクだけ張られて実体が
    # 追跡されない状態を避けるため）。
    # ls-files 側を落とさないこと。ワークツリーから memory/ ごと消えた回は -d が
    # 偽になるが、その削除は追跡対象なのでステージする必要がある。
    if [ "$MIGRATED" = "1" ]; then
      git -C "$ROOT" add -A
    elif [ -d "$ROOT/memory" ] || [ -n "$(git -C "$ROOT" ls-files -- memory)" ]; then
      git -C "$ROOT" add -A -- memory
    fi

    # 対象外に変更が残っていたら知らせる。黙って放置すると、次の
    # git add -A を打つ誰かのコミットへ紛れ込む。
    left=$(git -C "$ROOT" status --porcelain -- ':!memory' 2>/dev/null | head -5)
    if [ -n "$left" ]; then
      echo "[claude-private-sync] 自動コミットしていない変更があります。内容に合ったメッセージで自分でコミットしてください:" >&2
      echo "$left" >&2
    fi

    git -C "$ROOT" diff --cached --quiet && exit 0
    msg=""
    for f in "$ROOT"/.pending-commit-message.*; do
      [ -f "$f" ] || continue
      msg="${msg:+$msg$'\n'}$(cat "$f")"
      rm -f "$f"
    done
    [ -z "$msg" ] && msg="sync: $(date -Iseconds)"
    git -C "$ROOT" \
      -c user.name="haoblackj" \
      -c user.email="17177994+haoblackj@users.noreply.github.com" \
      commit -q -m "$msg" || true
    git -C "$ROOT" push -q 2>/dev/null || echo "[claude-private-sync] push failed — retry: git -C $ROOT push" >&2
    ;;
esac
exit 0
