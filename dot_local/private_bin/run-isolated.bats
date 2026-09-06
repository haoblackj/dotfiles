#!/usr/bin/env bats
# run-isolated.sh の骨格を確かめるテスト。
# 詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。

setup() {
    RUN_ISOLATED="$BATS_TEST_DIRNAME/run-isolated.sh"
    REPO_DIR="$(mktemp -d -t run-isolated-test-repo.XXXXXX)"
}

teardown() {
    rm -rf -- "$REPO_DIR"
}

@test "true の終了コード0が外へ伝わる" {
    run "$RUN_ISOLATED" "$REPO_DIR" -- true
    [ "$status" -eq 0 ]
}

@test "false の終了コード1が外へ伝わる" {
    run "$RUN_ISOLATED" "$REPO_DIR" -- false
    # false 自身の終了コード（1）とちょうど一致することを見る。
    # 「非0」だけで判定すると、スクリプトが未実装で「コマンドが見つからない」
    # （127）になった場合も通ってしまい、Step 2 の「6件とも落ちる」を裏切る。
    [ "$status" -eq 1 ]
}

@test "隔離の中の HOME に本番の HOME のファイルが見えない" {
    marker="$HOME/.run-isolated-visibility-marker-$$"
    : > "$marker"
    run "$RUN_ISOLATED" "$REPO_DIR" -- test -e "$marker"
    rm -f -- "$marker"
    # test -e が「無い」と判定したときの終了コード（1）とちょうど一致することを見る。
    [ "$status" -eq 1 ]
}

@test "隔離の中で HOME へ書いたものが本番の HOME に残らない" {
    marker_name=".run-isolated-write-marker-$$"
    run "$RUN_ISOLATED" "$REPO_DIR" -- sh -c "touch \"\$HOME/$marker_name\""
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/$marker_name" ]
}

@test "隔離の中からリポジトリへ書こうとすると失敗する" {
    run "$RUN_ISOLATED" "$REPO_DIR" -- sh -c "touch \"$REPO_DIR/should-not-exist\""
    # touch が読み取り専用ファイルシステムで失敗したときの終了コード（1）と
    # ちょうど一致することを見る。
    [ "$status" -eq 1 ]
    [ ! -e "$REPO_DIR/should-not-exist" ]
}

@test "-- が無い呼び出しを拒否する" {
    run "$RUN_ISOLATED" "$REPO_DIR" true
    # 使い方エラーとして予約した終了コード（2）とちょうど一致することを見る。
    [ "$status" -eq 2 ]
}

@test "--out で指定したホスト側ディレクトリに、隔離内で書いたファイルが残る" {
    out_dir="$(mktemp -d -t run-isolated-test-out.XXXXXX)"
    run "$RUN_ISOLATED" "$REPO_DIR" --out "$out_dir" -- sh -c 'echo hello > "$COVERAGE_OUT_DIR/result.txt"'
    [ "$status" -eq 0 ]
    [ -e "$out_dir/result.txt" ]
    [ "$(cat "$out_dir/result.txt")" = "hello" ]
    rm -rf -- "$out_dir"
}

@test "--out を付けない走行では、中で書いたものが残らない" {
    run "$RUN_ISOLATED" "$REPO_DIR" -- sh -c 'touch "$COVERAGE_OUT_DIR/marker" && echo "$COVERAGE_OUT_DIR"'
    [ "$status" -eq 0 ]
    # サンドボックス内の COVERAGE_OUT_DIR のパスをそのまま出力させ、
    # 走行後（サンドボックス破棄後）にそのパスがホスト側に存在しないことを見る。
    [ ! -e "$output" ]
}

@test "--out の指す先ディレクトリが無ければ作る" {
    base_dir="$(mktemp -d -t run-isolated-test-out.XXXXXX)"
    out_dir="$base_dir/nested/dir"
    [ ! -e "$out_dir" ]
    run "$RUN_ISOLATED" "$REPO_DIR" --out "$out_dir" -- sh -c 'echo hi > "$COVERAGE_OUT_DIR/f"'
    [ "$status" -eq 0 ]
    [ -d "$out_dir" ]
    [ -e "$out_dir/f" ]
    rm -rf -- "$base_dir"
}

@test "中のコマンドが失敗しても、それまでに書かれた出力は取り出せる" {
    out_dir="$(mktemp -d -t run-isolated-test-out.XXXXXX)"
    run "$RUN_ISOLATED" "$REPO_DIR" --out "$out_dir" -- sh -c 'echo partial > "$COVERAGE_OUT_DIR/partial.txt"; exit 1'
    [ "$status" -eq 1 ]
    [ -e "$out_dir/partial.txt" ]
    rm -rf -- "$out_dir"
}
