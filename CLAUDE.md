# Chezmoi Dotfiles — Claude Code Instructions

## このリポジトリの目的

haoblackj のdotfilesをchezmoiで管理するリポジトリ。Claude Code設定（settings / hooks / skills）もここで管理し、`chezmoi apply`でデプロイする。

<!-- chezmoi apply は dot_claude/ 配下のファイル編集時に PostToolUse フックが自動実行する。
     手動が必要な場合: chezmoi apply ~/.claude/ (dot_claude/ のみ) / chezmoi apply (全体) -->

## 公開/非公開の境界（厳守）

| 置き場所 | 内容 |
|---|---|
| `dot_claude/` (このrepo) | settings / hooks / keybindings |
| リポジトリ直下の `skills/` (このrepo) | 公開の自作スキル。`dot_claude/skills/symlink_<名前>.tmpl` で `~/.claude/skills/<名前>` へ symlink する |
| `.chezmoiexternal.toml` の git external | `book-to-skill`（公開・upstream追跡。著作権はupstream） |
| `~/.local/share/claude-private/` | memory 全体 / 機密・自作改変スキル（書籍のスキル、`report-skills` など） |

**非公開データ（memory内容・書籍スキル・自作改変したスキル）を `dot_claude/` に書いてはいけない。**

`report-skills` は元は公開スキルだが、こちらで改変を加えているため非公開（private repo）扱いとする。

## ファイル構造

```
dot_claude/                           — chezmoi source → ~/.claude/
  symlink_settings.json.tmpl          — ~/.claude/settings.json を linked/claude/settings.json への symlink にする
  skills/symlink_<名前>.tmpl          — ~/.claude/skills/<名前> を skills/<名前> への symlink にする
  hooks/
    executable_claude-private-sync.sh — SessionStart/Stop: private repo同期
    executable_chezmoi-auto-apply.sh  — PostToolUse: dot_claude/ 編集時に自動apply
linked/claude/settings.json           — グローバルClaude Code設定の実体（Claude Code が直接書き戻す。README「ソースとターゲットの往復」）
skills/<名前>/SKILL.md                — 公開の自作スキルの実体（.chezmoiignore でホームへは配らない）
run_once_NN_*.sh.tmpl                 — 環境セットアップ（.claude/rules/run_once.md 参照）
install-cloud.sh                      — Claude Code on the web の Setup script 用。dot_claude/ の一部を ~/.claude/ へ写す（README「クラウドセッション」）
cloud-skills.txt                      — install-cloud.sh がクラウドにだけ配る第三者の公開スキルの一覧（サブディレクトリを写す）
dot_zshrc.tmpl / dot_gitconfig.tmpl
.chezmoiexternal.toml                 — book-to-skill (公開external) + claude-private clone定義
```

スキルの実体は `dot_claude/skills/` に実ディレクトリとして置かない（同期フックの `migrate_new` が claude-private へ吸い込む）。
公開の自作スキルはリポジトリ直下の `skills/` に置き、`dot_claude/skills/` には symlink テンプレートだけを置く。
`book-to-skill` は git external で upstream から clone し、機密のものは private repo に置いて sync hook が `~/.claude/skills/` へ symlink する。
開発の流れは README「公開の自作スキル」。

## 本番の作業コピーのブランチ

本番の作業コピー（`~/.local/share/chezmoi`）は `main` に乗せたままにする。
本番の作業コピーが別のブランチか切り離した HEAD に移ると `main` が空き、Orca のワークスペースの作成で `main` を選ぶだけで、そのワークツリーが `main` を取り出せる。
git は 1 つのブランチを 2 つのワークツリーで取り出せないので、本番の作業コピーが `main` に戻れなくなる。

- 作業のブランチは、本番の作業コピーで切り替えず、ワークツリーで切る。
- 本番の作業コピーは `git pull --ff-only` で進める。
- `main` をほかのワークツリーが取り出していて戻れないときは、切り離した HEAD で進めず、`git worktree list` で取り出しているワークツリーを探し、そちらで `git switch --detach` を打ってから本番の作業コピーを `main` に戻す。打つのは、そのワークツリーで動いている Claude Code と未コミットの変更を確かめてから。
- 出来事: 2026-11-21 に、本番の作業コピーが作業のブランチに乗っている間に Orca のワークツリー `main-2` が `main` を取り出し、2026-11-25 まで本番の作業コピーが切り離した HEAD で進んだ（`docs/work/orca-main-held.md`）。

## push の最中の作業コピー

pre-push（pre-commit の pytest と bats、数分かかる）は、コミットしていない変更を一度よけて、終わったら戻す。
その間に同じ作業コピーのファイルを編集すると、戻すところで食い違って push が落ち、編集も巻き戻る。

- 自分の push は、先にすべてコミットし、終わるまで作業コピーを編集しない。結果は `git rev-parse origin/<ブランチ>` で確かめる。
- 本番の作業コピー（`~/.local/share/chezmoi`）は別のセッションも push する。未コミットの変更が消えて見えたら、置き直す前に `pgrep -af 'git push|pre-commit'` で別の push が走っていないかを確かめ、走っていれば終わるのを待つ。
- 出来事: 2026-11-20 に ops/work-records の push が 2 回落ちた。2026-11-21 に別のセッションの push の最中に変更を置き直し、push が落ちた（Refs #86）。

<!-- claude-private-sync.sh:
     pull (SessionStart): git pull --ff-only → symlink確立
     push (Stop): migrate_new() → commit → git push。失敗時はstderrに出して継続（exit 0） -->
