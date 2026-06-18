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

migrate_externals() {
  local TOML="$HOME/.local/share/chezmoi/.chezmoiexternal.toml"
  local CHEZMOI_DIR="$HOME/.local/share/chezmoi"
  local sk name key url changed=0
  for sk in "$HOME"/.claude/skills/*/; do
    [ -d "$sk" ] || continue
    [ -L "${sk%/}" ] && continue
    [ -d "${sk}.git" ] || continue
    name="$(basename "${sk%/}")"
    key=".claude/skills/$name"
    grep -qF "\"$key\"" "$TOML" 2>/dev/null && continue
    url="$(git -C "${sk%/}" remote get-url origin 2>/dev/null)" || continue
    printf '\n["%s"]\ntype = "git-repo"\nurl = "%s"\nrefreshPeriod = "168h"\nclone.args = ["--depth", "1"]\n' \
      "$key" "$url" >> "$TOML"
    changed=1
  done
  if [ "$changed" = "1" ]; then
    git -C "$CHEZMOI_DIR" add .chezmoiexternal.toml
    git -C "$CHEZMOI_DIR" diff --cached --quiet && return
    git -C "$CHEZMOI_DIR" \
      -c user.name="haoblackj" \
      -c user.email="17177994+haoblackj@users.noreply.github.com" \
      commit -q -m "auto: register external skills in chezmoiexternal.toml" || true
    git -C "$CHEZMOI_DIR" push -q 2>/dev/null || \
      echo "[claude-private-sync] dotfiles push failed" >&2
  fi
}

migrate_new() {
  # Capture real (non-symlinked) skill dirs into the private repo.
  # Skip chezmoi externals (git-repo clones that have their own .git).
  local sk name dest
  for sk in "$HOME"/.claude/skills/*/; do
    [ -d "$sk" ] || continue
    [ -L "${sk%/}" ] && continue
    [ -d "${sk}.git" ] && continue
    name="$(basename "$sk")"
    dest="$ROOT/skills/$name"
    mkdir -p "$dest"
    cp -a "$sk". "$dest"/ 2>/dev/null || true
    rm -rf "${sk%/}"
    ln -s "$dest" "${sk%/}"
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
  done
}

case "${1:-pull}" in
  pull)
    git -C "$ROOT" pull --ff-only >/dev/null 2>&1 || true
    ensure_symlinks
    ;;
  push)
    git -C "$ROOT" pull --ff-only >/dev/null 2>&1 || true
    migrate_externals
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
