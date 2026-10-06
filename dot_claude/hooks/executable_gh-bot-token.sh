#!/usr/bin/env bash
# Claude Code のセッションの gh と git push を GitHub App（penguinex-agent）の名義にする。
# gh も git の credential helper（!gh auth git-credential）も GH_TOKEN を最優先で使うので、
# Claude の Bash の環境に installation token を入れるだけで済み、gh や git は包まない。
#
#   session  SessionStart フックから呼ぶ。CLAUDE_ENV_FILE に「GH_TOKEN を決める1行」を追記する。
#            CLAUDE_ENV_FILE は Bash の実行のたびに読み直されるので（文書に記述が無く、#38 の実測による）、
#            1時間で切れる token も、長いセッションの途中で作り直される。
#   token    有効な token を標準出力へ出す。キャッシュが50分を過ぎていれば gh-token で作り直す。
#
# 鍵か age の identity が無い環境（クラウドセッションなど）と、token を作れないときは
# GH_TOKEN を入れず、本人（haoblackj）の名義のまま動く。
# Claude Code の中でリーダーが ! で打つ gh と git にも GH_TOKEN が入る（グローバル CLAUDE.md に注意書き）。
# 設計と決定: haoblackj/dotfiles#38、アプリと鍵の保管: haoblackj/penguinEx#67
set -u

APP_ID="${CLAUDE_GH_BOT_APP_ID:-4917610}"
INSTALLATION_ID="${CLAUDE_GH_BOT_INSTALLATION_ID:-161055606}"
KEY_AGE="${CLAUDE_GH_BOT_KEY:-$HOME/.local/share/claude-private/secrets/penguinex-agent/private-key.pem.age}"
AGE_IDENTITY="${CLAUDE_GH_BOT_AGE_IDENTITY:-$HOME/.config/chezmoi/key.txt}"
# installation token の寿命は1時間。余裕を見て50分で作り直す。
TOKEN_TTL=3000
# 共有の /tmp には落とさない（先回りのシンボリックリンクで書き込み先を横取りされうるため）
CACHE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/claude-gh-bot"

mint_token() {
    if [ -n "${CLAUDE_GH_BOT_MINT_CMD:-}" ]; then
        "$CLAUDE_GH_BOT_MINT_CMD"
        return
    fi
    command -v age >/dev/null 2>&1 || return 1
    # 秘密鍵の平文はディスクに書かず、プロセス置換で gh-token へ渡す
    gh token generate --app-id "$APP_ID" --installation-id "$INSTALLATION_ID" \
        --token-only --key <(age -d -i "$AGE_IDENTITY" "$KEY_AGE")
}

# 置き場が自分の持ち物の実ディレクトリであることを確かめてから使う
prepare_cache_dir() {
    (umask 077 && mkdir -p "$CACHE_DIR") 2>/dev/null || return 1
    [ -d "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ] && [ -O "$CACHE_DIR" ] || return 1
    chmod 700 "$CACHE_DIR"
}

cmd_token() {
    local token_file="$CACHE_DIR/token" tmp token
    prepare_cache_dir || return 1
    if [ -f "$token_file" ] && [ ! -L "$token_file" ] && [ -O "$token_file" ] &&
        [ $(($(date +%s) - $(stat -c %Y "$token_file"))) -lt "$TOKEN_TTL" ]; then
        token=$(cat "$token_file")
        if [ -n "$token" ]; then
            printf '%s\n' "$token"
            return 0
        fi
    fi
    token=$(mint_token 2>/dev/null) && [ -n "$token" ] || return 1
    tmp=$(umask 077 && mktemp "$CACHE_DIR/token.XXXXXX") || return 1
    printf '%s\n' "$token" > "$tmp" && mv -f "$tmp" "$token_file" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$token"
}

cmd_session() {
    [ -n "${CLAUDE_ENV_FILE:-}" ] || return 0
    [ -r "$KEY_AGE" ] && [ -r "$AGE_IDENTITY" ] || return 0
    local self
    self=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")
    # 読まれるたびに評価させるため、$(...) は書くときに展開しない
    printf '_gh_bot_t="$(%q token 2>/dev/null)" && [ -n "$_gh_bot_t" ] && export GH_TOKEN="$_gh_bot_t"; unset _gh_bot_t\n' \
        "$self" >> "$CLAUDE_ENV_FILE"
}

case "${1:-}" in
    session) cmd_session ;;
    token) cmd_token ;;
    *)
        echo "usage: $0 session|token" >&2
        exit 2
        ;;
esac
