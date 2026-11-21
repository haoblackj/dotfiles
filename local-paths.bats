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

@test "保管庫の data が無いマシンでは obsidian.nvim を読み込まない（空の spec）" {
    without_data
    run render dot_config/nvim/lua/plugins/obsidian.lua.tmpl
    [ "$status" -eq 0 ]
    [[ "$output" != *"obsidian.nvim"* ]]
    [[ "$(echo "$output" | tr -d '[:space:]')" == "return{}" ]]
}

@test "Codex の信頼するプロジェクトをローカルの data から並べる" {
    with_data
    run render dot_codex/private_exusiai.config.toml.tmpl
    [ "$status" -eq 0 ]
    [[ "$output" == *'[projects."/home/someone/repo/one"]'* ]]
    [[ "$output" == *'[projects."/home/someone/repo/two"]'* ]]
    [ "$(grep -c '^trust_level = "trusted"$' <<<"$output")" -eq 2 ]
}

@test "Codex の信頼するプロジェクトの data が無いマシンでは projects を書かない" {
    without_data
    run render dot_codex/private_exusiai.config.toml.tmpl
    [ "$status" -eq 0 ]
    [[ "$output" != *"[projects."* ]]
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

@test "data が無い設定を作り直しても、空の値で読める" {
    without_data
    run chezmoi --config "$CFG" --persistent-state "$STATE" --source "$SRC" execute-template --init < "$SRC/.chezmoi.toml.tmpl"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/new.toml"
    CFG="$BATS_TEST_TMPDIR/new.toml"
    run render dot_codex/private_exusiai.config.toml.tmpl
    [ "$status" -eq 0 ]
    [[ "$output" != *"[projects."* ]]
    run render dot_config/nvim/lua/plugins/obsidian.lua.tmpl
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | tr -d '[:space:]')" == "return{}" ]]
}

# 引用符、バックスラッシュ、日本語、制御文字を含む値
special_data() {
    python3 - "$CFG" <<'EOF'
import sys
open(sys.argv[1], "w").write('''[data]
    location = "wsl"
    isWSL = true
    isDevcontainer = false
    windowsUsername = "someone"
    isHome = false
    obsidianWorkspaces = { "メモ \\"a\\"" = "~/保管庫/a\\\\b", "c" = "~/v\\u0007c" }
    codexTrustedProjects = ["/home/someone/プロジェクト \\"x\\"", "/home/someone/y\\\\z\\u0001"]
''')
EOF
}

@test "特殊な文字を含む値でも、作り直した設定と Codex の設定が TOML として読め、値が変わらない" {
    special_data
    run chezmoi --config "$CFG" --persistent-state "$STATE" --source "$SRC" execute-template --init < "$SRC/.chezmoi.toml.tmpl"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/new.toml"
    run python3 - "$CFG" "$BATS_TEST_TMPDIR/new.toml" <<'EOF'
import sys, tomllib
a = tomllib.load(open(sys.argv[1], "rb"))["data"]
b = tomllib.load(open(sys.argv[2], "rb"))["data"]
for k in ("obsidianWorkspaces", "codexTrustedProjects"):
    assert a[k] == b[k], (k, a[k], b[k])
EOF
    [ "$status" -eq 0 ]
    run render dot_codex/private_exusiai.config.toml.tmpl
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/codex.toml"
    run python3 - "$CFG" "$BATS_TEST_TMPDIR/codex.toml" <<'EOF'
import sys, tomllib
want = tomllib.load(open(sys.argv[1], "rb"))["data"]["codexTrustedProjects"]
got = tomllib.load(open(sys.argv[2], "rb"))["projects"]
assert sorted(got) == sorted(want), (got, want)
assert all(v == {"trust_level": "trusted"} for v in got.values())
EOF
    [ "$status" -eq 0 ]
}

@test "特殊な文字を含む保管庫の名前とパスでも、Lua として読め、値が変わらない" {
    command -v nvim >/dev/null || skip "nvim が無い"
    cat > "$CFG" <<'EOF'
[data]
    location = "wsl"
    isWSL = true
    isDevcontainer = false
    windowsUsername = "someone"
    isHome = false
    obsidianWorkspaces = { "メモ \"a\"" = "~/保管庫/a\\b" }
EOF
    run render dot_config/nvim/lua/plugins/obsidian.lua.tmpl
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/obs.lua"
    run nvim --clean --headless -c "lua local s=dofile('$BATS_TEST_TMPDIR/obs.lua'); local w=s.opts.workspaces[1]; io.stdout:write(w.name .. '|' .. w.path)" -c q
    [ "$status" -eq 0 ]
    [ "$output" = 'メモ "a"|~/保管庫/a\b' ]
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

# opencode の導入スクリプトは、PATH に入っていないとき、~/.zshrc に同じ行（展開したパス）が
# 無ければ `# opencode` と `export PATH=<ホーム>/.opencode/bin:$PATH` を書き足す。
# ソースに同じ行を置き、opencode のあるマシンでだけ描く。
@test "opencode があるマシンでは、導入スクリプトと同じ PATH の行を .zshrc に描く" {
    without_data
    local home="$BATS_TEST_TMPDIR/home"
    mkdir -p "$home/.opencode/bin"
    run env HOME="$home" chezmoi --config "$CFG" --persistent-state "$STATE" --source "$SRC" execute-template < "$SRC/dot_zshrc.tmpl"
    [ "$status" -eq 0 ]
    grep -Fxq "export PATH=$home/.opencode/bin:\$PATH" <<<"$output"
}

@test "opencode の無いマシンでは、.zshrc に opencode の行を描かない" {
    without_data
    local home="$BATS_TEST_TMPDIR/home"
    mkdir -p "$home"
    run env HOME="$home" chezmoi --config "$CFG" --persistent-state "$STATE" --source "$SRC" execute-template < "$SRC/dot_zshrc.tmpl"
    [ "$status" -eq 0 ]
    [[ "$output" != *".opencode"* ]]
}
