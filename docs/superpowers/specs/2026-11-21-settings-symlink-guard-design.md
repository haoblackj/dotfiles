# settings.json の symlink が壊れたら知らせる仕組み（設計）

作業記録: `docs/work/settings-symlink.md`

## 目的

`~/.claude/settings.json` は、ソースの `linked/claude/settings.json` への symlink であることを前提にしている（Claude Code と Orca が書き戻した中身がそのままソースへ届く）。
2026-11-21 に Orca の Windows 側のアプリがこの symlink を通常のファイルで置き換え、気づかないまま書き戻しがソースへ届かなくなった。
Orca の設定を変えて原因を断っても、Orca の更新や別の道具で同じことが起きうる。
壊れたらリーダーに知らせ、Claude が直す作業に入れるようにする。

## 要件

- 壊れたことを、リーダーが次に Claude Code を使う時点で知らせる。
- 知らせは画面に出し、Claude にも状況と直し方の入口（作業記録）を渡す。
- 壊れていないときは何も出さない。
- 検出するだけで、何も書き換えない（直すのはリーダーの判断を経てから）。
- クラウドのセッション（`CLAUDE_CODE_REMOTE=true`）では settings.json が symlink でないのが正しいので、黙る。

## 方式の比較

- 採用: Claude Code の SessionStart のフック。新しいセッション、再開、`/clear`、圧縮のたびに `lstat` を一回するだけで、費用はほぼ無い。Orca が書き換えるのはアプリの起動や接続のときで、その後に立てるセッションで必ず気づける。`systemMessage` で画面に出し、`additionalContext` で Claude に伝える。
- 不採用: systemd の path unit でファイルを見張り、デスクトップへ通知する。即時に気づけるが、WSL からリーダーの画面へ通知を届ける道（Windows のトースト）を新しく作る必要があり、常駐の仕組みも増える。気づくのがセッションの開始まで遅れても、困るのはソースとの差が広がることだけで、検出時に差を見れば戻せる。
- 不採用: `chezmoi verify` や `chezmoi status` を回す。settings.json 以外の差も拾い、`chezmoi` の起動に 0.3 秒ほどかかる。

## 作り

- `dot_claude/hooks/executable_settings-symlink-guard.sh`
  - 調べる対象は `~/.claude/settings.json`、正しいリンク先は `${CHEZMOI_SOURCE_DIR:-~/.local/share/chezmoi}/linked/claude/settings.json`。試験のために、それぞれ環境変数 `SETTINGS_SYMLINK_GUARD_TARGET`、`SETTINGS_SYMLINK_GUARD_EXPECTED` で差し替えられる。
  - 正しい symlink（`realpath` が正しいリンク先と同じ）なら何も出さずに終わる。
  - 通常のファイル、別の場所への symlink、リンク先が無い symlink、ファイルが無い、のどれかなら、状態を一行で書いた JSON（`systemMessage` と `hookSpecificOutput.additionalContext`）を出す。
  - 終了コードは常に 0（セッションの開始を止めない）。
- `linked/claude/settings.json` の SessionStart に配線する。
- 試験は bats（`dot_claude/hooks/settings-symlink-guard.bats`）と、配線の試験（`settings-wiring.bats`）。

## 配備

ソースの作業コピーが別の作業のブランチにあるあいだは、`chezmoi apply` で配れない。
配備の手順と時期は作業記録に書き、リーダーの判断を仰ぐ。
