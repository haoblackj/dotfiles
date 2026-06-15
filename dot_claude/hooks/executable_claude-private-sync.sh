#!/usr/bin/env bash
# Sync Claude private memory + copyright-sensitive skills with the
# claude-private repo (cloned to ~/.local/share/claude-private via chezmoi external).
#   pull : SessionStart  -> git pull + ensure symlinks (absorb remote / bootstrap)
#   push : Stop          -> migrate new memory + commit + push
# Secrets never touch the public dotfiles repo; transcripts (*.jsonl) stay outside.
set -u

ROOT="$HOME/.local/share/claude-private"
[ -d "$ROOT/.git" ] || exit 0

ensure_symlinks() {
  # learning-efficiency-book skill (stable path)
  local sk_src="$ROOT/skills/learning-efficiency-book"
  local sk_dst="$HOME/.claude/skills/learning-efficiency-book"
  if [ -d "$sk_src" ] && [ ! -L "$sk_dst" ]; then
    [ -e "$sk_dst" ] && rm -rf "$sk_dst"
    mkdir -p "$(dirname "$sk_dst")"
    ln -s "$sk_src" "$sk_dst"
  fi
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
  # Capture real (non-symlinked) memory dirs holding markdown into the repo.
  local link proj dest
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
    git -C "$ROOT" add -A
    git -C "$ROOT" diff --cached --quiet && exit 0
    git -C "$ROOT" \
      -c user.name="haoblackj" \
      -c user.email="17177994+haoblackj@users.noreply.github.com" \
      commit -q -m "sync: $(date -Iseconds)" || true
    git -C "$ROOT" push -q 2>/dev/null || echo "[claude-private-sync] push failed — retry: git -C $ROOT push" >&2
    ;;
esac
exit 0
