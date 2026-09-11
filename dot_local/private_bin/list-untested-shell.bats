#!/usr/bin/env bats
# list-untested-shell.sh が、追跡 .sh のうちテストを持たないものを
# 正しく列挙することを確かめる。詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。
#
# 判別は使い捨てのリポジトリ（mktemp -d）で行う。**2つの実リポジトリの現況を
# 実数やファイル名で断言しない。**以前はここに「全部で15本、penguinEx は
# diet/scripts/init_env.sh の1本」と書いていたが、層5 Task 2 でこの .bats が
# pre-push の門へ恒久的に載ったため、penguinEx に .sh が1本増えるか
# init_env.sh に .bats が付くだけで chezmoi への push が全面的に止まる
# （テストを足すという正しい行為が門を赤にする）形になっていた。
# 実リポジトリを見るのは最後の1件だけで、断言は終了コードと
# 「1本以上出る」「出た行が実在する」までに留める。

# 対象の名前は置き場所で変わる。chezmoi のソース側では
# executable_list-untested-shell.sh、配置先（~/.local/bin/）では
# list-untested-shell.sh。pre-push の門はコミットされたものを検査するため
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
    LIST="$(resolve_target list-untested-shell.sh)"
    REPO_DIR="$(mktemp -d -t list-untested-shell-test-repo.XXXXXX)"
    git -C "$REPO_DIR" init -q
}

teardown() {
    rm -rf -- "$REPO_DIR"
}

# 使い捨てリポジトリへ追跡ファイルを1本置く。中身は判定に使われないので
# 名前だけが意味を持つ。
track() {
    local rel="$1"
    mkdir -p "$REPO_DIR/$(dirname -- "$rel")"
    printf '#!/usr/bin/env bash\n:\n' > "$REPO_DIR/$rel"
    git -C "$REPO_DIR" add -- "$rel"
}

@test "テストを持たない .sh は一覧に出る" {
    track hooks/lonely.sh
    run bash "$LIST" "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO_DIR/hooks/lonely.sh"* ]]
}

@test "同じ名前の .bats を持つ .sh は一覧に出ない" {
    track hooks/tested.sh
    track hooks/tested.bats
    track hooks/lonely.sh
    run bash "$LIST" "$REPO_DIR"
    [ "$status" -eq 0 ]
    # 除外できていることと、除外し過ぎていないことを同時に見る。
    # 片方だけだと「何も出さない壊れた実装」でも通ってしまう。
    [[ "$output" != *"hooks/tested.sh"* ]]
    [[ "$output" == *"hooks/lonely.sh"* ]]
}

@test "executable_ 接頭辞の .sh も、接頭辞の無い .bats に対応づく" {
    # chezmoi のソースツリーの形。配置先では接頭辞が外れる。
    track hooks/executable_tested.sh
    track hooks/tested.bats
    track hooks/executable_lonely.sh
    run bash "$LIST" "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"executable_tested.sh"* ]]
    [[ "$output" == *"executable_lonely.sh"* ]]
}

@test "対応する実装の無い .bats は何も除外しない" {
    # e2e-integration.bats のように、命名規約の指す .sh も .py も無い .bats。
    track hooks/orphan.bats
    track hooks/lonely.sh
    run bash "$LIST" "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hooks/lonely.sh"* ]]
}

@test "別のディレクトリにある同名の .bats では除外されない" {
    # 対応づけはディレクトリを跨がない。跨ぐと、よそのテストを根拠に
    # 「テストがある」と数えてしまう。
    track hooks/lonely.sh
    track other/lonely.bats
    run bash "$LIST" "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hooks/lonely.sh"* ]]
}

@test "テストファイル自身は一覧に出ない" {
    track hooks/foo.test.sh
    track hooks/test_bar.sh
    track hooks/lonely.sh
    run bash "$LIST" "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"foo.test.sh"* ]]
    [[ "$output" != *"test_bar.sh"* ]]
    [[ "$output" == *"hooks/lonely.sh"* ]]
}

@test "追跡されていない .sh は一覧に出ない" {
    track hooks/lonely.sh
    printf '#!/usr/bin/env bash\n:\n' > "$REPO_DIR/hooks/untracked.sh"
    run bash "$LIST" "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"untracked.sh"* ]]
    [[ "$output" == *"hooks/lonely.sh"* ]]
}

@test "複数のリポジトリを1つの一覧にまとめ、同じリポジトリは1回しか数えない" {
    track hooks/lonely.sh
    local second
    second="$(mktemp -d -t list-untested-shell-test-repo2.XXXXXX)"
    git -C "$second" init -q
    mkdir -p "$second/bin"
    printf '#!/usr/bin/env bash\n:\n' > "$second/bin/other.sh"
    git -C "$second" add -- bin/other.sh

    run bash "$LIST" "$REPO_DIR" "$second" "$REPO_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO_DIR/hooks/lonely.sh"* ]]
    [[ "$output" == *"$second/bin/other.sh"* ]]
    # 同じリポジトリを2回渡しても重複しない。
    local hits
    hits="$(printf '%s\n' "$output" | grep -c -F -- "$REPO_DIR/hooks/lonely.sh")"
    [ "$hits" -eq 1 ]

    rm -rf -- "$second"
}

@test "引数が無ければ使い方を出して 2 で落ちる" {
    run bash "$LIST"
    [ "$status" -eq 2 ]
    [[ "$output" == *"使い方"* ]]
}

@test "存在しないディレクトリを渡すと 2 で落ちる（黙って空の一覧にしない）" {
    run bash "$LIST" "$REPO_DIR/no-such-dir"
    [ "$status" -eq 2 ]
    [[ "$output" == *"リポジトリが見つかりません"* ]]
}

@test "実リポジトリでも 0 で終わり、出た行が実在するパスになっている" {
    # **実数も特定のファイル名も断言しない。**ここで現況を固定すると、
    # .sh を1本足す／.bats を1本足すという正しい行為で門が赤くなる。
    # PENGUINEX_REPO_OVERRIDE は切り替えの手動確認・デバッグ用。
    local penguinex="${PENGUINEX_REPO_OVERRIDE:-$HOME/repo/github.com/haoblackj/penguinEx}"
    local chezmoi="$HOME/.local/share/chezmoi"
    run bash "$LIST" "$penguinex" "$chezmoi"
    [ "$status" -eq 0 ]
    local count
    count="$(printf '%s\n' "$output" | grep -c .)"
    [ "$count" -ge 1 ]
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [ -f "$line" ]
    done <<< "$output"
}
