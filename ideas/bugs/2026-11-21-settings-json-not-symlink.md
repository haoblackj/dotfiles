# ~/.claude/settings.json が symlink でなく実体のファイルになっていて、ソースとずれている

## 見えたこと

Herdr から Orca へ移す作業で `~/.claude/settings.json` に一行足そうとしたとき、`ls -l` と `readlink -f` で、symlink ではなく通常のファイルだった。
本番の作業コピーの `linked/claude/settings.json` と `cmp` すると、404 行目で違っていた。
README と CLAUDE.md は、このファイルを `linked/claude/settings.json` への symlink として扱っている。

## 見つけた場所

- `~/.claude/settings.json`
- `~/.local/share/chezmoi/linked/claude/settings.json`
- `dot_claude/symlink_settings.json.tmpl`
