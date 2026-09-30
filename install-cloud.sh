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
SETTINGS_KEYS=(outputStyle language)

log() { echo "[install-cloud] $*" >&2; }

# 手元の chezmoi 管理の ~/.claude を上書きしない。ソースの置き場所は
# install.sh の --source で動きうるので、chezmoi 本体の有無でも見る
# （クラウドのコンテナには chezmoi が無い）。
if [ -L "$HOME/.claude/settings.json" ] || [ -d "$HOME/.local/share/chezmoi/.git" ] ||
  command -v chezmoi >/dev/null 2>&1; then
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
    -regex '.*/(executable_|private_|readonly_|literal_|encrypted_|dot_|symlink_|empty_|exact_|create_|modify_|remove_|run_)[^/]*|.*\.(tmpl|age|asc|literal)' \
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
  # 空のファイルは jq が何も出さずに成功するので、中身が無ければ {} から始める
  [ -s "$dst_settings" ] || echo '{}' >"$dst_settings"
  if jq --slurpfile src "$src_settings" \
    '. + ($src[0] | with_entries(select(.key | IN($ARGS.positional[]))))' \
    "$dst_settings" --args "${SETTINGS_KEYS[@]}" >"$dst_settings.tmp" &&
    [ -s "$dst_settings.tmp" ]; then
    mv "$dst_settings.tmp" "$dst_settings"
    log "配置: ~/.claude/settings.json（${SETTINGS_KEYS[*]}）"
  else
    rm -f "$dst_settings.tmp"
    log "settings.json のマージに失敗した"
  fi
else
  log "settings.json を飛ばす（ソースが無いか jq が無い）"
fi

# 3. .chezmoiexternal.toml の external のうち ~/.claude 配下の git-repo（公開スキル）。
#    ~/.claude の外（claude-private など非公開のもの）と、git-repo 以外の type
#    （archive / file）は対象にしない。clone.args などのオプションは読まない。
ext="$SRC/.chezmoiexternal.toml"
if [ -f "$ext" ]; then
  targets=$(python3 - "$ext" <<'EOF'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    for target, spec in tomllib.load(f).items():
        if not target.startswith(".claude/"):
            continue
        if spec.get("type") != "git-repo":
            print(f"SKIP {target} {spec.get('type')}")
            continue
        print(f"GIT {target} {spec['url']}")
EOF
  ) || { log ".chezmoiexternal.toml を読めなかったので external を飛ばす"; targets=""; }
  while read -r kind target url; do
    [ -n "$kind" ] || continue
    if [ "$kind" = SKIP ]; then
      log "git-repo 以外の external は飛ばす: $target ($url)"
      continue
    fi
    dest="$HOME/$target"
    # 一時ディレクトリへ clone し、成功したときだけ差し替える（失敗で既存を失わない）
    staging=$(mktemp -d)
    if git clone -q --depth 1 "$url" "$staging/repo" </dev/null; then
      rm -rf "$dest"
      mkdir -p "$(dirname "$dest")"
      mv "$staging/repo" "$dest"
      log "配置: ~/$target"
    else
      log "clone に失敗したので飛ばす: $url"
    fi
    rm -rf "$staging"
  done <<<"$targets"
fi

exit 0
