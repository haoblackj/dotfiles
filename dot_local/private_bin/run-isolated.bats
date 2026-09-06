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

@test "中のコマンドは成功したが --out の指す先が書き込み不可なら警告を出し専用の終了コードで知らせる" {
    out_dir="$(mktemp -d -t run-isolated-test-out.XXXXXX)"
    chmod 500 "$out_dir"
    run "$RUN_ISOLATED" "$REPO_DIR" --out "$out_dir" -- sh -c 'echo hello > "$COVERAGE_OUT_DIR/result.txt"'
    chmod 700 "$out_dir"
    # 取り出しの失敗が「正常終了(0)」に化けていないことを見る。
    # 中のコマンド自体は成功しているので、素の 0/1 と衝突しない
    # 専用コード（3）であることまで確かめる。
    [ "$status" -eq 3 ]
    [[ "$output" == *"警告"* ]]
    [ ! -e "$out_dir/result.txt" ]
    rm -rf -- "$out_dir"
}

@test "中のコマンドが失敗し --out の指す先も書き込み不可なら、中のコマンドの終了コードを優先して伝え警告も出す" {
    out_dir="$(mktemp -d -t run-isolated-test-out.XXXXXX)"
    chmod 500 "$out_dir"
    run "$RUN_ISOLATED" "$REPO_DIR" --out "$out_dir" -- sh -c 'echo partial > "$COVERAGE_OUT_DIR/partial.txt"; exit 1'
    chmod 700 "$out_dir"
    # 取り出しにも失敗しているが、中のコマンドの終了コード（1）が
    # 専用コード（3）に上書きされず、そのまま外へ伝わることを見る。
    [ "$status" -eq 1 ]
    [[ "$output" == *"警告"* ]]
    [ ! -e "$out_dir/partial.txt" ]
    rm -rf -- "$out_dir"
}

# 層1 Task 3: 本番資産の mtime 差分。
#
# bwrap の下からは本番の監視対象へ物理的に書けない（それが隔離の目的その
# ものなので、これは正しい振る舞い）。そのため「走行中に監視対象が変わる」
# 状況は、--out の指す先を監視対象そのものに重ねることで作る。--out の
# 取り出しはこの道具自身がホスト側へ書く経路であり、それが監視対象と重なる
# ことは実際に起こりうる（本番資産の保護が要る理由そのもの）。
#
# VERIFY_TESTS_WATCHED / VERIFY_TESTS_WATCHED_EXCLUDE でフィクスチャへ
# 差し替える。実物の本番パスへは触れない。

@test "監視対象のディレクトリへ --out が書くと報告に出て非0で終わる" {
    watched_dir="$(mktemp -d -t run-isolated-test-watched.XXXXXX)"
    export VERIFY_TESTS_WATCHED="$watched_dir"
    run "$RUN_ISOLATED" "$REPO_DIR" --out "$watched_dir" -- sh -c 'echo hello > "$COVERAGE_OUT_DIR/result.txt"'
    unset VERIFY_TESTS_WATCHED
    [ "$status" -eq 4 ]
    [[ "$output" == *"本番へ書いた: $watched_dir/result.txt"* ]]
    rm -rf -- "$watched_dir"
}

@test "監視対象が変わらなければ報告が空で0で終わる" {
    watched_dir="$(mktemp -d -t run-isolated-test-watched.XXXXXX)"
    echo before > "$watched_dir/existing.txt"
    export VERIFY_TESTS_WATCHED="$watched_dir"
    run "$RUN_ISOLATED" "$REPO_DIR" -- true
    unset VERIFY_TESTS_WATCHED
    [ "$status" -eq 0 ]
    [[ "$output" != *"$watched_dir"* ]]
    rm -rf -- "$watched_dir"
}

@test "監視の一覧が空なら監視していないと分かる形で報告する" {
    export VERIFY_TESTS_WATCHED=""
    run "$RUN_ISOLATED" "$REPO_DIR" -- true
    unset VERIFY_TESTS_WATCHED
    [ "$status" -eq 0 ]
    [[ "$output" == *"監視対象なし"* ]]
}

@test "環境変数の除外に当てはまる変化は判定に算入せず報告だけする" {
    watched_dir="$(mktemp -d -t run-isolated-test-watched.XXXXXX)"
    export VERIFY_TESTS_WATCHED="$watched_dir"
    export VERIFY_TESTS_WATCHED_EXCLUDE="$watched_dir"
    run "$RUN_ISOLATED" "$REPO_DIR" --out "$watched_dir" -- sh -c 'echo hello > "$COVERAGE_OUT_DIR/result.txt"'
    unset VERIFY_TESTS_WATCHED VERIFY_TESTS_WATCHED_EXCLUDE
    [ "$status" -eq 0 ]
    [[ "$output" == *"変化（判定に算入しない）: $watched_dir/result.txt"* ]]
    rm -rf -- "$watched_dir"
}
