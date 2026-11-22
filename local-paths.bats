#!/usr/bin/env bats
# マシンごとのパス（Obsidian の保管庫、Codex の信頼するプロジェクト）を、
# リポジトリに入らないローカルの chezmoi の設定の data から読むことの試験。
#
# 一時の設定ファイルを --config で渡し、この作業ツリーをソースにして
# テンプレートを描く。本番の ~/.config/chezmoi/chezmoi.toml は読まない。
set -u

setup() {
    command -v chezmoi >/dev/null || skip "chezmoi が無い"
    SRC="$BATS_TEST_DIRNAME"
    CFG="$BATS_TEST_TMPDIR/chezmoi.toml"
    # 本番の設定の状態ファイルを使わないよう、persistent-state も一時に置く
    STATE="$BATS_TEST_TMPDIR/state.boltdb"
}

render() {
    chezmoi --config "$CFG" --persistent-state "$STATE" --source "$SRC" execute-template < "$SRC/$1"
}

with_data() {
    cat > "$CFG" <<'EOF'
[data]
    location = "wsl"
    isWSL = true
    isDevcontainer = false
    windowsUsername = "someone"
    isHome = false
    obsidianWorkspaces = { "notes-a" = "~/vaults/a", "notes-b" = "~/vaults/b" }
    codexTrustedProjects = ["/home/someone/repo/one", "/home/someone/repo/two"]
EOF
}

without_data() {
    cat > "$CFG" <<'EOF'
[data]
    location = "wsl"
    isWSL = true
    isDevcontainer = false
    windowsUsername = "someone"
    isHome = false
EOF
}

@test "Obsidian の保管庫をローカルの data から並べる" {
    with_data
    run render dot_config/nvim/lua/plugins/obsidian.lua.tmpl
    [ "$status" -eq 0 ]
    [[ "$output" == *"{ name = \"notes-a\", path = \"~/vaults/a\" },"* ]]
    [[ "$output" == *"{ name = \"notes-b\", path = \"~/vaults/b\" },"* ]]
    [[ "$output" == *"'obsidian-nvim/obsidian.nvim'"* ]]
}

@test "chezmoi init で設定を作り直しても、ローカルの data を引き継ぐ" {
    with_data
    run chezmoi --config "$CFG" --persistent-state "$STATE" --source "$SRC" execute-template --init < "$SRC/.chezmoi.toml.tmpl"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/new.toml"
    # 作り直した設定を、もう一度設定として読めて、同じ値が出る
    CFG="$BATS_TEST_TMPDIR/new.toml"
    run chezmoi --config "$CFG" --persistent-state "$STATE" --source "$SRC" execute-template \
        '{{ range $k, $v := .obsidianWorkspaces }}{{ $k }}={{ $v }};{{ end }}|{{ join "," .codexTrustedProjects }}'
    [ "$status" -eq 0 ]
    [ "$output" = "notes-a=~/vaults/a;notes-b=~/vaults/b;|/home/someone/repo/one,/home/someone/repo/two" ]
}

@test "data の型を間違えたら、黙って描かずに止まる" {
    without_data
    printf '    obsidianWorkspaces = ["~/vaults/a"]\n' >> "$CFG"
    run render dot_config/nvim/lua/plugins/obsidian.lua.tmpl
    [ "$status" -ne 0 ]
    [[ "$output" == *"obsidianWorkspaces"* ]]
    without_data
    printf '    codexTrustedProjects = "/home/someone/repo/one"\n' >> "$CFG"
    run render dot_codex/private_exusiai.config.toml.tmpl
    [ "$status" -ne 0 ]
    [[ "$output" == *"codexTrustedProjects"* ]]
}

