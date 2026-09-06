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
