#!/usr/bin/env bats
# check-coverage-sources.sh が、pyproject.toml の [tool.coverage.run] の
# source/omit から漏れた追跡 .py を見つけることを確かめる。
# 詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。

# 対象の名前は置き場所で変わる。chezmoi のソース側では
# executable_check-coverage-sources.sh、配置先（~/.local/bin/）では
# check-coverage-sources.sh。pre-push の門はコミットされたものを検査するため
# ソースツリーで走らせるので、両方を試す。どちらも無ければ落とす（黙って
# 素通りさせない）。ソース側には実行ビットが無いので bash 経由で呼ぶ。
resolve_target() {
    local cand
    for cand in "$BATS_TEST_DIRNAME/$1" "$BATS_TEST_DIRNAME/executable_$1"; do
        if [ -f "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    echo "対象が見つからない: $BATS_TEST_DIRNAME/$1 も executable_$1 も無い" >&2
    return 1
}

setup() {
    CHECK="$(resolve_target check-coverage-sources.sh)"
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
    run bash "$CHECK" "$REPO_DIR"
    [ "$status" -eq 0 ]
}

@test "source にも omit にも属さない追跡 .py があれば、そのパスを出して非0で終わる" {
    mkdir -p "$REPO_DIR/leak"
    echo "z = 3" > "$REPO_DIR/leak/b.py"
    git -C "$REPO_DIR" add -A

    run bash "$CHECK" "$REPO_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"leak/b.py"* ]]
}

@test "omit に挙がっているファイルは報告に出ない" {
    mkdir -p "$REPO_DIR/leak"
    echo "z = 3" > "$REPO_DIR/leak/b.py"
    git -C "$REPO_DIR" add -A

    run bash "$CHECK" "$REPO_DIR"
    [ "$status" -ne 0 ]
    # 漏れ（leak/b.py）は出ているのに omit 対象（omitted.py）だけが出ない、
    # という区別ができていることを見る。これが無いと「何も出力しない
    # 壊れた実装」でもこのテストは green になってしまう。
    [[ "$output" == *"leak/b.py"* ]]
    [[ "$output" != *"omitted.py"* ]]
}

@test "新しいディレクトリへ .py を1本置くと非0になる" {
    run bash "$CHECK" "$REPO_DIR"
    [ "$status" -eq 0 ]

    mkdir -p "$REPO_DIR/newdir"
    echo "w = 4" > "$REPO_DIR/newdir/fresh.py"
    git -C "$REPO_DIR" add -A

    run bash "$CHECK" "$REPO_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"newdir/fresh.py"* ]]

    # 一時ファイルを消して元の状態（全部が属する）へ戻す。
    git -C "$REPO_DIR" rm -q --cached newdir/fresh.py
    rm -f -- "$REPO_DIR/newdir/fresh.py"

    run bash "$CHECK" "$REPO_DIR"
    [ "$status" -eq 0 ]
}

@test "引数でリポジトリを受け取り、chezmoi でも動く" {
    run bash "$CHECK" "$HOME/.local/share/chezmoi"
    [ "$status" -eq 0 ]
}
