# Chezmoi Dotfiles — Claude Code Instructions

## このリポジトリの目的

haoblackj のdotfilesをchezmoiで管理するリポジトリ。Claude Code設定（settings / hooks / skills）もここで管理し、`chezmoi apply`でデプロイする。

<!-- chezmoi apply は dot_claude/ 配下のファイル編集時に PostToolUse フックが自動実行する。
     手動が必要な場合: chezmoi apply ~/.claude/ (dot_claude/ のみ) / chezmoi apply (全体) -->

## 公開/非公開の境界（厳守）

| 置き場所 | 内容 |
|---|---|
| `dot_claude/` (このrepo) | settings / hooks / keybindings |
| `.chezmoiexternal.toml` の git external | `book-to-skill`（公開・upstream追跡。著作権はupstream） |
| `~/.local/share/claude-private/` | memory 全体 / 機密・自作改変スキル（`dig` / `idenshi-hakase-diet` / `learning-efficiency-book` / `report-skills`） |

**非公開データ（memory内容・書籍スキル・自作改変したスキル）を `dot_claude/` に書いてはいけない。**

`report-skills` は元は公開スキルだが、こちらで改変を加えているため非公開（private repo）扱いとする。

## ファイル構造

```
dot_claude/                           — chezmoi source → ~/.claude/
  settings.json                       — グローバルClaude Code設定
  hooks/
    executable_claude-private-sync.sh — SessionStart/Stop: private repo同期
    executable_chezmoi-auto-apply.sh  — PostToolUse: dot_claude/ 編集時に自動apply
run_once_NN_*.sh.tmpl                 — 環境セットアップ（.claude/rules/run_once.md 参照）
dot_zshrc.tmpl / dot_gitconfig.tmpl
.chezmoiexternal.toml                 — book-to-skill (公開external) + claude-private clone定義
```

スキルは `dot_claude/skills/` には置かない。`book-to-skill` は git external で upstream から clone、
それ以外（自作・機密）は private repo に置き、sync hook が `~/.claude/skills/` へ symlink する。

<!-- claude-private-sync.sh:
     pull (SessionStart): git pull --ff-only → symlink確立
     push (Stop): migrate_new() → commit → git push。失敗時はstderrに出して継続（exit 0） -->
