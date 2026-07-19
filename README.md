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

## Claude Code Memory Recall

発言のたびに `UserPromptSubmit` フックが Cloudflare Workers AI（`@cf/baai/bge-m3`）で発言を
埋め込み、プロジェクトの auto-memory 全ファイル（description＋本文）の埋め込みキャッシュと
内積比較して、類似度 0.55 以上の上位 3 件を「パス＋一行説明」でコンテキストへ自動注入する。
`MEMORY.md` の 200 行/25KB 制限で索引に載らないメモリも意味検索で想起させるのが目的。
常駐プロセスなし・stdlib のみ・失敗時は注入なしの exit 0 で静かに縮退（Cloudflare 障害時は
Claude 本体も落ちるため専用対策なし）。定常レイテンシ実測 0.2 秒、Workers AI 無料枠内で 0 円。

依存関係（pip 依存ゼロ、外部バイナリ呼び出しなし）:

- `python3`（3.6 相当以上。標準ライブラリのみ使用: urllib/hashlib/json/math/re 等。WSL の
  Ubuntu 標準で充足し、venv も pip install も不要）
- `api.cloudflare.com` への HTTPS 到達性と Workers AI トークン（下記 secrets）
- Claude Code の auto-memory が有効でプロジェクトの memory ディレクトリが存在すること
- いずれが欠けても「注入なしの exit 0＋ログ」へ縮退するだけで、会話・他フックには影響しない

構成:

- フック本体/テスト: `dot_claude/hooks/memory_recall.py` / 同 `tests/test_memory_recall.py`
- 登録: `dot_claude/private_settings.json` の `hooks.UserPromptSubmit`（timeout 5 秒）
- 埋め込みキャッシュ: 各プロジェクト memory ディレクトリ直下 `.embeddings.json`
  （claude-private 同期に相乗り。破損時は自動でゼロ再生成される派生データ）
- ログ: `~/.claude/logs/memory-recall.log`（ローカル、5MB で自動 truncate）
- 設計/実装の経緯: penguinEx `docs/superpowers/specs/2026-07-18-memory-semantic-recall-design.md`
  と `docs/superpowers/plans/2026-07-19-memory-semantic-recall.md`

新規マシンのセットアップ:

1. `chezmoi apply`（フック本体と settings 登録が配布される）
2. claude-private 同期（SessionStart フックが自動 pull）で secrets
   `~/.local/share/claude-private/secrets/cloudflare-workers-ai-token`
   （`CF_ACCOUNT_ID`/`CF_API_TOKEN` の 2 行、chmod 600）と `.embeddings.json` が届く。
   トークンを失効・再発行する場合は Cloudflare ダッシュボード → API トークン →
   カスタムトークン（権限: アカウント / Workers AI / 編集）で作り直してこのファイルを更新
3. 動作確認（身長メモが 1 件注入されれば OK。空なら `memory-recall.log` を見る）:

```zsh
echo '{"prompt": "背が高い人に合う家具を探したい"}' | \
  MEMORY_RECALL_DIR=$HOME/.claude/projects/-home-yagu001-repo-github-com-haoblackj-penguinEx/memory \
  python3 ~/.claude/hooks/memory_recall.py
```

注意: `dot_claude/` 配下のソースを Claude Code の Write/Edit で編集すると
`chezmoi-auto-apply.sh` が `~/.claude/` 全体を apply し、`/config` で選んだ一時 model 等の
ターゲット側設定がソース側の値で上書きされる。避けたいときは Bash 経由で編集して
`chezmoi apply ~/.claude/hooks` の限定 apply にする。閾値 0.55 を較正し直すときは
`dot_claude/hooks/memory_recall.py` の `THRESHOLD` を書き換える（較正手順は上記 plan の Task 7 参照）。

