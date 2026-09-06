#!/usr/bin/env bats
# mutation-target: dot_local/private_bin/executable_list-untested-shell.sh
# list-untested-shell.sh が、追跡 .sh のうちテストを持たないものを
# 正しく列挙することを確かめる。詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。

setup() {
    LIST="$BATS_TEST_DIRNAME/list-untested-shell.sh"
    PENGUINEX_REPO="/home/yagu001/repo/github.com/haoblackj/penguinEx/.claude/worktrees/issue-16-mutation"
    CHEZMOI_REPO="$HOME/.local/share/chezmoi"
}

@test "テストを持たない実装が一覧に出る" {
    run "$LIST" "$PENGUINEX_REPO" "$CHEZMOI_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *".claude/skills/morning/check-memory-drift.sh"* ]]
    [[ "$output" == *"/install.sh"* ]]
}

@test "実測で19本になる(penguinEx 5、chezmoi 14)" {
    run "$LIST" "$PENGUINEX_REPO" "$CHEZMOI_REPO"
    [ "$status" -eq 0 ]
    total="$(printf '%s\n' "$output" | grep -c .)"
    [ "$total" -eq 19 ]

    penguinex_count="$(printf '%s\n' "$output" | grep -c -F -- "$PENGUINEX_REPO/")"
    chezmoi_count="$(printf '%s\n' "$output" | grep -c -F -- "$CHEZMOI_REPO/")"
    [ "$penguinex_count" -eq 5 ]
    [ "$chezmoi_count" -eq 14 ]
}

@test "本番のフックに配線済みの2本が一覧に含まれる" {
    run "$LIST" "$PENGUINEX_REPO" "$CHEZMOI_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dot_claude/hooks/route-deletes-to-trash.sh"* ]]
    [[ "$output" == *"dot_claude/hooks/executable_chezmoi-auto-apply.sh"* ]]
}

@test "テストを持つ実装は一覧に出ない" {
    run "$LIST" "$PENGUINEX_REPO" "$CHEZMOI_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" != *"/check-issues.sh"* ]]
    [[ "$output" != *"executable_guard-destructive-git.sh"* ]]
    # この計画がchezmoiへ足した3本自身も、mutation-target宣言でテストを
    # 持つと認識されるはず。ここが漏れると一覧が22本に戻る（Step 4）。
    [[ "$output" != *"executable_run-isolated.sh"* ]]
    [[ "$output" != *"executable_check-coverage-sources.sh"* ]]
    [[ "$output" != *"executable_list-untested-shell.sh"* ]]
}

@test "テストファイル自身は一覧に出ない" {
    run "$LIST" "$PENGUINEX_REPO" "$CHEZMOI_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" != *"check-issues.test.sh"* ]]
    [[ "$output" != *"test_check_repo.sh"* ]]
    [[ "$output" != *"executable_guard-destructive-git.test.sh"* ]]
}
