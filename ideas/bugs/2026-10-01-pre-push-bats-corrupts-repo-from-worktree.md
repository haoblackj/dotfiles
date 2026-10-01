# ワークツリーから push すると pre-push の bats が本体の git 設定と index を書き換える

## 見えたこと

`.worktrees/pr25`（PR #25 のブランチ）で `git push` したとき、pre-push フックの bats が失敗し、push も止まった。

- `claude-private-sync.bats` の A1〜A4、B1 などが `No .pre-commit-config.yaml file was found` を出して落ちた。
- bats の結果に `files were modified by this hook` と出た。
- 終わった後、ワークツリーの index に `.gitignore` の書き換え（`.pending-commit-message.*` の1行だけになる）と、`memory/proj/base.md`、`skills/mulmoterminal-xxx/palettes.json` の追加が載っていた（作業ツリーのファイルは HEAD のまま）。
- 本体の `.git/config` が `core.bare = true` に書き換わり、本チェックアウトで `git status` が `fatal: this operation must be run in a work tree` になった。

`git restore --staged` と `git config core.bare false` で戻した。ref と reflog に余計なコミットは無かった。

## 見つけた場所

- `dot_claude/hooks/claude-private-sync.bats`（落ちたテスト）
- pre-push フックの bats（`.pre-commit-config.yaml` の hook id `bats`）
- 本体の `.git/config`、ワークツリー `.worktrees/pr25` の index
