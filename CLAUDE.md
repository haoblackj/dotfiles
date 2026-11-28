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
| `dot_claude/external-skills.txt`（宣言） | 外部のメンテナが作る公開スキル（`imozuru`、REA のスキルなど）。`~/.local/bin/external-skills` が skills CLI などの上流の手段で `~/.agents/skills/` へ入れる。claude-private に置かない |
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
dot_claude/external-skills.txt        — 外から取ってくるスキルの宣言（README「外から取ってくるスキル」）。cloud の行は install-cloud.sh がクラウドへも配る
dot_local/private_bin/executable_external-skills — 宣言どおりに入れる（install）、最新へ上げる（update）
dot_zshrc.tmpl / dot_gitconfig.tmpl
.chezmoiexternal.toml                 — book-to-skill (公開external) + claude-private clone定義
```

スキルの実体は `dot_claude/skills/` に実ディレクトリとして置かない（同期フックの `migrate_new` が claude-private へ吸い込む）。
公開の自作スキルはリポジトリ直下の `skills/` に置き、`dot_claude/skills/` には symlink テンプレートだけを置く。
外部のメンテナが作るスキルは `dot_claude/external-skills.txt` に宣言し、同期フックは宣言の名前と `synced`（Claude.ai から同期されたスキル。`syncClaudeAiSkills: false` で止めてある）を取り込まない。
`book-to-skill` は git external で upstream から clone し、機密のものは private repo に置いて sync hook が `~/.claude/skills/` へ symlink する。
開発の流れは README「公開の自作スキル」。

## push の最中の作業コピー

pre-push（pre-commit の pytest と bats、数分かかる）は、コミットしていない変更を一度よけて、終わったら戻す。
その間に同じ作業コピーのファイルを編集すると、戻すところで食い違って push が落ち、編集も巻き戻る。

- 自分の push は、先にすべてコミットし、終わるまで作業コピーを編集しない。結果は `git rev-parse origin/<ブランチ>` で確かめる。
- 本番の作業コピー（`~/.local/share/chezmoi`）は別のセッションも push する。未コミットの変更が消えて見えたら、置き直す前に `pgrep -af 'git push|pre-commit'` で別の push が走っていないかを確かめ、走っていれば終わるのを待つ。
- 出来事: 2026-11-20 に ops/work-records の push が 2 回落ちた。2026-11-21 に別のセッションの push の最中に変更を置き直し、push が落ちた（Refs #86）。

<!-- claude-private-sync.sh:
     pull (SessionStart): git pull --ff-only → symlink確立
     push (Stop): migrate_new() → commit → git push。失敗時はstderrに出して継続（exit 0） -->
