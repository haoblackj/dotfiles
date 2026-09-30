#!/usr/bin/env bats
# install-cloud.sh のテスト。
#
# 一時ディレクトリを HOME にし、clone の代わりにこの作業ツリーを DOTFILES_SRC
# として渡す。external の clone（ネットワーク）は、中身を差し替えたソースで
# 止めて検証する。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/install-cloud.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    # external を持たないソース（clone を走らせないため）
    SRC="$BATS_TEST_TMPDIR/src"
    mkdir -p "$SRC/linked/claude"
    cp -R "$BATS_TEST_DIRNAME/dot_claude" "$SRC/dot_claude"
    cp "$BATS_TEST_DIRNAME/linked/claude/settings.json" "$SRC/linked/claude/settings.json"
    export DOTFILES_SRC="$SRC"
}

@test "CLAUDE.md / agents / rules / output-styles を ~/.claude へ写す" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    cmp "$SRC/dot_claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
    diff -r "$SRC/dot_claude/agents" "$HOME/.claude/agents"
    diff -r "$SRC/dot_claude/rules" "$HOME/.claude/rules"
    diff -r "$SRC/dot_claude/output-styles" "$HOME/.claude/output-styles"
}

@test "hooks と keybindings は写さない" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.claude/hooks" ]
    [ ! -e "$HOME/.claude/keybindings.json" ]
}

@test "settings.json には決めたキーだけを入れる" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run jq -c 'keys' "$HOME/.claude/settings.json"
    [ "$output" = '["effortLevel","language","outputStyle"]' ]
    run jq -r '.outputStyle' "$HOME/.claude/settings.json"
    [ "$output" = "$(jq -r '.outputStyle' "$SRC/linked/claude/settings.json")" ]
}

@test "既存の settings.json のキーを残してマージする" {
    mkdir -p "$HOME/.claude"
    echo '{"foo":1,"language":"english"}' >"$HOME/.claude/settings.json"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run jq -r '.foo' "$HOME/.claude/settings.json"
    [ "$output" = "1" ]
    run jq -r '.language' "$HOME/.claude/settings.json"
    [ "$output" = "japanese" ]
}

@test "二度走らせても同じ結果になる（消した agent が残らない）" {
    bash "$SCRIPT" 2>/dev/null
    echo stale >"$HOME/.claude/agents/stale.md"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.claude/agents/stale.md" ]
}

@test "~/.claude 配下の external だけを対象にする" {
    cat >"$SRC/.chezmoiexternal.toml" <<'EOF'
[".claude/skills/pub"]
type = "git-repo"
url = "https://invalid.example/pub.git"

[".local/share/secret"]
type = "git-repo"
url = "https://invalid.example/secret.git"
EOF
    # clone は失敗させ、試みた URL をログから読む
    run bash -c 'GIT_TERMINAL_PROMPT=0 bash "$1" 2>&1' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://invalid.example/pub.git"* ]]
    [[ "$output" != *"secret.git"* ]]
}

@test "chezmoi 管理の環境では何もしない" {
    mkdir -p "$HOME/.local/share/chezmoi/.git" "$HOME/.claude"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/.claude/CLAUDE.md" ]
}
