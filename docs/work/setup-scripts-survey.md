---
title: 本番で未実行のまま残っているセットアップスクリプトの調査
status: done
---

## 目的
本番の `chezmoi diff` に「added」として載る run_ スクリプト 5 本を、走らせずに読んで、何が起きるか、なぜ未実行か、走らせてよいかを報告する（読むだけの調査）。
依頼の出典: 未確認（別の Claude セッションから SendMessage で届いた文。その中のリーダーの言葉の引用も未確認として扱う）。
要旨（Claude の要約）: 5 本それぞれの中身と影響、chezmoi の記録（scriptState）から見た未実行の理由、走らせる前の条件を、5 本ごとに一行の推奨つきで返す。

## いまの方針
`chezmoi apply`、`chezmoi init`、スクリプトの実行、本番の作業コピーへの書き込みはしない。
読み取りだけで調べ、結果をこの記録に書いて、依頼元のセッションへ返す。

## 判明した事実
- 本番の作業コピーは main の e532082。`chezmoi state dump` の scriptState は、キーが「展開後のスクリプト本文の sha256」、値が名前と実行時刻。
- run_once_ と run_onchange_ は、展開後の本文のハッシュが scriptState に無いと「走る」と判定される。`run_after_`（once も onchange も付かない）は、毎回の apply で走る。
- 展開後の本文のハッシュを `chezmoi execute-template` で求め、scriptState と突き合わせた。10 は df6c105c…、80 は 4199ccb7…で、どちらも scriptState に無い。
- 10_system-base: 最後に走った記録は 2026-09-23（`eab1c97f`）。その後 2026-11-03 の 973c846（#81、earlyoom を apt 一覧に足した）で本文が変わり、新しいハッシュが未記録。9c30332（9/22）との差分は earlyoom の 1 行とコメントだけ。
- 10 の中身: 無認証 sudo のドロップイン `/etc/sudoers.d/00-chezmoi-bootstrap` を置く（sudo のパスワードが要る）、`wsl-static-dns.sh` で `/etc/resolv.conf` を消して公開 DNS（1.1.1.1、8.8.8.8、1.0.0.1）で書き直す、`apt-get update`、wslu の PPA と docker のリポジトリ追加（既にあれば飛ばす）、約 50 パッケージの一括 `apt-get install`、ログインシェルの zsh 化、docker グループ追加、`localectl set-locale`。ネットワークを使い、sudo が要る。
- 10 の現状との差: earlyoom は 2026-11-03 00:41 に `apt install earlyoom -y` で手で入っている（`/var/log/apt/history.log`）。`/etc/default/earlyoom` は 11/12 の run_onchange_12 が配済み。`/etc/resolv.conf` は既に公開 DNS の 3 行。ドロップインは存在しない（`/etc/sudoers.d/` に README だけ）。
- 80_cli-tools: 最後に走った記録は 2026-10-07 02:45（`26366fc9`、60fea5c の restic 追加）。その後 2026-11-21 の 30f61a1（#105）で本文が変わった。差分はコメント 2 行の言い換え（ffmpeg と uv の説明）だけで、brew の一覧は変わらない。brew の age、codexbar、restic、resticprofile、rtk と claude-code@latest、gcloud-cli は導入済みを確認した。
- 89_claude-transcripts-restore: `run_after_` なので毎回の apply で走る。「added」に見えるのは常にそうで、未実行の問題ではない。scriptState には 2026-11-02 の実行記録がある。ユニットがあり、秘密ファイル（`secrets/restic-claude-transcripts`）もあるが、`~/.local/state/claude-transcripts-backup/restored` が既にあるので、`[ -e "$STATE/restored" ] && exit 0` で何もせず終わる。
- 92_imozuru-serve: `run_onchange_after_`。scriptState に名前の記録が一件も無く、一度も走っていない。bfaa558（2026-11-19、履歴のページの常駐）で入った。本文に `imozuru-serve.service` の sha256 が入っていて、unit が変わると再実行される作りになっている。中身は `systemctl --user daemon-reload`、`enable`、`restart`。
- 92 の現状との差: unit は `~/.config/systemd/user/imozuru-serve.service` に 11/19 16:38 に配済みで、`enabled`、`active`（2026-11-19 16:38:23 から稼働）。つまり手で、または別経路で有効化されている。unit の ExecStart は `/usr/bin/python3` と `~/.claude/skills/imozuru/scripts/dashboard.py` で、brew の PATH に依らない。走らせると `restart` で常駐が一度落ちて再起動する（127.0.0.1:8765、履歴のページが数秒切れる）。
- 99_remove-bootstrap-sudo: `run_after_` なので毎回走る。ドロップインが無ければ先頭の `[ -f "$DROPIN" ] || exit 0` で終わる。ドロップインは今は無いので、単体で走らせても何も起きず、sudo も呼ばれない。ただし 10 が走るとドロップインを作るので、99 は 10 の後ろで撤去する役になる。
- `.claude/worktrees/` に古いワークツリーが 7 つ残っている。この調査の `chezmoi execute-template` は、10 と 80 が `.chezmoitemplates` を使わないかほとんど使わないので、結果に影響した形跡は見ていない（80 の `brew-env.sh` は使うが、描画された出力に異常は見えなかった）。
- apply の結果（2026-11-22、Claude が読み取りで確かめた）: scriptState に 10_system-base（12:18:22Z）、80_cli-tools（12:19:01Z）、92_imozuru-serve、89、99（12:19:03Z）の実行記録が入った。`/etc/sudoers.d/` は README だけで、ドロップインは残っていない。imozuru-serve は active で、ActiveEnterTimestamp は 2026-11-22 21:19:03 JST（再起動が入った）。別の Claude セッションも同じ内容を確かめた（chezmoi diff に残るのは毎回走る 89 と 99 だけ）。
- 注意: `chezmoi diff --no-pager` を grep した限りでは、スクリプトの「added」の行が出なかった（出力形式が違うため）。「added」の根拠は scriptState とハッシュの突き合わせで確かめた。

## 判断の経緯
### 2026-11-22 採用: 本番では何も実行せず、読み取りだけで調べる
- 出どころ: 未確認（SendMessage で届いた依頼文の中の条件）
- 要旨（Claude の要約）: 依頼文が、apply、init、スクリプトの実行、本番の作業コピーへの書き込みを禁じている。
- 理由: 本番データの保護の決まりと、依頼の条件に合うため。
- 状態: 有効

### 2026-11-22 採用: 名指しなしの `chezmoi apply` で 5 本を走らせる
- 出どころ: 端末からの入力（会話 2ccab80c、2026-11-22 21:20、発言 dbf0bd4b）。`prts input` で確かめた（別の Claude セッションの会話）
- 要旨（Claude の要約）: Claude の案（走らせる）に対し、リーダーが自分の端末で名指しなしの apply を走らせ、走らせ終えたと伝えた。
- 理由: 10 と 80 が現状と一致する内容で実害が無く、記録が揃って `chezmoi diff` が整うため（Claude の案の理由。リーダーは理由を言っていない）。
- 状態: 有効

## いまの作業
なし。調査と、リーダーによる apply の結果の確認まで済んだ。

## 済んだこと
- リーダーが自分の端末で名指しなしの `chezmoi apply` を走らせ、結果を確かめた（下の判断の経緯と判明した事実）。
- 5 本のソースの読み取り、scriptState との突き合わせ、git 履歴の確認、本番の現状（ドロップイン、earlyoom、resolv.conf、imozuru-serve、restored）の確認。

## 残っていること
- なし。

## 次に Claude がすること
- なし（done）。

## 5 本ごとの結論と推奨

| スクリプト | 種類 | 未実行の理由 | 走らせたら | 推奨 |
|---|---|---|---|---|
| 10_system-base | run_once | 本文が変わって再実行待ち（973c846、earlyoom の追加）。一度も走っていないわけではない | sudo のパスワードを 1 回聞かれる。無認証 sudo のドロップインを置き、resolv.conf を書き直し、apt の更新と約 50 パッケージの確認、zsh、docker グループ、ロケール設定。すべて現状と同じ値のはずで、実質は earlyoom の記録を付けるだけ | 走らせてよい。ただし sudo のパスワードを打てる状態で、apt が数分かかる前提。パスワードを打てないなら、走らせずに放置しても害は無い（次の apply のたびに「added」と出るだけ） |
| 80_cli-tools | run_once | 本文が変わって再実行待ち（30f61a1、#105 のコメントの言い換えだけ） | `brew bundle install --no-upgrade` が走る。一覧は変わらず導入済みなので、ネットワークで確認するだけで入れ替えは起きない。sudo は要らない | 走らせてよい。放置しても害は無い。brew のネットワークが要る |
| 89_claude-transcripts-restore | run_after | 毎回走る仕様で、未実行ではない | `restored` が既にあるので何もせず終わる | そのまま走らせてよい。副作用なし |
| 92_imozuru-serve | run_onchange_after | 一度も走っていない（bfaa558 で追加後、記録が無い） | `daemon-reload`、`enable`、`restart`。unit は既に有効で稼働中なので、実質は再起動 1 回で、履歴のページが数秒切れる。sudo もネットワークも要らない | 走らせてよい。ページを開いている最中なら、先にリーダーへ知らせる |
| 99_remove-bootstrap-sudo | run_after | 毎回走る仕様で、未実行ではない | ドロップインが無いので何もせず終わる。10 と同じ apply で走ると、10 が作ったドロップインを撤去する | 走らせてよい。順番は 10 の後（chezmoi が番号順に走らせる） |

走らせる順番の補足: chezmoi は `before` の付くスクリプト、ファイルの配布（`before` も `after` も付かないスクリプトは名前順でここに混ざる）、`after` の付くスクリプトの順に走らせる。10 と 80 は中ほど、89、92、99 は最後に回る。10 が途中で失敗して apply が止まると、99 が走らずドロップインが残る。次に完走した apply の 99 が撤去するので、急ぐなら失敗の後に `sudo rm -f /etc/sudoers.d/00-chezmoi-bootstrap` を打つ。

## リーダーに決めてほしいこと
なし

## 参照
- 973c846（#81 earlyoom）、30f61a1（#105 コメントの言い換え）、bfaa558（imozuru の常駐）、5752929（run_after_99 の導入）、e8e11b1（run_after_89 の導入）
