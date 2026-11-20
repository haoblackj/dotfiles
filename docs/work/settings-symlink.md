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
- 続く依頼の出典: 端末からの入力（会話 86439d41、2026-11-21 02:51、発言 dcde8cf7）
- 要旨（Claude の要約）: 案 1 が本当にそう働くかを確かめる。案 1 をやるだけで済ませるのも放置するのも無しで、また symlink が外れたら知らせて直させる仕組みがほしい。

## いまの方針

symlink が外れている間、入力欄の上に赤い帯で出し続ける Mod（`skills/settings-symlink-guard/`）を作った。最初に作った SessionStart のフックの版は、リーダーの希望で Mod に置き換えた。
案 1 は、コードと実機の読み取りで「働く見込みが高い」ところまで確かめた（「判明した事実」の「案 1 の確かめ」）。
実際に Orca を動かして確かめる手順と、Mod を配る時期は、Windows 側の操作と本番の `~/.claude/settings.json` の書き換えを含むので、リーダーに仰ぐ。

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

### 案 1 の確かめ（コードと実機の読み取り）

- リモートへのフックの導入を切る手段は、Orca の画面の設定ではなく、Windows 側のアプリの環境変数 `ORCA_FEATURE_REMOTE_AGENT_HOOKS`。空か `0` で切れ、未設定なら有効（配布物のコードの判定）。前回の報告で「Windows 側の画面の設定」と書いたのは誤りだった。
- この変数は、Windows で動くアプリが WSL へフックのイベントを中継する仕組み（`~/.orca-relay` を作る側）を丸ごと止める。リモートへのフックの導入は、この中継を立てる流れの中で走る。
- この環境の WSL の Claude Code のフックは、中継を通らず、WSL の中の orcad へ直接送っている。pane の環境変数 `ORCA_AGENT_HOOK_ENDPOINT` は `~/.orca/agent-hooks/endpoint.env`（orcad が 01:02:47 に書いた）を指し、そこにある port（実測 45573）で待ち受けているのは orcad の node（pid 1310229）だった。`claude-hook.sh` はその port へ `curl` で送る。
- そのため、変数で中継を止めても、WSL の Claude Code の状態の表示は残る見込みが高い。WSL 側の orcad の導入（symlink をたどる書き方）は変数の影響を受けない。
- 実際に Orca を再起動して確かめてはいない。確かめるには、Windows 側でアプリの環境変数を設定して Orca を起動し直す操作が要る。

### 知らせる仕組み

- 最初の版は SessionStart のフック（コミット `a02ed0a`）。本物の `~/.claude/settings.json` に読み取りだけで走らせると「通常のファイルになっている」と出て、ファイルの inode と mtime は変わらなかった。審査では、`jq` が PATH に無いと黙って知らせないこと、`realpath` が失敗すると正しいと判断して黙ることを指摘された（設計の前提は崩さない、という答え）。
- いまの版は Mod（設計は `docs/superpowers/specs/2026-11-21-settings-symlink-guard-design.md`）。外れている間は入力欄の上（`AbovePrompt`）に帯を出し続け、外れたときにトーストを一度出し、Claude へ一節（`prompt.compose`）を足す。一分ごとに調べ直す。`$.fs.stat` で調べるので外のコマンドに頼らず、フックの版の二つの指摘は起きない。ソースが無いときは正しいと言わない。
- Mod の試験は 12 件（`claude plugin test`）が通り、`claude plugin validate` も通った（アイコンが無い警告だけ）。
- 配備は `bg-progress` と同じく、`dot_claude/skills/symlink_settings-symlink-guard.tmpl` で `~/.claude/skills/settings-symlink-guard` から `skills/settings-symlink-guard/` へ symlink を張る。`~/.claude/skills/bg-progress` がこの形で読み込まれていることを確かめた。
- このセッションで実際に帯が出るかを試すため、Mod をこのセッションの試し用の置き場（`~/.claude/dev-mods/<この会話>/`）に写した。

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

### 2026-11-21 採用: 案 1 を確かめ、symlink が外れたら知らせる仕組みを作る
- 出どころ: 端末からの入力（会話 86439d41、2026-11-21 02:51、発言 dcde8cf7）
- 要旨（Claude の要約）: 案 1 が本当にそう働くかを確かめつつ、案 1 だけで済ませるのも放置するのも無しで、また外れたら知らせて直させる仕組みがほしい。
- 理由: 理由の提示なし（Claude の読み: 原因を断っても、Orca の更新などで再発しうるため）。
- 状態: 有効

### 2026-11-21 採用: 知らせる仕組みは Claude Code の SessionStart のフックにする
- 出どころ: Claude の判断
- 理由: Orca が書き換えるのはアプリの起動や接続のときで、その後に立てるセッションで必ず気づける。毎回 `lstat` 一回で費用がほぼ無い。画面（`systemMessage`）と Claude（`additionalContext`）の両方へ届く。systemd でファイルを見張る案は、WSL から Windows の画面へ通知を届ける道を新しく作る必要があり、常駐も増えるので採らない（設計書の「方式の比較」）。
- 状態: 置き換え済み（2026-11-21 変更: 知らせる仕組みを Mod の帯にする）

### 2026-11-21 変更: 知らせる仕組みを Mod の帯にする
- 置き換えたもの: 2026-11-21 採用: 知らせる仕組みは Claude Code の SessionStart のフックにする
- 出どころ: 端末からの入力（会話 86439d41、2026-11-21 02:57、発言 efa20ad4）
- 要旨（Claude の要約）: Mod にできないか。画面に出しておいたほうが放置しにくい。
- 理由: SessionStart のフックの表示はセッションの開始時の一行だけで、流れて見えなくなる。Mod の帯なら外れている間ずっと出せる。審査で出たフックの版の欠点（`jq` が無いと黙る）も起きない。
- 状態: 有効

## いまの作業

このセッションで Mod を試し用に読み込ませ、帯が出るかを見ている（有効にするかの確認がリーダーに出る）。そのあとはリーダーの答え待ち（案 1 を実機で確かめる手順と、Mod を配る時期）。

## 済んだこと

- 原因の調査（上の「判明した事実」）。
- 案 1 のコードと実機の読み取りでの確かめ（「案 1 の確かめ」）。
- 知らせる仕組みの実装と試験。SessionStart のフックの版（コミット `a02ed0a`）を、Mod の版に置き換えた。

## 残っていること

- 案 1 を実機で確かめる。
- このセッションで帯が出ることを確かめる。
- Mod を本番へ配る（`chezmoi apply` で `~/.claude/skills/settings-symlink-guard` の symlink を張る）。
- symlink を戻し、Orca のフックと `CLAUDE_CODE_ENABLE_TODO_TOOLS` の一行をソースにコミットする。
- 既定ブランチへ取り込む前の審査（requesting-code-review）と PR。
- 上の三つの本番の操作は、ソースの作業コピーが別の作業の承認待ちのブランチにあるあいだはできない。

## 次に Claude がすること

- このセッションで帯が出たかを確かめて記録する。
- Mod の版の審査を頼み（フックの版の審査は済んでいるが、作りが替わったので頼み直す）、PR にする。
- 別の作業のブランチが片付いたら、リーダーの答えの手順で、symlink を戻す、Mod を配る、Orca の環境変数を設定して再起動する、を一続きで行い、再起動の後に帯が出ていないこと、`~/.claude/settings.json` の inode が変わらないこと、Orca の画面で WSL の Claude Code の状態が出ることを確かめる。

## リーダーに決めてほしいこと

- 案 1 を実機で確かめる手順。答えで、Windows 側を誰がどう操作するかと、本番の `~/.claude/settings.json` を書き換える時期が決まる。
  - Claude の案（推奨）: 別の作業のブランチが片付いたあとに一続きで行う。(1) Claude がソースに Orca のフックと `CLAUDE_CODE_ENABLE_TODO_TOOLS` の一行を取り込み、`~/.claude/settings.json` を symlink に戻し、Mod を配る。(2) リーダーが Windows 側で、Orca のアプリが読むユーザーの環境変数 `ORCA_FEATURE_REMOTE_AGENT_HOOKS=0` を設定し、Orca を終了して起動し直す。(3) Claude が上の三点を確かめる。利点は、外れたら帯が出る状態で確かめられること。欠点は、別の作業のブランチが片付くまで待つこと。
  - 別案: 今すぐ (2) だけ行い、`~/.orca-relay` が作り直されないことと状態の表示が残ることだけを見る。利点は早いこと。欠点は、`~/.claude/settings.json` の中身がすでに Windows 側の望む形と同じなので、変数が無くても書き込みは起きず、symlink が守られるかは確かめられないこと。
- 確かめを強めるために、Windows 側の Orca のアプリのログを読み取りだけで見てよいか。Claude の案: 見なくても進められる。見るなら実機の確かめのときに、中継とリモートへの導入が走らなかったことをログでも確かめる。
- 取り下げ: 前回の「直し方をどれにするか」の問いは、案 1 を確かめる方向の答え（上の判断の経緯）で置き換えた。

## 参照

- 書き置き: ブランチ `feat/orca-from-herdr` の `ideas/bugs/2026-11-21-settings-json-not-symlink.md`
- symlink を作ったコミット: `f4aa14a`（2026-09-20、`dot_claude/symlink_settings.json.tmpl`）
- PR #99（`CLAUDE_CODE_ENABLE_TODO_TOOLS` の一行）
