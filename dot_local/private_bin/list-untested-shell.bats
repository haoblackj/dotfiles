#!/usr/bin/env bats
# list-untested-shell.sh が、追跡 .sh のうちテストを持たないものを
# 正しく列挙することを確かめる。詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。

setup() {
    LIST="$BATS_TEST_DIRNAME/list-untested-shell.sh"
    # issue #16 用のワークツリーは作業が終われば消える一時的な存在。
    # 消えた瞬間にこの絶対パスを固定していると exit 2 になり全件が
    # 恒久的に赤くなるので、存在すればワークツリー、無ければ main の
    # チェックアウトへ自動で落とす。ただし main へ単純に向け替えるだけ
    # では直らない: このブランチがまだ main へマージされていない間は
    # main 側の一覧が19本ではなく25本になる（超過6本は
    # check-repo.sh・check-gpu-tdr.sh・check-issues.sh・
    # memory-triage-scan.sh・check_claude_hooks.sh・check_claude_md.sh
    # の mutation-target 宣言コミットがまだ main に無いため、実測済み）。
    # 両方の状態で赤くならないよう、存在チェックで切り替える。
    # マージ後にワークツリーが消えれば main は19本になっているはず。
    # PENGUINEX_REPO_OVERRIDE で明示的に上書きもできる（切り替えの
    # 手動確認・デバッグ用）。
    local worktree="/home/yagu001/repo/github.com/haoblackj/penguinEx/.claude/worktrees/issue-16-mutation"
    local main_checkout="$HOME/repo/github.com/haoblackj/penguinEx"
    if [ -n "${PENGUINEX_REPO_OVERRIDE:-}" ]; then
        PENGUINEX_REPO="$PENGUINEX_REPO_OVERRIDE"
    elif [ -d "$worktree" ]; then
        PENGUINEX_REPO="$worktree"
    else
        PENGUINEX_REPO="$main_checkout"
    fi
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
    # この計画がchezmoiへ足した3本自身も、命名規約(<name>.bats ↔
    # executable_<name>.sh)でテストを持つと認識されるはず。ここが漏れる
    # と一覧が22本に戻る（Step 4）。
    [[ "$output" != *"executable_run-isolated.sh"* ]]
    [[ "$output" != *"executable_check-coverage-sources.sh"* ]]
    [[ "$output" != *"executable_list-untested-shell.sh"* ]]
}

@test "テストファイル自身は一覧に出ない" {
    run "$LIST" "$PENGUINEX_REPO" "$CHEZMOI_REPO"
    [ "$status" -eq 0 ]
    # 層4b Task 9 で判定を .bats の命名規約へ切り替えた。以前の
    # フィクスチャ名（check-issues.test.sh・test_check_repo.sh・
    # executable_guard-destructive-git.test.sh）は層4a/Task 6/Task 2の
    # 移行でとうに存在しなくなっており、「存在しない名前が出ないこと」
    # を確かめるだけの空振りになっていた。移行後の実名へ差し替える。
    # .bats は git ls-files '*.sh' の候補集合に入らないため一覧へは
    # 構造的に出ない。ここでは名前が実在するファイルであることに加え、
    # 対応する実装（check-issues.sh・check-repo.sh・
    # guard-destructive-git.sh）が命名規約の対応づけで一覧から正しく
    # 除かれていることも確かめ、空振りにしない。
    # 上記に加えて、いまは list-untested-shell.sh が git ls-files '*.sh'
    # からしか候補を採らないため、".bats" という文字列自体が出力に
    # 出ようがない（all_bats は除外集合の計算にしか使われない）。
    # つまり次の3行は実装が正しくても間違っていても常に通り、
    # 構造的に落ちない。それでも消さずに残しているのは、層5が
    # テストの門を .bats も拾う形へ変えたとき、この3行が生きた
    # 検査へ戻るため。この下に続く、直下の .sh を見る3行が、
    # 現時点で実際に判別している側。
    [[ "$output" != *"check-issues.bats"* ]]
    [[ "$output" != *"check-repo.bats"* ]]
    [[ "$output" != *"guard-destructive-git.bats"* ]]
    [[ "$output" != *"/check-issues.sh"* ]]
    [[ "$output" != *"/check-repo.sh"* ]]
    [[ "$output" != *"/executable_guard-destructive-git.sh"* ]]
}
