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
| `~/.local/share/claude-private/` | memory 全体 / 機密・自作改変スキル（`idenshi-hakase-diet` / `learning-efficiency-book` / `report-skills` など）/ 移行前の自作スキル（dotfiles#49） |

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
dot_zshrc.tmpl / dot_gitconfig.tmpl
.chezmoiexternal.toml                 — book-to-skill (公開external) + claude-private clone定義
```

スキルの実体は `dot_claude/skills/` に実ディレクトリとして置かない（同期フックの `migrate_new` が claude-private へ吸い込む）。
公開の自作スキルはリポジトリ直下の `skills/` に置き、`dot_claude/skills/` には symlink テンプレートだけを置く。
`book-to-skill` は git external で upstream から clone し、機密のものは private repo に置いて sync hook が `~/.claude/skills/` へ symlink する。
開発の流れは README「公開の自作スキル」。

<!-- claude-private-sync.sh:
     pull (SessionStart): git pull --ff-only → symlink確立
     push (Stop): migrate_new() → commit → git push。失敗時はstderrに出して継続（exit 0） -->
