---
title: Google Antigravity の CLI を WSL に入れて Orca から使えるようにする
status: done
---

## 目的

Google Antigravity を入れて、Orca から使えるようにする。
出典: 端末からの入力（会話 ce9d2e89、2026-11-28 17:37、発言 be26aaa2）。
要旨（Claude の要約）: Antigravity を入れ、Orca から起動できるようにしてほしい。

## いまの方針

Orca が起動する Antigravity は CLI の `agy` なので、WSL の `~/.local/bin/agy` に公式のインストーラーで入れる。
インストーラーがシェルの設定ファイルへ足す PATH の行は、chezmoi の状態へ戻して持たない（`~/.profile` が `~/.local/bin` を PATH に入れている）。
他のマシンへの自動の導入（`run_once` のスクリプト）は作っていない。

## 判明した事実

- Orca（アプリ 1.4.266、ランタイム `0.1.0+e52a56a3b079`）は Antigravity をエージェント `antigravity` として最初から持つ。ターミナルでは `agy` を、チャットでは `agy acp` を起動し、Linux では `~/.local/bin` を探す（根拠: `~/.orca-remote/orcad-0.1.0+e52a56a3b079/orcad-server.js` の定義）。
- 入れる前は、Orca のプローブが `agy_acp_server.par` を起動できず `ENOENT` で失敗していた（根拠: `~/.orca/logs/orcad.trace.ndjson.3`）。
- 公式の入れ方は `curl -fsSL https://antigravity.google/cli/install.sh | bash`。manifest の SHA512 を確かめて `~/.local/bin/agy` に置き、最後に `agy install` を走らせる（根拠: https://antigravity.google/docs/cli/install と、取ってきたスクリプトの中身）。
- `agy install` は `~/.zshrc`、`~/.zprofile`、`~/.bash_profile`、`~/.bashrc`、`~/.profile` の末尾に `# Added by Antigravity CLI installer` と `export PATH="$HOME/.local/bin:$PATH"` を足す。5 つとも chezmoi の管理下のファイル（根拠: `chezmoi cat` との diff）。
- 入った版は 1.5.19。`agy` は実行中にバックグラウンドで自分を更新する（インストーラーの表示）。Orca はチャットの起動では `AGY_CLI_DISABLE_AUTO_UPDATE=true` を渡す。
- ダウンロードしたスクリプトを Claude Code から走らせる操作は、auto mode の判定に 2 回止められた。インストールはリーダーが `!` で打った。
- `!` で打つコマンドは入力を受け付けないので、`agy` の Google OAuth の認可コードを貼れない。Orca のターミナルで `agy` を立てると、その画面でログインできる。
- 認証は `agy` の画面の「1. Google OAuth」で、Windows の既定のブラウザ（Chrome）が開く。

## 判断の経緯

### 2026-11-28 採用: インストーラーが足した PATH の行をシェルの設定ファイルから外す

- 出どころ: Claude の判断
- 理由: 5 つのファイルの差分は足された 2 行だけで、`~/.profile` がもとから `~/.local/bin` を PATH に入れている。`~/.zprofile` は `~/.profile` を読む。外したあと、空の環境から立てたログインシェル（zsh と bash）で `agy` が見つかることを確かめた。外す前の 5 つのファイルは `~/.cache/agy-install-rc-backup-20261128/` に控えた。
- 状態: 有効

### 2026-11-28 採用: ログインは Orca のターミナルに立てた `agy` で行う

- 出どころ: Claude の判断
- 理由: `!` では認可コードを貼れない。`orca agent launch --agent antigravity --surface terminal` で立てれば、Orca からの起動の確かめも兼ねる。
- 状態: 有効

## いまの作業

なし（済み）。

## 済んだこと

- `agy` 1.5.19 を `~/.local/bin/agy` に入れた。
- シェルの設定ファイル 5 つを `chezmoi apply --force` で chezmoi の状態に戻した。
- Orca のターミナルで `agy` を立て、Google OAuth でログインした。
- `agy -p "Reply with just: ok"` が `ok` を返した。
- `orca agent launch --agent antigravity --surface terminal` で Orca のタブに `agy` が立ち、ログイン後の画面が出た。
- `orca agent launch --agent antigravity --surface chat --prompt ...` でチャットが立ち、`orca agent read` で応答 `ok` を読めた。
- `orca agent installed` の一覧に `antigravity` が出る。

## 残っていること

- 他のマシンで同じにするなら、公式のインストーラーを打ってから、シェルの設定ファイルを `chezmoi apply` で戻し、Orca のターミナルでログインする（自動化はしていない）。

## 次に Claude がすること

- なし。

## リーダーに決めてほしいこと

- なし

## 参照

- https://antigravity.google/docs/cli/install
