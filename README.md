# haoblackj's Dot Files

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/haoblackj/dotfiles)

WSL2（Ubuntu）の作業環境を chezmoi で再構築するためのリポジトリ。
WSL を初期化した直後にこの README だけ読めば同じ環境に戻せることを目的にしている。

## 管理しているもの

| 対象 | ソース | 備考 |
|---|---|---|
| シェル | `dot_zshrc.tmpl` / `zsh/` / `dot_bashrc` ほか | zi + powerlevel10k。プラグインは初回起動時に zi が clone する |
| git / gh | `dot_gitconfig.tmpl` / `dot_config/gh/` | github.com の認証は `gh auth git-credential`、それ以外は Windows 側 scoop の GCM |
| Claude Code | `dot_claude/` | settings / hooks / keybindings / CLAUDE.md / output-styles。境界は下記「Claude Code」 |
| Codex | `dot_codex/` | 委譲スクリプトと設定 |
| CLI ツール類 | `run_once_NN_*.sh.tmpl` | 導入スクリプト。中身は下記「自動で入るもの」 |
| systemd user unit | `dot_config/systemd/user/` | Bitwarden SSH agent ブリッジ、herdr の umask override |
| その他 `~/.config` | `dot_config/{herdr,nvim,lazygit,rtk,ccstatusline,fontconfig}` | |
| Windows 側 | `dot_wslconfig.tmpl` / `dot_config/{komorebi,whkd,yasb,glazewm,scoop}` / `dot_glzr/` / `AppData/` / `*.bat.tmpl` | Windows ネイティブの chezmoi が配る。下記「Windows 側」 |
| 非公開データ | `.chezmoiexternal.toml` → `~/.local/share/claude-private` | memory と機密スキル。private repo `haoblackj/claude-private` |

`.chezmoiignore` が OS ごとに配布対象を振り分ける（Windows では Linux 用のファイルとスクリプトを、Linux では Windows 用のファイルを除外）。

## 前提（chezmoi を動かす前に済ませること）

1. WSL2 に Ubuntu を入れ、Linux ユーザー名を `yagu001` にする。
   `dot_zshrc.tmpl`（`/home/yagu001/.deno/env`）と `bitwarden-ssh-agent.service`（`/mnt/c/Users/yagu001/...`）が絶対パスで参照している。
2. WSL の interop を有効のままにしておく。
   `.chezmoi.toml.tmpl` が `powershell.exe` を呼んで Windows 側ユーザー名を取り、`.gitconfig` と `.profile` に埋め込む。
3. Windows 側に Bitwarden Desktop を入れ、設定で SSH agent を有効にしてログインとアンロックを済ませる。
   `npiperelay.exe` を `C:\Users\yagu001\AppData\Local\Programs\npiperelay\npiperelay.exe` に置く。
   unit ファイルはこのパスを固定で持つので、Windows 側ユーザー名が `yagu001` でない機械ではそのままでは動かない。

`bitwarden-ssh-agent.service` が使う `socat` は `run_once_10` の基本 apt パッケージに含めてあるので手動導入は要らない。

## 導入手順

### 1. chezmoi を入れて init する（apply はまだしない）

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" init haoblackj
```

`--apply` を付けない理由は次の手順にある。

### 2. external を除いて apply する（run_once スクリプトが走る）

```sh
~/.local/bin/chezmoi apply --exclude=externals
```

sudo のパスワードは `run_once_10` の最初で 1 回だけ聞かれる。
`run_once_10` が `/etc/sudoers.d/00-chezmoi-bootstrap` に「このユーザーを NOPASSWD」のドロップインを置き、以降の run_once を無人化して、`run_once_99` の末尾で消す。
WSL2 の sudo（sudo-rs）は認証をプロセスの壁を越えて共有せず、run_once の各本が別々の子プロセスなので、`sudo -v` とバックグラウンドの延命ループでは無人化できない（Ubuntu 26.04 / sudo-rs 0.2.13 で実測）。ドロップインだけが子プロセスに効く。
apply が `run_once_99` に届く前に中断した場合はドロップインが残る。完走させれば 99 が消すが、ブートストラップ自体をやめるなら手で消す。

```sh
sudo rm -f /etc/sudoers.d/00-chezmoi-bootstrap
```

chezmoi はターゲットをパス順に処理するので、`.local/share/claude-private`（private repo の clone）が `10_*.sh` 以降のスクリプトより先に来る。
この clone は GitHub の認証情報を要求し、認証を担う `gh` は `run_once_80` で入り `run_once_85` でログインする。
認証が無いと clone に失敗し、chezmoi はそこで apply 全体を止める（この動作は実機で確認済み）。
そのため初回は external を外してスクリプトだけ先に走らせる。

途中で手を止める箇所は次の 2 つ。

- `sudo` のパスワード（`run_once_10` の冒頭で 1 回。上記のドロップインが以降を無人化する）
- `gh auth login -w`（`run_once_85`。ブラウザで device code を入力する）

`run_once_99` は `systemctl --user` を使う。
systemd が動いていない Ubuntu イメージではここで失敗するので、Windows 側から `wsl --shutdown` して入り直し、同じコマンドを再実行する（`run_once_10` が `/etc/wsl.conf` を `systemd=true` の設定へ symlink 済み）。
失敗した run_once スクリプトは記録に残らず次回の apply で再実行される（実機で確認済み）。

### 3. WSL を入れ直す

Windows 側で `wsl --shutdown` してから再度開く。
ログインシェルの zsh 化（`run_once_10` の `usermod -s`）と docker グループ（`run_once_70`）は、再ログインしないと効かない。
DNS は `run_once_10` が `wsl-static-dns.sh` を即実行して公開リゾルバに固定するのでブートストラップ中から効く（恒久化は `wsl-static-dns.service` と `wsl.conf` の `generateResolvConf=false`）。
再起動後のシェルは zsh が brew を読むので `gh` が PATH に載る。次の external clone がこれを要るので、順序として再起動を先に置く。

### 4. external を含めて apply する

```sh
chezmoi apply
```

`.chezmoiexternal.toml` の 2 つが clone される。

- `~/.claude/skills/book-to-skill`（公開スキル。upstream 追従。認証不要）
- `~/.local/share/claude-private`（memory と機密スキル）

private repo の clone は `.gitconfig` の credential helper 経由で `gh` を呼ぶ。
再起動前のブートストラップシェルは `gh`（brew 導入）が PATH に無く、helper が `gh: not found` で失敗して `Username for 'https://github.com':` を聞かれるので、必ず手順 3 の再起動を済ませてから行う（急ぐなら `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"` で `gh` を PATH に載せてから）。

### 5. 確認

```sh
systemctl --user status bitwarden-ssh-agent   # active なら socat ブリッジが立っている
ssh-add -l                                     # Bitwarden の鍵が並べば Windows 側まで通っている
~/.claude/hooks/claude-private-sync.sh pull    # claude-private を pull し memory/skills の symlink を張る（claude の SessionStart と同じ処理）
ls -la ~/.claude/projects/*/memory ~/.claude/skills
```

symlink の確認はこのフックを直接叩く。`claude` をホーム直下で起動すると、ホーム全体が 1 プロジェクト扱いになって `~/.claude/projects/` にホーム dir のエントリができるため、確認目的では開かない。実際に Claude Code を使うときは対象リポジトリへ `cd` してから起動する。

`ssh-add -l` が空のときは Windows 側の Bitwarden がロックされているか、SSH agent の設定が無効になっている。

## 自動で入るもの

一覧は各スクリプトが正で、ここには写さない。

| スクリプト | 中身 |
|---|---|
| `run_once_10_system-base` | 公開 DNS 固定（`wsl-static-dns`）、`/etc/wsl.conf` `/etc/fonts/local.conf` `/etc/default/keyboard` の symlink、zsh、apt の基本パッケージ、日本語ロケール |
| `run_once_11_system-upgrade` | `apt upgrade` |
| `run_once_20_wslu` | wslu（`xdg-open` で Windows のブラウザを開く）と GUI 系ライブラリ |
| `run_once_30_linuxbrew` | Homebrew |
| `run_once_40_python-env` | pyenv / pyenv-virtualenv とビルド依存 |
| `run_once_50_node-env` | nvm |
| `run_once_60_languages` | go / deno |
| `run_once_70_editors-containers` | neovim（AppImage）/ docker |
| `run_once_80_cli-tools` | **brew の Brewfile。CLI ツールの一覧はここを見る**（claude-code は `cask "claude-code@latest"`） |
| `run_once_82_npm-global` | nvm の LTS と npm グローバル（ccstatusline は pin、yarn、commitizen） |
| `run_once_83` / `84` / `86` | herdr の agent skill、プラグイン、Claude Code 統合 |
| `run_once_85_gh-setup` | `gh auth login` と gh 拡張 |
| `run_onchange_87_wikiwalk-tool` | `uv tool install` で wikiwalk。リモート HEAD が動くと再実行 |
| `run_onchange_after_90` | herdr の umask override を変えたら service を restart |
| `run_once_99_services` | `bitwarden-ssh-agent` の enable/start、`wsl-static-dns.service` と docker の enable |

ツールを足すときは該当スクリプトに 1 行足す。
run_once は内容のハッシュが変わると再実行されるが、既導入分はスキップされる作りになっている（`.claude/rules/run_once.md`）。

## 手動作業として残るもの

- `aicommit2 setup`（API キーの登録）
- Windows 側の Bitwarden Desktop と npiperelay（前提 3）
- `bw login`（bitwarden-cli は入るが、使うときにログインする）
- Cloudflare Workers AI のトークン失効時の再発行（下記「Memory Recall」）
- `setup_vall_e_x.sh`（VALL-E X。必要なときだけ手で実行する）
- このリポジトリを編集するなら `pre-commit install`（`.pre-commit-config.yaml` が shellcheck を pre-commit で、pytest と bats を pre-push で回す）

## Windows 側

Windows ネイティブの chezmoi で同じソースを apply すると、`%USERPROFILE%\.wslconfig`、komorebi / whkd / zebar / yasb / glazewm の設定、Windows Terminal の `settings.json`、scoop の alias が着地する。
`run_onchange_after_50_komorebi-fetch-asc.bat.tmpl` が komorebi の application-specific configuration を取得し、`run_once_after_55_komorebi-zebar-autostart.bat.tmpl` がスタートアップに komorebi（自宅機のみ）と zebar のショートカットを作る。
`.wslconfig` はホスト名が `HIRO-DESKTOP` で始まる機械でだけ `memory=48GB` を出す（経緯は `docs/superpowers/specs/2026-08-12-wslconfig-chezmoi-design.md`）。
`.wslconfig` は WSL2 の VM 起動時にしか読まれないので、変更後は `wsl --shutdown` が要る。

Windows 側の環境構築手順（scoop 本体や chezmoi の導入）は `haoblackj/_windows11-dotfiles` 側の README が持つ。

## Claude Code

### 公開と非公開の境界

`dot_claude/` に置くのは settings / hooks / keybindings / CLAUDE.md / rules / output-styles / agents だけ。
memory と機密スキル（自作改変分を含む）は private repo `claude-private` に置き、`~/.local/share/claude-private` へ clone したものを hook が `~/.claude/` へ symlink する。
`book-to-skill` だけは公開スキルなので git external で upstream から直接 clone する。

同期は `dot_claude/hooks/executable_claude-private-sync.sh` が担う。

| タイミング | 動作 |
|---|---|
| SessionStart | `git pull --ff-only` と symlink の確認 |
| Stop | 新しく生えた実ディレクトリの memory / skills を private repo へ移して commit と push（自動コミットの対象は memory 配下のみ） |

他マシンの memory やスキルを取り込む手順、マージ衝突の解消手順は `docs/claude-code.md`。

### ソースとターゲットの往復

`dot_claude/` 配下を Claude Code の Write/Edit で編集すると、PostToolUse hook `chezmoi-auto-apply.sh` が `chezmoi apply ~/.claude/` を走らせる。
逆に `~/.claude/` 側の管理ファイルを直接編集すると、同じ hook が `chezmoi re-add` を促す。
`/config` で選んだ一時的な model 等はソース側の値で上書きされるので、避けたいときは Bash から編集して `chezmoi apply ~/.claude/hooks` のように範囲を絞る。

### StatusLine

`dot_claude/private_settings.json` の `statusLine.command` は `bash ~/.claude/hooks/statusline-context-window.sh`。
このラッパーが context window の使用率をマーカーファイルへ書いてから、入力 JSON をそのまま `ccstatusline` へ流す。
表示内容は `dot_config/ccstatusline/settings.json` と同ディレクトリのスクリプト群。
`ccstatusline` 自体は `run_once_82` で pin 導入しており、バージョンを上げるときは pin を書き換えると `chezmoi apply` で再導入される。

### Memory Recall

発言のたびに `UserPromptSubmit` hook `dot_claude/hooks/memory_recall.py` が Cloudflare Workers AI（`@cf/baai/bge-m3`）で発言を埋め込み、プロジェクトの auto-memory 全ファイルの埋め込みキャッシュと内積比較して、類似度 0.55 以上の上位 3 件を「パスと一行説明」でコンテキストへ注入する。
`MEMORY.md` の行数制限で索引に載らないメモリも想起させるのが目的。
常駐プロセスなし、Python 標準ライブラリのみ、失敗時は注入なしの exit 0 で縮退する。

- secrets: `~/.local/share/claude-private/secrets/cloudflare-workers-ai-token`（`CF_ACCOUNT_ID` / `CF_API_TOKEN` の 2 行、chmod 600。claude-private の clone で届く）
- 埋め込みキャッシュ: 各 memory ディレクトリ直下の `.embeddings.json`（破損時は自動再生成）
- ログ: `~/.claude/logs/memory-recall.log`（5MB で truncate）
- テスト: `dot_claude/hooks/tests/test_memory_recall.py`
- 設計と較正手順: penguinEx の `docs/superpowers/specs/2026-07-18-memory-semantic-recall-design.md` と `docs/superpowers/plans/2026-07-19-memory-semantic-recall.md`

トークンを再発行するときは Cloudflare ダッシュボードのカスタムトークン（権限: アカウント / Workers AI / 編集）で作り直し、上記の secrets ファイルを更新する。

動作確認:

```zsh
echo '{"prompt": "背が高い人に合う家具を探したい"}' | \
  MEMORY_RECALL_DIR=$HOME/.claude/projects/-home-yagu001-repo-github-com-haoblackj-penguinEx/memory \
  python3 ~/.claude/hooks/memory_recall.py
```

1 件注入されれば動いている。空なら `memory-recall.log` を見る。

## herdr

`run_once_80`（本体）、`run_once_83`（agent skill）、`run_once_84`（プラグイン: reviewr、herdr-plus、command-palette、equalize-splits、file-viewer、hunk、ローカルの open-project）、`run_once_86`（Claude Code 統合 hook）で自動導入される。
キーバインドは `dot_config/herdr/config.toml` の `[[keys.command]]`（`prefix+a` でコマンドパレット、`prefix+s` / `prefix+d` で分割して Claude Code 起動など）。

チートシート:

- 恒久コピー: [`docs/herdr-cheatsheet.html`](docs/herdr-cheatsheet.html)（ブラウザで直接開ける単体 HTML）
- ライブ版（検索 UI 付き）: https://claude.ai/code/artifact/d13eca3b-71cc-40e5-a62b-1b897aa6c4c9（claude.ai Artifact。長期保持を保証する公式記述は未確認）

## このリポジトリを直すとき

- ホーム側を編集したら `chezmoi re-add <file>` でソースへ取り込み、ソース側を編集したら `chezmoi apply` で配る。zsh 起動時にドリフト検知が走り、どちらが要るかを案内する。
- run_once スクリプトの書き方は `.claude/rules/run_once.md`。
- hook の単体テストは bats（`dot_claude/hooks/*.bats`）、`memory_recall.py` は pytest。`pre-commit install` 後は shellcheck が pre-commit、テストが pre-push で回る。
- 作業中に見つけた無関係なバグは `ideas/bugs/` に書き置く（ホームへは配らない）。
