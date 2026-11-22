#!/usr/bin/env bats
# .pre-commit-config.yaml の pre-push の bats のフックのテスト。
# 本番の作業コピーでは .claude/worktrees/ の下に別のワークツリーがあり、
# bats -r . がその下のテストまで拾って 3000 件を超えて走らせ、push が 10 分を超えた（2026-11-22）。
set -u

setup() {
    # 外から GIT_DIR などを受け継ぐと、一時のリポジトリでなく本体へ書き込む（2026-10-01）。
    unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    cp "$BATS_TEST_DIRNAME/.pre-commit-config.yaml" "$REPO/"
    printf '@test "ok" { true; }\n' > "$REPO/pass.bats"
    git -C "$REPO" add .pre-commit-config.yaml pass.bats
    # 追跡していない別のワークツリーの .bats。拾って走らせると落ちる。
    mkdir -p "$REPO/.claude/worktrees/other"
    printf '@test "ng" { false; }\n' > "$REPO/.claude/worktrees/other/fail.bats"
}

@test "bats のフックは追跡している .bats だけを走らせ、別のワークツリーの下は拾わない" {
    cd "$REPO"
    run pre-commit run bats --hook-stage pre-push --all-files
    [ "$status" -eq 0 ]
    [[ "$output" == *"1..1"* ]]
}
