#!/usr/bin/env bats
# mutation-target: dot_local/private_bin/executable_check-coverage-sources.sh
# check-coverage-sources.sh が、pyproject.toml の [tool.coverage.run] の
# source/omit から漏れた追跡 .py を見つけることを確かめる。
# 詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。

setup() {
    CHECK="$BATS_TEST_DIRNAME/check-coverage-sources.sh"
    REPO_DIR="$(mktemp -d -t check-coverage-sources-test-repo.XXXXXX)"
    git -C "$REPO_DIR" init -q

    mkdir -p "$REPO_DIR/src"
    echo "x = 1" > "$REPO_DIR/src/covered.py"
    echo "y = 2" > "$REPO_DIR/src/omitted.py"

    cat > "$REPO_DIR/pyproject.toml" <<'EOF'
[tool.coverage.run]
branch = true
source = [
    "src",
]
omit = [
    "src/omitted.py",
]
EOF
    git -C "$REPO_DIR" add -A
}

teardown() {
    rm -rf -- "$REPO_DIR"
}

@test "全部が source か omit に属していれば0で終わる" {
    run "$CHECK" "$REPO_DIR"
    [ "$status" -eq 0 ]
}

@test "source にも omit にも属さない追跡 .py があれば、そのパスを出して非0で終わる" {
    mkdir -p "$REPO_DIR/leak"
    echo "z = 3" > "$REPO_DIR/leak/b.py"
    git -C "$REPO_DIR" add -A

    run "$CHECK" "$REPO_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"leak/b.py"* ]]
}

@test "omit に挙がっているファイルは報告に出ない" {
    mkdir -p "$REPO_DIR/leak"
    echo "z = 3" > "$REPO_DIR/leak/b.py"
    git -C "$REPO_DIR" add -A

    run "$CHECK" "$REPO_DIR"
    [ "$status" -ne 0 ]
    # 漏れ（leak/b.py）は出ているのに omit 対象（omitted.py）だけが出ない、
    # という区別ができていることを見る。これが無いと「何も出力しない
    # 壊れた実装」でもこのテストは green になってしまう。
    [[ "$output" == *"leak/b.py"* ]]
    [[ "$output" != *"omitted.py"* ]]
}

@test "新しいディレクトリへ .py を1本置くと非0になる" {
    run "$CHECK" "$REPO_DIR"
    [ "$status" -eq 0 ]

    mkdir -p "$REPO_DIR/newdir"
    echo "w = 4" > "$REPO_DIR/newdir/fresh.py"
    git -C "$REPO_DIR" add -A

    run "$CHECK" "$REPO_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"newdir/fresh.py"* ]]

    # 一時ファイルを消して元の状態（全部が属する）へ戻す。
    git -C "$REPO_DIR" rm -q --cached newdir/fresh.py
    rm -f -- "$REPO_DIR/newdir/fresh.py"

    run "$CHECK" "$REPO_DIR"
    [ "$status" -eq 0 ]
}

@test "引数でリポジトリを受け取り、chezmoi でも動く" {
    run "$CHECK" "$HOME/.local/share/chezmoi"
    [ "$status" -eq 0 ]
}
