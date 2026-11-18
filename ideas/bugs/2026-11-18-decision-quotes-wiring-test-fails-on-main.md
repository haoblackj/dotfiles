# origin/main で、guard-decision-quotes.py の配線の bats テストが落ちて push できない

## 見えたこと

origin/main から切ったブランチを push すると、pre-push の bats で `not ok 206 guard-decision-quotes.py が PreToolUse の Bash に配線されている` が落ちた（`AssertionError: PreToolUse: []`）。
origin/main には `dot_claude/hooks/executable_guard-decision-quotes.py` と `guard-decision-quotes.bats` があり、`linked/claude/settings.json` には `guard-decision-quotes` の文字列が無い。
`git log -S'guard-decision-quotes' origin/main` に出るのは PR #92 と、それを取り消した PR #93 だけ。
ワークツリー `decision-quote-guard`（ブランチ `worktree-decision-quote-guard`、コミット b5763eb、Refs #86）が残っている。

## 見つけた場所

`dot_claude/hooks/settings-wiring.bats` の 145 行目、`linked/claude/settings.json`。
