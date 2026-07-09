# haoblackj's Dot Files

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/haoblackj/dotfiles)

## Installation

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply haoblackj
```

## Manual

node / npm グローバルパッケージ（nvm LTS 導入・yarn・commitizen・ccstatusline）は
`run_once_82_npm-global.sh.tmpl` が `nvm.sh` を明示 source して冪等に導入するため手動不要。
残る手動手順は以下。

```zsh
aicommit2 setup
```

```
brew install bitwarden-cli
gh repo clone joaojacome/bitwarden-ssh-agent
```

## herdr

`run_once_80`(brew本体)/`run_once_83`(agent skill)/`run_once_84`(プラグイン: reviewr, herdr-plus,
command-palette)/`run_once_86`(Claude Code統合フック)で新規マシンでも自動導入される。キーバインドは
`dot_config/herdr/config.toml`の`[[keys.command]]`で`prefix+a`にコマンドパレット(fzf)を割当済み。
キーバインド・導入済みプラグインactionのチートシート:
- 恒久コピー: [`docs/herdr-cheatsheet.html`](docs/herdr-cheatsheet.html)（ローカル/ブラウザで直接開ける単体HTML）
- ライブ版(検索UI付き): https://claude.ai/code/artifact/d13eca3b-71cc-40e5-a62b-1b897aa6c4c9 （claude.ai Artifactとしてホスト、長期保持を保証する公式記述は未確認）

## Claude Code StatusLine

`ccstatusline`（pin: `run_once_82_npm-global.sh.tmpl` が `npm i -g ccstatusline@<ver>` を自動実行）。
設定は `dot_config/ccstatusline/settings.json`、Claude 側は `dot_claude/private_settings.json` の
`statusLine.command = "ccstatusline"`。5h/7d 使用率を Claude Code が stdin に流す `rate_limits`
（`five_hour` / `seven_day` の `used_percentage`）から表示する。バージョンを上げるときは
run_once スクリプトの pin を書き換えると `chezmoi apply` で再導入される。

