#!/usr/bin/env bash
# Claude Code on the web（クラウドセッション）へ、dotfiles の Claude Code 設定の
# うち環境に依存しない部分だけを配る。クラウド環境の Setup script から呼ぶ:
#
#   curl -fsSL https://raw.githubusercontent.com/haoblackj/dotfiles/main/install-cloud.sh | bash
#
# 何を配り、何を配らないか、足すときの判断基準はREADME「クラウドセッション」の節。
# ここを変えたらそちらの表も合わせる。
#
# 失敗しても exit 0 で抜ける。取得に失敗しただけでクラウド環境のセットアップ
# 全体を落とさないため（本来の作業は設定なしでも進められる）。
set -u

REPO_URL="https://github.com/haoblackj/dotfiles.git"
REF="${DOTFILES_REF:-main}"
# テスト用: clone せずにこのディレクトリをソースとして使う
SRC="${DOTFILES_SRC:-}"

# dot_claude/ から ~/.claude/ へそのまま写すもの。chezmoi の属性つきの名前
# （executable_ / dot_ / *.tmpl など）は写すと名前が変わらないので含めない。
COPY_ITEMS=(CLAUDE.md agents rules output-styles)

# linked/claude/settings.json から ~/.claude/settings.json へ抜き出すキー。
# hooks / statusLine / enabledPlugins などの手元専用のキーは入れない。
SETTINGS_KEYS=(outputStyle language effortLevel)

log() { echo "[install-cloud] $*" >&2; }

# 手元の chezmoi 管理の ~/.claude を上書きしない
if [ -L "$HOME/.claude/settings.json" ] || [ -d "$HOME/.local/share/chezmoi/.git" ]; then
  log "chezmoi 管理の環境で動いているので何もしない（クラウド専用のスクリプト）"
  exit 1
fi

tmp=""
trap '[ -n "$tmp" ] && rm -rf "$tmp"' EXIT

if [ -z "$SRC" ]; then
  tmp=$(mktemp -d)
  if ! git clone -q --depth 1 --branch "$REF" "$REPO_URL" "$tmp/dotfiles"; then
    log "dotfiles の clone に失敗した（$REPO_URL @ $REF）。設定なしで続ける"
    exit 0
  fi
  SRC="$tmp/dotfiles"
fi

mkdir -p "$HOME/.claude"

# 1. dot_claude/ の中身
for item in "${COPY_ITEMS[@]}"; do
  from="$SRC/dot_claude/$item"
  if [ ! -e "$from" ]; then
    log "見つからないので飛ばす: dot_claude/$item"
    continue
  fi
  # chezmoi の属性つきの名前が混ざったら知らせる（写した先で名前が化ける）
  odd=$(find "$from" -regextype posix-extended \
    -regex '.*/(executable_|private_|readonly_|dot_|symlink_|empty_|exact_|create_|modify_|remove_)[^/]*|.*\.tmpl' \
    2>/dev/null)
  [ -n "$odd" ] && log "chezmoi の属性つきの名前がある。そのまま写すので名前を確かめる: $odd"
  rm -rf "${HOME:?}/.claude/$item"
  cp -R "$from" "$HOME/.claude/$item"
  log "配置: ~/.claude/$item"
done

# 2. settings.json の一部のキー（既存の settings.json があればマージ）
src_settings="$SRC/linked/claude/settings.json"
dst_settings="$HOME/.claude/settings.json"
if [ -f "$src_settings" ] && command -v jq >/dev/null 2>&1; then
  keys_json=$(printf '%s\n' "${SETTINGS_KEYS[@]}" | jq -R . | jq -sc .)
  [ -f "$dst_settings" ] || echo '{}' >"$dst_settings"
  if jq --slurpfile src "$src_settings" --argjson keys "$keys_json" \
    '. + ($src[0] | with_entries(select(.key as $k | $keys | index($k))))' \
    "$dst_settings" >"$dst_settings.tmp"; then
    mv "$dst_settings.tmp" "$dst_settings"
    log "配置: ~/.claude/settings.json（${SETTINGS_KEYS[*]}）"
  else
    rm -f "$dst_settings.tmp"
    log "settings.json のマージに失敗した"
  fi
else
  log "settings.json を飛ばす（ソースが無いか jq が無い）"
fi

# 3. .chezmoiexternal.toml の external のうち ~/.claude 配下のもの（公開スキル）。
#    ~/.claude の外（claude-private など非公開のもの）は対象にしない。
ext="$SRC/.chezmoiexternal.toml"
if [ -f "$ext" ]; then
  awk '
    /^\[/ { t = $0; gsub(/^\["|"\]$/, "", t) }
    /^url *=/ { u = $0; sub(/^url *= *"/, "", u); sub(/".*$/, "", u); if (t ~ /^\.claude\//) print t, u }
  ' "$ext" | while read -r target url; do
    dest="$HOME/$target"
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    if git clone -q --depth 1 "$url" "$dest"; then
      log "配置: ~/$target"
    else
      log "clone に失敗したので飛ばす: $url"
    fi
  done
fi

exit 0
