# Chezmoi Dotfiles — Codex Instructions

## このリポジトリの目的

haoblackj のdotfilesをchezmoiで管理するリポジトリ。Codex設定（settings / hooks / skills）もここで管理し、`chezmoi apply`でデプロイする。

<!-- chezmoi apply は dot_claude/ 配下のファイル編集時に PostToolUse フックが自動実行する。
     手動が必要な場合: chezmoi apply ~/.Codex/ (dot_claude/ のみ) / chezmoi apply (全体) -->

## 公開/非公開の境界（厳守）

| 置き場所 | 内容 |
|---|---|
| `dot_claude/` (このrepo) | settings / hooks / keybindings / スキル（著作権・機密なし） |
| `~/.local/share/Codex-private/` | memory 全体 / learning-efficiency-book スキル |

**非公開データ（memory内容・書籍スキル）を `dot_claude/` に書いてはいけない。**

## ファイル構造

```
dot_claude/                           — chezmoi source → ~/.Codex/
  settings.json                       — グローバルCodex設定
  hooks/
    executable_claude-private-sync.sh — SessionStart/Stop: private repo同期
    executable_chezmoi-auto-apply.sh  — PostToolUse: dot_claude/ 編集時に自動apply
  skills/
    report-skills/                    — 日本語レポート作成スキル
    book-to-skill/                    — 外部スキル（git external）
run_once_NN_*.sh.tmpl                 — 環境セットアップ（.Codex/rules/run_once.md 参照）
dot_zshrc.tmpl / dot_gitconfig.tmpl
```

<!-- Codex-private-sync.sh:
     pull (SessionStart): git pull --ff-only → symlink確立
     push (Stop): migrate_new() → commit → git push。失敗時はstderrに出して継続（exit 0） -->
