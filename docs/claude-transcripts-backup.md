# Claude Code のトランスクリプトの退避と復元

Claude Code のトランスクリプトを、WSL の初期化に巻き込まれない D ドライブへ 1 時間ごとに退避している。
WSL を入れ直したら、README の導入手順の `chezmoi apply` が元の場所へ自動で戻し、戻し終わってから退避を再開する。
戻した後は `claude --resume` で過去のセッションを再開できる。
経緯と決定は haoblackj/dotfiles#42、フェイルセーフは #45。

## 仕組み

| 項目 | 中身 |
|---|---|
| 退避するもの | `~/.claude/projects`（resume が読む jsonl と `subagents/`、`tool-results/`）、`~/.claude/file-history`（rewind）、`~/.claude/history.jsonl`（上矢印の履歴） |
| 退避先 | `D:\claude-transcripts-backup\restic`（restic のリポジトリ。暗号化済み） |
| パスワード | `~/.local/share/claude-private/secrets/restic-claude-transcripts`（claude-private の clone で届く） |
| 設定 | `~/.config/resticprofile/profiles.yaml`（ソースは `dot_config/resticprofile/profiles.yaml.tmpl`） |
| スケジュール | resticprofile が生成する systemd --user のタイマー。backup は毎時、forget と prune は毎週月曜 0 時、中身の検査（`restic check --read-data-subset 5%`）は毎週木曜 12 時 |
| 世代 | 1 時間ごと 48、1 日ごと 30、1 週ごと 52、月ごとは無期限 |
| 見張り | `~/.local/bin/claude-transcripts-backup-guard`。resticprofile の run-before と run-after から呼ばれるほか、ユニットが失敗したら `OnFailure=` の `claude-transcripts-backup-failed@.service` から呼ばれる |
| 状態 | `~/.local/state/claude-transcripts-backup/` の `failure-env`、`failure-backup`、`failure-check`、`failure-forget`（原因ごとの失敗の理由）、`last-success`、`restored`（このマシンで復元済みの印） |
| 配る先 | ホスト名が `HIRO-DESKTOP` で始まるマシンだけ（`.chezmoiignore`）。ステータスラインの枠だけは全マシンに配り、タイマーが無ければ何も出さない |

`chezmoi apply` のときに走るスクリプトは 2 つある。

- `run_onchange_after_88_claude-transcripts-backup.sh.tmpl` が、設定が変わったときにタイマーを作り直して動かす。D ドライブの無いマシンでは何もしない。
- `run_after_89_claude-transcripts-restore.sh` が、apply のたびに「未復元でパスワードが届いている」かを見て、そうなら backup を一回走らせる。

WSL が止まっている間はタイマーも止まるので、退避されるのは WSL が動いている時間帯だけになる。

## 毎回の backup の前に確かめること

guard は backup、forget、check の前に次を確かめ、欠けていれば退避をやめて失敗の理由を書く。

1. D ドライブに届くか。
2. 退避先に restic のリポジトリがあるか。無くても新しくは作らない。D が初期化されたときに、気づかないまま空から積み直さないため。
3. パスワードのファイルがあるか。

backup の前で、このマシンにまだ `restored` の印が無ければ、最新の世代を `--overwrite never` で戻してから印を付ける。
手元にすでにあるファイルは上書きしないので、戻す前に Claude Code を使っていても、その分は残る。

## 失敗の知らせ

Claude Code のステータスラインに、失敗している間だけ赤い字で出る。

| 表示 | 意味 |
|---|---|
| `⚠ 退避失敗: <理由>` | 直近の backup、forget、check のどれかが失敗した。理由は下のトラブルシューティング |
| `⚠ 退避が N 時間止まっている` | 最後の成功から 3 時間を超えた。タイマーが止まっている可能性がある |
| `⚠ 退避がまだ一度も成功していない` | タイマーを入れてから 3 時間を超えても、一度も成功していない |

失敗の理由は 3 か所で書く。

- run-before（guard の check）が、D、リポジトリ、パスワードの欠けと、復元の失敗を書く。
- run-after-fail が、restic 自体の失敗を終了コードつきで書く。
- 上の 2 つより手前で落ちた回（resticprofile が restic を起こせない等）は、systemd の `OnFailure=` が「ユニットが失敗」と書く。その回に上の 2 つが理由を書いていれば、そちらを残す。

失敗が複数あれば、環境、backup、check、forget の順に、原因に近いものを一つ出す。
それぞれの表示は、同じコマンドが次に成功すると消える。
check の失敗は週に一度しか試し直されないので、直したら手で `systemctl --user start resticprofile-check@profile-claude-transcripts.service` を走らせると早く消える。

止まっている判定は、WSL を起動してから 3 時間たつまでは出さない。止まっていた間の分で騒がないため。

## 状態を見る

```sh
systemctl --user list-timers 'resticprofile-*'
resticprofile -n claude-transcripts snapshots
journalctl --user -u 'resticprofile-backup@profile-claude-transcripts' -n 50
head ~/.local/state/claude-transcripts-backup/failure-*
```

`systemctl --user start` は、退避が終わる前に戻る（生成されるユニットは `Type=notify`）。
手で走らせた結果は、`systemctl --user is-active` が `active` でなくなってから見る。

## WSL を入れ直した後の復元

README の導入手順をそのまま進めればよい。
claude-private が届く手順 4 の `chezmoi apply` で、`run_after_89` が backup を一回走らせ、その前に guard が最新の世代を戻す。

ユーザー名とリポジトリの置き場所は前と同じにする。
resume は元と同じ絶対パスの jsonl しか見つけられず、スナップショットも `/home/<ユーザー名>/.claude/...` の絶対パスで記録されているため。

戻ったことは次で確かめる。

```sh
ls ~/.local/state/claude-transcripts-backup/restored
journalctl --user -u 'resticprofile-backup@profile-claude-transcripts' -n 50
```

最後に、対象のリポジトリへ `cd` してから `claude --resume` を開き、過去のセッションが並ぶことを確かめる。
resume に要るのはトランスクリプトとログインと作業ディレクトリだけで、`~/.claude.json` は要らない（2026-10-07 に確認）。

### 古い世代から戻したいとき

自動の復元は最新の世代しか戻さない。
壊れた jsonl を一つ前の世代から戻すときなどは、手で戻す。

```sh
systemctl --user stop 'resticprofile-backup@profile-claude-transcripts.timer'
resticprofile -n claude-transcripts snapshots
resticprofile -n claude-transcripts restore <スナップショットID> --target / --include <戻すファイルの絶対パス>
systemctl --user start 'resticprofile-backup@profile-claude-transcripts.timer'
```

`--include` を外すと世代全体を戻す。
`--overwrite` を指定しないと手元のファイルを上書きする（restic の既定は `always`）。

## パスワードの控え

パスワードの正本は claude-private の `secrets/restic-claude-transcripts` にある。
GitHub に入れなくなったときのために、Bitwarden の保管庫にも同じ値を「claude-transcripts restic password」という名前で置いている。
これが無いと D の退避は読めない。

claude-private が使えないときは、Bitwarden から書き戻す。

```sh
export BW_SESSION=$(bw unlock --raw)
mkdir -p ~/.local/share/claude-private/secrets
(umask 077; bw get password 'claude-transcripts restic password' > ~/.local/share/claude-private/secrets/restic-claude-transcripts)
```

パスワードを変えるとき（`restic key passwd`）は、claude-private と Bitwarden の両方を更新する。

## 本番を上書きしない復元の演習

本物の `~/.claude` に触れずに、退避が使えることを確かめる手順。

```sh
work=$(mktemp -d)
resticprofile -n claude-transcripts restore latest --target "$work"
# 中身の照合。退避の後に追記されたファイルだけが差分に出る
diff -rq "$work$HOME/.claude/projects" "$HOME/.claude/projects" | head
```

resume まで確かめるときは、復元先の `memory` の symlink を外してから、`CLAUDE_CONFIG_DIR` を復元先へ向けて、元のセッションと同じディレクトリで起動する。
symlink は本物の claude-private を指しているので、外さないとテストのセッションが本物の memory へ書きうる。
追記は復元先の jsonl へ入り、本番の jsonl と本番のフックには触れない。
認証情報の読み先も復元先に変わるので、起動したらログインし直す。

```sh
find "$work" -type l -name memory -exec trash-put {} +
cd <元のセッションの作業ディレクトリ>
CLAUDE_CONFIG_DIR="$work$HOME/.claude" claude --resume
```

## トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `D ドライブに届かない` | D が外れているか、Windows 側で見えていない。D が戻れば次の回から通る |
| `退避先のリポジトリが無い` | D が初期化されたか、`D:\claude-transcripts-backup\restic` が消えた。PC のバックアップから戻すか、空から始めるなら `resticprofile -n claude-transcripts init` を打つ |
| `パスワードが無い` | claude-private がまだ clone されていない。README の手順 4 を済ませる。claude-private が使えないときは、Bitwarden の控え（下の「パスワードの控え」）から戻す |
| `スナップショットを読めない` | パスワードがリポジトリと合っていないか、リポジトリが壊れている。`resticprofile -n claude-transcripts check` で確かめる |
| `復元に失敗` | journal で restic の出力を見る。直したら `systemctl --user start resticprofile-backup@profile-claude-transcripts.service` で試し直す |
| `restic backup が失敗（終了コード N）` | journal で restic の出力を見る。`repository is already locked` なら、止まった回の古いロックを `resticprofile -n claude-transcripts unlock` で外す |
| `restic check が失敗（終了コード N）` | リポジトリが壊れている可能性がある。`journalctl --user -u 'resticprofile-check@profile-claude-transcripts'` で中身を見て、`resticprofile -n claude-transcripts check --read-data` で全体を読む。壊れていれば restic の公式の手順（`restic repair`）に従う |
| `<コマンド> のユニットが失敗（journalctl で確認）` | フックより手前で落ちた。`journalctl --user -u 'resticprofile-<コマンド>@profile-claude-transcripts'` の最後を見る。restic が見つからない、設定が読めない、などがここに来る |
| `退避が N 時間止まっている` | `systemctl --user list-timers 'resticprofile-*'` にタイマーが無ければ `chezmoi apply` で作り直す |
| resume で「No conversation found」 | 復元先のパスかユーザー名が元と違う。`ls ~/.claude/projects` のディレクトリ名（作業ディレクトリの絶対パスの記号をハイフンにしたもの）が今の作業ディレクトリと一致しているかを見る |
| 一つのセッションだけ resume できない | 書き込みの途中で退避された jsonl のことがある。「古い世代から戻したいとき」の手順で、一つ前の世代からそのファイルだけ戻す |
| 容量が膨らんだ | `resticprofile -n claude-transcripts stats --mode raw-data` で実サイズを見る。世代を減らすなら設定の `forget` を変えて `chezmoi apply` する |
