# settings.json の symlink が外れたら画面に出し続ける Mod（設計）

作業記録: `docs/work/settings-symlink.md`

## 目的

`~/.claude/settings.json` は、ソースの `linked/claude/settings.json` への symlink であることを前提にしている（Claude Code と Orca が書き戻した中身がそのままソースへ届く）。
2026-11-21 に Orca の Windows 側のアプリがこの symlink を通常のファイルで置き換え、気づかないまま書き戻しがソースへ届かなくなった。
Orca の設定を変えて原因を断っても、Orca の更新や別の道具で同じことが起きうる。
外れたら、直すまで画面に出し続けてリーダーが放置しにくくし、Claude が直す作業に入れるようにする。

## 要件

- 外れている間は、入力欄の上に出し続ける（リーダーの希望。一度だけの表示は流れて放置されやすい）。
- 外れた瞬間にも気づけるよう、トーストを一度出す。セッションの途中で外れても、一分以内に気づく。
- Claude にも、状況と直し方の入口（作業記録）を伝える。
- 正しいときは何も出さない。直ったら帯を消す。
- 調べるだけで、何も書き換えない（直すのはリーダーの判断を経てから）。
- クラウドのセッション（`CLAUDE_CODE_REMOTE=true`）では settings.json が symlink でないのが正しいので、黙る。

## 方式の比較

- 採用: Claude Code の Mod。`AbovePrompt` の帯で出し続け、`prompt.compose` で Claude へ一節を足す。`$.fs.stat` が symlink かどうかとたどった先を返すので、`jq` や `realpath` などの外のコマンドに頼らない。このリポジトリの `bg-progress` と同じく、`skills/<名前>/` に置いて `~/.claude/skills/` から読み込ませる。
- 置き換え済み: SessionStart のフック。最初はこれで作ったが、表示はセッションの開始時の一行だけで流れて見えなくなる。リーダーが画面に出し続ける形を望んだので Mod に替えた。審査では、`jq` が PATH に無いと黙って知らせない欠点も指摘された。
- 不採用: systemd の path unit でファイルを見張り、デスクトップへ通知する。WSL から Windows の画面へ通知を届ける道を新しく作る必要があり、常駐の仕組みも増える。
- 不採用: `chezmoi verify` や `chezmoi status` を回す。settings.json 以外の差も拾い、`chezmoi` の起動に 0.3 秒ほどかかる。

## 作り

- `skills/settings-symlink-guard/`（Mod の実体）と `dot_claude/skills/symlink_settings-symlink-guard.tmpl`（`~/.claude/skills/` からの symlink）。
- 調べる対象は `$HOME/.claude/settings.json`、正しいリンク先は `${CHEZMOI_SOURCE_DIR:-$HOME/.local/share/chezmoi}/linked/claude/settings.json`。
- 判定の順: ファイルが無い、通常のファイル、リンク先が無い symlink、比べるソースが無い、たどった先がソースと違う。どれでもなければ正しい。ソースが無いときに正しいと言わない（審査の指摘の、失敗が黙る側に倒れる問題を避ける）。
- `session.start` で一度調べ、以後 `$.clock.every` で一分ごとに調べる。状態は `$.state` の `broken`（状態の文か null）に置き、帯はそれを読んで描く。外れていない状態から外れた状態に変わったときだけトーストを出す。
- 試験は `claude plugin test` の `tests/register.test.tsx`（`fs.stat` と `env.get` をパスごとに偽の答えで返す）。

## 配備

ソースの作業コピーが別の作業のブランチにあるあいだは、`chezmoi apply` で `~/.claude/skills/` の symlink を張れない。
配備の手順と時期は作業記録に書き、リーダーの判断を仰ぐ。
