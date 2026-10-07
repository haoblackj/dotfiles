# Claude Code のトランスクリプトの退避と復元

Claude Code のトランスクリプトを、WSL の初期化に巻き込まれない D ドライブへ 1 時間ごとに退避している。
WSL を入れ直したら、この手順で元の場所へ戻すと `claude --resume` で過去のセッションを再開できる。
経緯と決定は haoblackj/dotfiles#42。

## 仕組み

| 項目 | 中身 |
|---|---|
| 退避するもの | `~/.claude/projects`（resume が読む jsonl と `subagents/`、`tool-results/`）、`~/.claude/file-history`（rewind）、`~/.claude/history.jsonl`（上矢印の履歴） |
| 退避先 | `D:\claude-transcripts-backup\restic`（restic のリポジトリ。暗号化済み） |
| パスワード | `~/.local/share/claude-private/secrets/restic-claude-transcripts`（claude-private の clone で届く） |
| 設定 | `~/.config/resticprofile/profiles.yaml`（ソースは `dot_config/resticprofile/profiles.yaml.tmpl`） |
| スケジュール | resticprofile が生成する systemd --user のタイマー。backup は毎時、forget と prune は毎週 |
| 世代 | 1 時間ごと 48、1 日ごと 30、1 週ごと 52、月ごとは無期限 |

タイマーの登録は `run_onchange_after_88_claude-transcripts-backup.sh.tmpl` が `chezmoi apply` のときに行う。
WSL が止まっている間はタイマーも止まるので、退避されるのは WSL が動いている時間帯だけになる。

## 状態を見る

```sh
systemctl --user list-timers 'resticprofile-*'
resticprofile -n claude-transcripts snapshots
journalctl --user -u 'resticprofile-backup@profile-claude-transcripts' -n 50
```

## WSL を入れ直した後の復元

前提は、README の導入手順をすべて済ませていること（claude-private が clone され、restic と resticprofile が入っている）。
ユーザー名は前と同じにする。
resume は元と同じ絶対パスの jsonl しか見つけられず、スナップショットも `/home/<ユーザー名>/.claude/...` の絶対パスで記録されているため。

1. 復元が終わるまでタイマーを止める。
   chezmoi apply の時点でタイマーは動き始めていて、空に近い `~/.claude` を新しい世代として退避してしまうため。

   ```sh
   systemctl --user stop 'resticprofile-backup@profile-claude-transcripts.timer'
   ```

2. 戻す世代を選ぶ。
   初期化の後に取られた世代は中身が空に近いので、初期化より前の時刻の最新を選ぶ。

   ```sh
   resticprofile -n claude-transcripts snapshots
   ```

3. 元の絶対パスへ戻す。
   restic は更新時刻も戻すので、`--resume` の一覧の並び（更新時刻順）も元どおりになる。

   ```sh
   resticprofile -n claude-transcripts restore <スナップショットID> --target /
   ```

4. タイマーを動かし直す。

   ```sh
   systemctl --user start 'resticprofile-backup@profile-claude-transcripts.timer'
   ```

5. 対象のリポジトリへ `cd` してから `claude --resume` を開き、過去のセッションが並ぶことを確かめる。

## 本番を上書きしない復元の演習

本物の `~/.claude` に触れずに、退避が使えることを確かめる手順。

```sh
work=$(mktemp -d)
resticprofile -n claude-transcripts restore latest --target "$work"
# 中身の照合。退避の後に追記されたファイルだけが差分に出る
diff -rq "$work$HOME/.claude/projects" "$HOME/.claude/projects" | head
```

resume まで確かめるときは、`CLAUDE_CONFIG_DIR` を復元先へ向けて、元のセッションと同じディレクトリで起動する。
追記は復元先の jsonl へ入り、本番の jsonl と本番のフックには触れない。
認証情報の読み先も復元先に変わるので、起動したらログインし直す。

```sh
cd <元のセッションの作業ディレクトリ>
CLAUDE_CONFIG_DIR="$work$HOME/.claude" claude --resume
```

## トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| backup が `password-file` を読めずに失敗する | claude-private がまだ clone されていない。README の手順 4 を済ませれば、次の回から通る |
| `/mnt/d` が無いと出て、タイマーが登録されない | D ドライブの無いマシン。登録スクリプトは何もせずに終わる |
| `repository is already locked` | 前の回が長引いているか、途中で止まった。backup は 15 分、forget は 1 時間ロックの解放を待つ。止まった回の古いロックは `resticprofile -n claude-transcripts unlock` で外す |
| resume で「No conversation found」 | 復元先のパスかユーザー名が元と違う。`ls ~/.claude/projects` のディレクトリ名（作業ディレクトリの絶対パスの記号をハイフンにしたもの）が今の作業ディレクトリと一致しているかを見る |
| 一つのセッションだけ resume できない | 書き込みの途中で退避された jsonl のことがある。手順 2 で一つ前の世代を選び、そのファイルだけ `--include` で戻す |
| 容量が膨らんだ | `resticprofile -n claude-transcripts stats --mode raw-data` で実サイズを見る。世代を減らすなら設定の `forget` を変えて `chezmoi apply` する |
