# pre-push の pytest で test_guard_gh_target_repo.py の push 系 5 件が ERROR になり push が止まる

## 見えたこと

japanese-guard の閾値の変更（#83）のブランチを push したら、pre-push の pytest で次の 5 件が ERROR になり、push が止まった（154 passed、5 errors）。

- `test_push_to_own_remote_passes`
- `test_push_to_other_owners_remote_is_denied`
- `test_push_without_remote_uses_the_branch_remote`
- `test_push_of_commits_that_reference_other_issues_is_denied`
- `test_push_with_unresolvable_remote_is_denied`

同じワークツリーで `python3 -m pytest dot_claude/hooks/tests/test_guard_gh_target_repo.py -k push` を直接回すと 5 件とも pass した。
ブランチの変更は `skills/japanese-guard/` と spec だけで、このテストの対象には触れていない。

## 見つけた場所

`dot_claude/hooks/tests/test_guard_gh_target_repo.py`（最後に触ったコミットは `72c21ff`）。
pre-push の pytest の hook の中でだけ起きる。
