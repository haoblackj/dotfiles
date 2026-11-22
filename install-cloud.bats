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
    # PATH 上の chezmoi を隠す（スクリプトは chezmoi が PATH にあると何もしない）。
    # 同じディレクトリの jq や python3 を残すため、ディレクトリごと外さずに
    # chezmoi 以外を symlink した一時ディレクトリへ置き換える。
    local dir path="" i=0 shadow f
    local IFS=:
    for dir in $PATH; do
        if [ -x "$dir/chezmoi" ]; then
            i=$((i + 1))
            shadow="$BATS_TEST_TMPDIR/path$i"
            mkdir -p "$shadow"
            for f in "$dir"/*; do
                [ "${f##*/}" = chezmoi ] || ln -s "$f" "$shadow/"
            done
            dir="$shadow"
        fi
        path="${path:+$path:}$dir"
    done
    export PATH="$path"
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

# CLOUD_HOOK_COMMANDS はいま空なので、仕組みを試すテストは値を差し込んだ写しで走らせる。
# ソースの settings.json にも、その command の Stop hook を足す。
with_cloud_hook() {
    sed 's|^CLOUD_HOOK_COMMANDS=.*|CLOUD_HOOK_COMMANDS=("~/.claude/hooks/demo-guard.py")|' \
        "$SCRIPT" >"$BATS_TEST_TMPDIR/install-cloud.sh"
    SCRIPT="$BATS_TEST_TMPDIR/install-cloud.sh"
    jq '.hooks.Stop += [{"hooks":[{"type":"command","command":"~/.claude/hooks/demo-guard.py"}]}]' \
        "$SRC/linked/claude/settings.json" >"$BATS_TEST_TMPDIR/settings.json"
    mv "$BATS_TEST_TMPDIR/settings.json" "$SRC/linked/claude/settings.json"
}

@test "settings.json には決めたキーだけを入れる" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run jq -c 'keys' "$HOME/.claude/settings.json"
    [ "$output" = '["language","outputStyle","spinnerVerbs"]' ]
    run jq -r '.outputStyle' "$HOME/.claude/settings.json"
    [ "$output" = "$(jq -r '.outputStyle' "$SRC/linked/claude/settings.json")" ]
    run jq -c '.spinnerVerbs' "$HOME/.claude/settings.json"
    [ "$output" = "$(jq -c '.spinnerVerbs' "$SRC/linked/claude/settings.json")" ]
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

@test "hooks.Stop には CLOUD_HOOK_COMMANDS のものだけを入れる" {
    with_cloud_hook
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run jq -c '[.hooks.Stop[].hooks[].command]' "$HOME/.claude/settings.json"
    [ "$output" = '["~/.claude/hooks/demo-guard.py"]' ]
    run jq -c '.hooks | keys' "$HOME/.claude/settings.json"
    [ "$output" = '["Stop"]' ]
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

[".claude/skills/arc"]
type = "archive"
url = "https://invalid.example/arc.tar.gz"

[".local/share/secret"]
type = "git-repo"
url = "https://invalid.example/secret.git"
EOF
    # clone は失敗させ、試みた URL をログから読む
    run bash -c 'GIT_TERMINAL_PROMPT=0 bash "$1" 2>&1' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://invalid.example/pub.git"* ]]
    [[ "$output" != *"secret.git"* ]]
    [[ "$output" == *"git-repo 以外の external は飛ばす: .claude/skills/arc"* ]]
}

@test "chezmoi 管理の環境では何もしない" {
    mkdir -p "$HOME/.local/share/chezmoi/.git" "$HOME/.claude"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/.claude/CLAUDE.md" ]
}

@test "settings.json が symlink の環境では何もしない" {
    mkdir -p "$HOME/.claude"
    echo '{}' >"$BATS_TEST_TMPDIR/real.json"
    ln -s "$BATS_TEST_TMPDIR/real.json" "$HOME/.claude/settings.json"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/.claude/CLAUDE.md" ]
}

@test "skills/ のスキルを ~/.claude/skills へ写す" {
    mkdir -p "$SRC/skills/demo/references"
    echo '---' >"$SRC/skills/demo/SKILL.md"
    echo ref >"$SRC/skills/demo/references/a.md"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    diff -r "$SRC/skills/demo" "$HOME/.claude/skills/demo"
}

@test "CLOUD_MODS に挙げた Mod は SKILL.md が無くても写す" {
    mkdir -p "$SRC/skills/japanese-guard/.claude-plugin" "$SRC/skills/japanese-guard/hooks"
    echo '{"name":"japanese-guard"}' >"$SRC/skills/japanese-guard/.claude-plugin/plugin.json"
    echo '{"modules":["./register.ts"]}' >"$SRC/skills/japanese-guard/hooks/hooks.json"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    diff -r "$SRC/skills/japanese-guard" "$HOME/.claude/skills/japanese-guard"
}

# cloud-skills.txt のテストに使う、サブディレクトリにスキルを持つ git リポジトリ。
# 一時ディレクトリに作り、file:// で clone させる（ネットワークを使わない）。
make_subdir_skill_repo() {
    UP="$BATS_TEST_TMPDIR/upstream"
    mkdir -p "$UP/skills/demo/references"
    echo '---' >"$UP/skills/demo/SKILL.md"
    echo ref >"$UP/skills/demo/references/a.md"
    echo top >"$UP/README.md"
    git -C "$UP" init -q
    git -C "$UP" add -A
    git -C "$UP" -c user.name=t -c user.email=t@example.invalid commit -q -m init
}

@test "cloud-skills.txt のスキルをサブディレクトリだけ ~/.claude/skills へ写す" {
    make_subdir_skill_repo
    echo "# コメント" >"$SRC/cloud-skills.txt"
    echo "demo file://$UP skills/demo" >>"$SRC/cloud-skills.txt"
    run bash -c 'bash "$1" 2>&1' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    diff -r "$UP/skills/demo" "$HOME/.claude/skills/demo"
    [ ! -e "$HOME/.claude/skills/demo/README.md" ]
    [ ! -e "$HOME/.claude/skills/demo/.git" ]
}

@test "本物の cloud-skills.txt の行はすべて「名前 URL パス」の形" {
    run awk '!/^[[:space:]]*(#|$)/ && NF != 3' "$BATS_TEST_DIRNAME/cloud-skills.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -q '^yomiyasu https://github.com/nanaism/yomiyasu.git skills/yomiyasu$' \
        "$BATS_TEST_DIRNAME/cloud-skills.txt"
}
