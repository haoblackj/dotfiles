# gh の書き込みを止めるフックが、`git push 2>&1` の `2` を送り先として読んで止める

## 見えたこと

上流の設定があるブランチで `git push 2>&1 | grep -v '^ok ' | tail -3` を打つと、`guard-gh-target-repo.py` が「git push の送り先 2 の URL を確かめられません」で止めた。
`git push origin <ブランチ> 2>&1 | ...` と送り先を書くと通った。

## 見つけた場所

`dot_claude/hooks/guard-gh-target-repo.py` の `check_git`（PreToolUse の Bash）。
