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
    export VERIFY_TESTS_WATCHED="$watched_dir"

    # まず監視が実際に有効であることを確かめる（対象が1件以上あり、走行の
    # 前後で mtime を実際に読んでいることの証拠）。ここが通らなければ
    # 「報告が空」が「変化が無かったから」なのか「そもそも監視していない
    # から」なのか区別できない。mtime 差分が実装されていなければ、この
    # ブロックの時点でこのテストは赤くなる。
    run "$RUN_ISOLATED" "$REPO_DIR" --out "$watched_dir" -- sh -c 'echo hello > "$COVERAGE_OUT_DIR/result.txt"'
    [ "$status" -eq 4 ]
    [[ "$output" == *"本番へ書いた: $watched_dir/result.txt"* ]]

    # 監視が有効だと確かめた上で、改めて何も書き換えない走行を見る。
    # ここでの「報告が空・終了コード0」は、直前のブロックで監視が働いて
    # いることを既に確認済みなので、「変化が無かったから空」だと言える。
    run "$RUN_ISOLATED" "$REPO_DIR" -- true
    [ "$status" -eq 0 ]
    [[ "$output" != *"$watched_dir"* ]]

    unset VERIFY_TESTS_WATCHED
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

# 層1 Task 4: ラッパーを意図的に壊し、テストが実際に赤くなることを確かめる。
#
# 壊すのは常に $RUN_ISOLATED（配置先の実物）の「複製」に対してのみ行う。
# 複製は各テストの中で mktemp によりその場で作り、走行後に消す。$RUN_ISOLATED
# 自身は一切書き換えない。各テストは「壊した複製で赤くなる」ことと「壊して
# いない原本で緑になる」ことの両方を1つのテストの中で確かめる。片方だけでは
# 検査が効いているかどうか判断できない。
#
# (a) の壊し方は統制側の裁定に従う。RO_BINDS には環境変数での差し替え口が
# 無いため、複製の中で一覧そのものをテスト用のフィクスチャ（自作の空
# ディレクトリで、本番の実データではない）へ書き換えたうえで、そのフィクス
# チャへの bind を --ro-bind から --bind へ変える。原本側は RO_BINDS を
# 差し替えられないため、実在するエントリ（~/.claude/hooks）へ書き込みが
# 「失敗する」ことだけを見る。書き込みは期待どおり失敗するので、本番の
# ファイルには一切触れない。

@test "(a) RO_BINDSをフィクスチャへ差し替え--bindへ変えると読み取り専用のはずのパスへ書けてしまうが、原本の既存RO_BINDSは書き込みを防ぐ" {
    fixture_dir="$(mktemp -d -t run-isolated-test-mutant-a-fixture.XXXXXX)"
    mutant_marker="$fixture_dir/marker"
    mutant="$(mktemp -t run-isolated-test-mutant-a.XXXXXX)"

    awk -v fixture="$fixture_dir" '
        /^RO_BINDS=\($/ { print; print "    \"" fixture "\""; print ")"; skip=1; next }
        skip && /^\)$/ { skip=0; next }
        skip { next }
        { print }
    ' "$RUN_ISOLATED" > "$mutant"
    sed -i 's#--ro-bind "$p" "$p")#--bind "$p" "$p")#' "$mutant"
    chmod +x "$mutant"

    # 実際に置換が起きたことを見る(空振りで両方とも変化なしだと、以降の
    # 赤/緑の判定が「もともとの挙動」を見ているだけになりかねない)。まだ
    # どちらの run も走っていないので、ここで落ちても本番へは何も届かない。
    [[ "$(cat "$mutant")" == *"$fixture_dir"* ]]
    ! grep -q -F -- '--ro-bind "$p" "$p")' "$mutant"

    # 壊した複製: フィクスチャ(本番ではない自作のディレクトリ)が
    # 書き込み可能になっている(赤=保護が効いていない状態)はず。
    run "$mutant" "$REPO_DIR" -- touch "$mutant_marker"
    mutant_status="$status"
    mutant_marker_exists=0
    [ -e "$mutant_marker" ] && mutant_marker_exists=1
    rm -f -- "$mutant"
    rm -rf -- "$fixture_dir"

    # 原本: 実在するRO_BINDSのエントリ(~/.claude/hooks)への書き込みは失敗する
    # はず(緑)。カーネルの読み取り専用bindが失敗を保証するが、万一 assert が
    # 落ちてもマーカーを本番のパスに残さないよう、存在確認と削除を assert
    # より前で行う。
    original_marker="$HOME/.claude/hooks/.run-isolated-mutation-test-marker-$$"
    run "$RUN_ISOLATED" "$REPO_DIR" -- touch "$original_marker"
    original_status="$status"
    original_marker_exists=0
    [ -e "$original_marker" ] && original_marker_exists=1
    rm -f -- "$original_marker"

    [ "$mutant_status" -eq 0 ]
    [ "$mutant_marker_exists" -eq 1 ]
    [ "$original_status" -ne 0 ]
    [ "$original_marker_exists" -eq 0 ]
}

@test "(b) diff_watchedの呼び出しを外すと本番資産への書き込みを見逃すが、原本は検出する" {
    watched_dir="$(mktemp -d -t run-isolated-test-mutant-b-watched.XXXXXX)"
    mutant="$(mktemp -t run-isolated-test-mutant-b.XXXXXX)"
    grep -v -F -- 'diff_watched watched_before watched_after mutation_counted mutation_noted' "$RUN_ISOLATED" > "$mutant"
    chmod +x "$mutant"

    ! grep -q -F -- 'diff_watched watched_before watched_after mutation_counted mutation_noted' "$mutant"

    export VERIFY_TESTS_WATCHED="$watched_dir"

    # 壊した複製: 監視対象への書き込みが起きても検出されず0で終わる(赤)。
    run "$mutant" "$REPO_DIR" --out "$watched_dir" -- sh -c 'echo hello > "$COVERAGE_OUT_DIR/result.txt"'
    [ "$status" -eq 0 ]

    rm -f -- "$watched_dir/result.txt"

    # 原本: 同じ状況で検出し、専用の終了コード(4)で報告する(緑)。
    run "$RUN_ISOLATED" "$REPO_DIR" --out "$watched_dir" -- sh -c 'echo hello > "$COVERAGE_OUT_DIR/result.txt"'
    [ "$status" -eq 4 ]
    [[ "$output" == *"本番へ書いた: $watched_dir/result.txt"* ]]

    unset VERIFY_TESTS_WATCHED
    rm -f -- "$mutant"
    rm -rf -- "$watched_dir"
}

@test "(c) 使い捨てHOMEへの差し替えを外すと本番のHOMEが隔離の中に見えるが、原本は見せない" {
    marker="$HOME/.run-isolated-mutation-test-marker-c-$$"
    : > "$marker"
    mutant="$(mktemp -t run-isolated-test-mutant-c.XXXXXX)"
    grep -v -F -- '--bind "$sandbox" "$HOME"' "$RUN_ISOLATED" > "$mutant"
    chmod +x "$mutant"

    ! grep -q -F -- '--bind "$sandbox" "$HOME"' "$mutant"

    # 壊した複製: 使い捨てHOMEへ差し替わらず、本番のHOMEがそのまま見えるはず(赤)。
    run "$mutant" "$REPO_DIR" -- test -e "$marker"
    mutant_status="$status"

    # 原本: 使い捨てHOMEへ差し替わっており、マーカーは見えないはず(緑)。
    # 同じマーカーを両方の走行で使うため、削除は両方の run が終わったあと・
    # assert より前で行う(assert が落ちても本番のHOMEに痕跡を残さない)。
    run "$RUN_ISOLATED" "$REPO_DIR" -- test -e "$marker"
    original_status="$status"

    rm -f -- "$marker" "$mutant"

    [ "$mutant_status" -eq 0 ]
    [ "$original_status" -eq 1 ]
}

# 上記3つの壊し方は、いずれもファイル中の特定の文字列を置換(grep -v /
# sed)することで作っている。その置換対象が2箇所以上に当たると、意図しない
# 場所も壊れ、「別の理由で赤くなったのに確認できたと読める」空振りになる
# (過去に実際に起きている)。run-isolated.sh は Task 5 で venv 用の
# --ro-bind を足すためにもう一度書き換わる予定で、書き方によっては (a) の
# 置換対象が2箇所に当たるようになりうる。一度確かめて終わりにせず、常時
# 走るテストとして置いておく。

@test "(a) 壊すために使う置換対象の文字列がrun-isolated.shの中で一意である" {
    run grep -c -F -- '--ro-bind "$p" "$p")' "$RUN_ISOLATED"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "(b) 壊すために使う置換対象の文字列がrun-isolated.shの中で一意である" {
    run grep -c -F -- 'diff_watched watched_before watched_after mutation_counted mutation_noted' "$RUN_ISOLATED"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "(c) 壊すために使う置換対象の文字列がrun-isolated.shの中で一意である" {
    run grep -c -F -- '--bind "$sandbox" "$HOME"' "$RUN_ISOLATED"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

# 層1 Task 5: カバレッジを取れる python が隔離の中で使える状態にする。
# venv 本体（~/.local/share/penguinex-test-venv）は git 管理外。
# venv の作り方・要求バージョンは test-requirements.txt を参照。

@test "隔離の中でpythonがvenvのものを指す" {
    run "$RUN_ISOLATED" "$REPO_DIR" -- python -c 'import sys; print(sys.executable)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"penguinex-test-venv"* ]]
}

@test "隔離の中でimport coverageが成功する" {
    run "$RUN_ISOLATED" "$REPO_DIR" -- python -c 'import coverage'
    [ "$status" -eq 0 ]
}

@test "隔離の中でimport pytest_covが成功する" {
    run "$RUN_ISOLATED" "$REPO_DIR" -- python -c 'import pytest_cov'
    [ "$status" -eq 0 ]
}

@test "venvのパスがrun-isolated.shの中で1箇所にだけ書かれている" {
    run grep -c -F -- "penguinex-test-venv" "$RUN_ISOLATED"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}
