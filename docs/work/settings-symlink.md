---
title: ~/.claude/settings.json の symlink が通常のファイルに置き換わった原因の調査と直し方
status: waiting
---

## 目的

`~/.claude/settings.json` は、README と CLAUDE.md の前提では `dot_claude/symlink_settings.json.tmpl` が作る、ソースの `linked/claude/settings.json` への symlink のはず。
ところが通常のファイルになっていて、ソースと内容がずれていた。
いつ、何が置き換えたのかと、ソースとの違いが何かを調べ、直し方の案を作って、直す前にリーダーの判断を仰ぐ。

- 依頼の出典: 端末からの入力（会話 3c33ee18、2026-11-21 02:33、発言 12f754d5）
- 要旨（Claude の要約）: Orca を入れた時点でそうなったのかもしれないので、別のセッションで確かめてほしい。
- 依頼の条件（同じ会話から渡された指示文による）: 本番の作業コピー（`~/.local/share/chezmoi`、別の作業の承認待ちのブランチで、コミットされていない変更がある）には書かない。`chezmoi apply` と `chezmoi re-add` を走らせない。`~/.claude/settings.json` も書き換えない。

## いまの方針

調べるだけで、どのファイルも書き換えていない。
原因は突き止めた（「判明した事実」）。
直し方の案を「リーダーに決めてほしいこと」に置き、答えを待つ。

## 判明した事実

### 時系列（2026-11-21、JST）

| 時刻 | 起きたこと | 根拠 |
|---|---|---|
| 01:02:49.364 | Orca が WSL 側に `~/.orca/agent-hooks/claude-hook.sh` を作る | `stat` の作成時刻 |
| 01:02:49.368 | WSL 側の Orca（orcad）が Claude 用のフックを settings.json に足す。symlink をたどってソースの `linked/claude/settings.json` に書き、元の中身を `linked/claude/settings.json.bak` に残す | ソースの `stat`（作成と更新が 01:02:49.368）、`.bak` の作成時刻が同じで、`.bak` の中身はコミット済みの HEAD と一致 |
| 01:03:06.238 | 何かがソースを読む | ソースの atime |
| 01:03:06.255 | `~/.claude/settings.json` が、ソースとほぼ同じ中身の新しい通常のファイルに置き換わる。ここで symlink が消えた | 02:32 の編集の直前に別のセッションが `cp -p` で取った複製の mtime |
| 01:03:06.278 | Windows 側の Orca のアプリが WSL へつなぐ中継の置き場 `~/.orca-relay` を作る | `find -printf %T` |
| 02:32:46 | 別のセッションが、リーダーの許可を受けて `env.CLAUDE_CODE_ENABLE_TODO_TOOLS` を一行足す（Edit の道具で書いたので、ファイルが作り直されて作成時刻もこの時刻になった） | その会話の記録と `stat` |

`~/.claude/` に `settings.json.bak` は無い。
01:03:06 の書き手は、置き換える前の中身を残さない書き方をしている。

### 置き換えた書き手（Orca 0.1.0+e52a56a3b079 の配布物のコードを読んで確かめた）

Orca には Claude Code のフックを入れる経路が二つある。

1. WSL 側の orcad が手元の設定に入れる経路（`install`）。書き込みの関数は、対象が symlink なら `realpath` で実体を求め、実体の隣に一時ファイルを作って実体へ rename し、実体の `.bak` を残す。symlink は壊れない。01:02:49 の書き込みがこれで、PermissionRequest のフックの timeout を 130 にする（非 Windows の既定）。
2. Windows 側のアプリが、リモート（WSL も含む）の設定に入れる経路（`installRemote`）。SFTP 相当の接続で、`~/.claude/settings.json` の隣に一時ファイルを書き、そのパスへ rename する。symlink をたどらず、`.bak` も残さない。PermissionRequest のフックの timeout は既定の 10 になる。この経路は、アプリが Windows で動き、リモートのフックが有効なときに走る。

01:03:06 の書き込みは、二つ目の経路の特徴（symlink の置き換え、`.bak` が無い、timeout が 10、中継の置き場の作成と同じ瞬間）にすべて合う。
Windows 側のアプリのログは、WSL と Windows の境界の決まりで読んでいない。
そのため「その瞬間に `installRemote` が呼ばれた」ことは、ログでは確かめていない（時刻とコードの一致による推定）。

### ソースとの違い

いまの `~/.claude/settings.json` とソースの作業コピーの違いは二つだけ。

- 18 行目: `env.CLAUDE_CODE_ENABLE_TODO_TOOLS: "1"`。02:32 にリーダーの許可で足したもの（同じ一行は PR #99 に入っている）。
- 404 行目あたり: Orca が入れた PermissionRequest のフックの `timeout`。ソースは 130（WSL 側の経路が書いた値）、`~/.claude/settings.json` は 10（Windows 側の経路が書いた値）。フックのコマンド自体は同じ。

新しいのは `~/.claude/settings.json` のほう（01:03:06 と 02:32 の書き込みがソースに届いていない）。
ソースの作業コピーには、Orca が足したフック（171 行）がコミットされずに載っている。

### 今後も起きうること

Windows 側の書き込みは、中身が同じなら書かない作り。
ただ、WSL 側は timeout 130、Windows 側は 10 を正とするので、両方が既存のフックを書き直す作りなら、Orca を起動するたびに交互に書き換え、symlink を戻しても Windows 側の書き込みでまた壊れうる。
WSL 側が既存の timeout 10 のフックを書き直すかは、まだ確かめていない。

## 判断の経緯

### 2026-11-21 採用: 調べるだけにし、直す前にリーダーの判断を仰ぐ
- 出どころ: 端末からの入力（会話 3c33ee18、2026-11-21 02:33、発言 12f754d5）
- 要旨（Claude の要約）: Orca の導入のときに起きたのかもしれないので、別のセッションで確かめてほしい。
- 理由: 依頼が、直し方の案を記録に書いて、直す前に判断を仰ぐことを求めているため。
- 状態: 有効

### 2026-11-21 採用: Windows 側の Orca のログは読まない
- 出どころ: Claude の判断
- 理由: グローバルの CLAUDE.md の環境の境界の決まり（明示の指示なしに Windows 側の領域へ触らない）。WSL 側の時刻の一致とコードで、原因を絞れた。
- 状態: 有効

## いまの作業

リーダーの答え待ち。

## 済んだこと

- 原因の調査（上の「判明した事実」）。どのファイルも書き換えていない。

## 残っていること

- 直し方を決める（「リーダーに決めてほしいこと」）。
- 直す作業。ソースの作業コピーが別の作業の承認待ちのブランチにあるので、そちらが片付くまで、ソースへの取り込みと symlink の作り直しはできない。

## 次に Claude がすること

- リーダーが直し方を選んだら、その案で設計と計画を書き、試しの環境で Orca の再起動のあとも symlink が残るかを確かめてから、PR にする。

## リーダーに決めてほしいこと

- 直し方をどれにするか。答えで、symlink を続けるか、Orca の設定を変えるか、chezmoi の管理の形を変えるかが決まる。
  - 案 1（推奨）: Windows 側の Orca のアプリで、リモートへのフックの導入を切る。WSL 側の orcad の経路だけが残り、こちらは symlink をたどって書く。そのうえで symlink を戻し、Orca のフックをソースにコミットする。利点は原因そのものを断つこと。欠点は、Windows 側の画面の設定を変える操作になることと、切っても WSL で動く Claude Code の状態の表示が保たれるかを試して確かめる必要があること。
  - 案 2: symlink を戻し、Orca のフックを timeout 10 の形でソースにコミットして、Windows 側の書き込みが「中身が同じ」で止まるようにする。利点は Orca の設定に触れないこと。欠点は、WSL 側が 130 に書き直す作りなら交互の書き換えが続き、また壊れること（未確認）。
  - 案 3: symlink をやめ、`~/.claude/settings.json` を chezmoi の通常のファイルとして配る。利点は Orca の書き方に左右されないこと。欠点は、Claude Code と Orca が書き戻した中身がソースへ自動で届かなくなり、`chezmoi apply` のたびに上書きされること（README の往復の設計を作り直す必要がある）。
- 確かめを強めるために、Windows 側の Orca のアプリのログを読み取りだけで見てよいか。Claude の案: 見なくても直し方は決められる。見るなら案 1 の確かめのときに、01:03:06 の `installRemote` の呼び出しを確かめる。

## 参照

- 書き置き: ブランチ `feat/orca-from-herdr` の `ideas/bugs/2026-11-21-settings-json-not-symlink.md`
- symlink を作ったコミット: `f4aa14a`（2026-09-20、`dot_claude/symlink_settings.json.tmpl`）
- PR #99（`CLAUDE_CODE_ENABLE_TODO_TOOLS` の一行）
