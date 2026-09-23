# herdr のタブ名を Claude Code のセッションタイトルに揃える

作成日: 2026-09-23
issue: haoblackj/dotfiles#11（設計の合意と調査の出典はそちらが正本）

## 解決する問題

herdr のタブ名は手で付けるしかなく、タブに並ぶ Claude Code セッションが何の作業かを、タブを開かないと判別できない。
Claude Code は会話からセッションタイトル（ai-title）を自動で作るが、herdr にはタブ名をターミナルタイトルへ追従させる機能が無く、要望（herdrdev/herdr#4359）も 2026-09 に not_planned で閉じられた。

あわせて、Claude Code の入力欄の枠に出るチップは custom-title しか表示しないため、自動タイトルしかないセッションではチップが空のままになる。

このリポジトリで配る Claude Code の設定に、次の2つを加える。

1. 自動タイトルを custom-title に格上げし、チップに出す
2. statusline に渡るセッション名で herdr のタブ名を書き換える

## 検証済みの前提

2026-09-23、Claude Code 2.1.280 と herdr 0.9.1 で確かめた。
issue の調査結果のうち、この spec の設計が直接依存するものを公式ドキュメントの原文と実機で再確認した。

`hookSpecificOutput.sessionTitle` は `UserPromptSubmit` と `SessionStart` の両方で返せる（[hooks](https://code.claude.com/docs/en/hooks) の UserPromptSubmit decision control と SessionStart decision control の表）。
効果は `/rename` と同じ。
`SessionStart` では `source` が `startup`、`resume`、`fork` のときだけ効き、`clear` と `compact` では無視される。

`SessionStart` の入力には、タイトルが既に付いていれば `session_title` が入る。
公式は「`sessionTitle` を返すフックは、利用者が明示的に付けた名前を上書きしないよう先に `session_title` を見る」使い方を示している。

フックの入力の `transcript_path` が指す jsonl は非同期に書かれ、フックの発火時点で直近のターンを含まないことがある（同ページ）。
ai-title は jsonl に `{"type":"ai-title","aiTitle":"...","sessionId":"..."}` の1行として出る。
同じセッションで何度も出力され、最後の行が最新になる（手元の transcript で確認）。
jsonl の形式は内部仕様で、バージョンごとに変わりうる。

statusline の入力 JSON の `session_name` は、custom-title があればそれ、無ければ ai-title で、どちらも無ければキーごと無い（[statusline](https://code.claude.com/docs/en/statusline)）。
statusline のコマンドは、新しい応答、`/compact` の完了、`refreshInterval` の経過などで走り、300ms でデバウンスされる。
実行中に次の更新が来ると、実行中のスクリプトは打ち切られる。
このリポジトリの設定は `refreshInterval` を 30 秒にしている。

herdr のペインには `HERDR_ENV=1`、`HERDR_TAB_ID`、`HERDR_PANE_ID` が渡る。
`herdr tab get <TAB_ID>` は `{"result":{"tab":{"pane_count":N,...}}}` の形の JSON を返す。
`herdr tab rename <TAB_ID> <LABEL>` でタブ名を変えられる。

## 決定事項（issue #11 で合意済み）

方式は案B とする。
チップはフックで揃え、タブ名は statusline の `session_name` で追う。
却下した案A は、同じ `UserPromptSubmit` フックでタブ名も変える方式で、jsonl 読みにタブ名まで依存し、`/rename` に追従しない。
案B ならタブ名側は公式の入力欄（`session_name`）だけを読むので、`/rename` にもそのまま追従する。

タブ名に issue 番号の接頭辞（`#34` など）は付けない。
タブ名はセッションタイトルそのままにする。

`~/.claude/settings.json` に `"language": "japanese"` を足し、自動タイトルを日本語に固定する。
`language` は応答の言語と音声入力の言語も決める（[settings-reference](https://code.claude.com/docs/en/settings-reference#language)）。

## 設計

### 部品1: 自動タイトルを custom-title に格上げするフック

ファイルは `dot_claude/hooks/executable_session-title-promote.sh` とし、`~/.claude/hooks/session-title-promote.sh` に着地する。
1本のスクリプトで `SessionStart` と `UserPromptSubmit` の両方を受け、入力の `hook_event_name` で分岐する。
2つのイベントは同じ印ファイルを読み書きするので、ファイルを分けると印の置き場所の定義が2か所に割れる。

印は `${TMPDIR:-/tmp}/claude-session-titled/<session_id>` に置く。
印があるセッションには二度とタイトルを付けない。
`session_id` は既存フックと同じ正規表現 `^[A-Za-z0-9._-]+$` で検査し、外れたら何もしない（パストラバーサル対策）。

`SessionStart` のとき:

1. 入力の `session_title` が空でなければ印を置く
2. 何も出力せず終わる

`claude -n` で名前を付けて起動したセッションや、名前付きのセッションの `resume` を、自動タイトルで上書きしないための処理である。

`UserPromptSubmit` のとき:

1. 印があれば何もしない
2. `transcript_path` の jsonl から `type` が `custom-title` の行を探し、あれば印を置いて終わる
3. `type` が `ai-title` の最後の行の `aiTitle` を取る。無ければ何もしない
4. `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"<aiTitle>"}}` を stdout に出し、印を置く

手順2は issue の合意内容に対してこの spec で足したものである。
`SessionStart` はセッションの開始時に一度しか走らないので、起動後の最初のプロンプトより前に打った `/rename` は `session_title` に載らず、印も置かれない。
手順2が無いと、その名前を次のプロンプトで自動タイトルが上書きする。
ただし jsonl 上の custom-title の行の形（`"type":"custom-title"`）は、手元の transcript に実例が無く未検証である。
実装計画の最初の手順で、使い捨てのセッションで `/rename` を打ち、jsonl に出る行の形を確かめてから判定を書く。

ai-title は最初の応答のあとに作られるので、多くの場合、格上げは2回目のプロンプトで起きる。
jsonl の書き込みの遅れで取れなかったときも、印を置かないので次のプロンプトで取り直す。

割り切り:

- 一度名前が付くと、プラン承認時などにタイトルがプランの中身へ差し替わらなくなる。custom-title が ai-title より優先されるためである
- jsonl を読めない、形式が変わって ai-title の行が見つからない、`jq` が無い、のいずれでも何もしない（fail-open、常に exit 0）
- ブランチ番号など、タイトルに何かを付け足す処理は入れない

### 部品2: タブ名を同期するスクリプト

ファイルは `dot_claude/hooks/executable_herdr-tab-title-sync.sh` とし、`~/.claude/hooks/herdr-tab-title-sync.sh` に着地する。
statusline の登録は変えず、既存の `executable_statusline-context-window.sh` の中から呼ぶ。
ファイルを分けるのは、statusline の表示を待たせないため、また既存スクリプトの役割（使用率マーカーの書き出しと表示の整形）と混ぜないためである。

呼び出し側（`statusline-context-window.sh`）には、入力 JSON を読んだ直後に次の1行を足す。

```bash
printf '%s' "$INPUT" | bash "$HOOK_DIR/herdr-tab-title-sync.sh" >/dev/null 2>&1 &
```

`HOOK_DIR` は既存の `userpromptsubmit-compact-prep-reminder.sh` と同じく `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` で求める。
stdout と stderr を `/dev/null` へ向けるのは、バックグラウンドの子が statusline の出力のパイプを握ったままにならないようにするためである。
握ったままだと Claude Code がパイプの終端を待ち、表示が遅れる。

処理:

1. `HERDR_ENV` が `1` でなければ何もしない
2. `HERDR_TAB_ID` と `HERDR_PANE_ID` が空なら何もしない
3. 入力の `session_name` が無いか空なら何もしない（名前の無いタブは今の名前を保つ）
4. 前回このペインで書いた値と同じなら何もしない
5. `herdr tab get "$HERDR_TAB_ID"` の `.result.tab.pane_count` が 2 以上なら何もしない（どのセッション名を使うか決まらないため）。取れなければ何もしない
6. `herdr tab rename "$HERDR_TAB_ID" "$session_name"` を呼ぶ
7. 成功したときだけ、書いた値を記録する

前回値は `${TMPDIR:-/tmp}/herdr-tab-title/<HERDR_PANE_ID>` に置く。
ペインIDは `w9:p6` の形でコロンを含むので、検査の正規表現は `^[A-Za-z0-9:._-]+$` とする。

手順1から4は herdr を呼ばずに終わる。
`refreshInterval` による30秒ごとの実行の大半はここで止まり、herdr のソケットを叩かない。

値が変わったときだけ書き換えるので、herdr 側で手で付けたタブ名は、次にセッション名が変わるまで残る。
statusline の実行が打ち切られて子も止まった場合は、手順7の記録が残らないので、次の実行で書き直す。
herdr が無い、ソケットに繋がらない、rename が失敗した、のいずれでも statusline の表示には影響しない（fail-open、常に exit 0）。

### 部品3: 設定

`linked/claude/settings.json` に次を足す。
`statusLine` の登録は変えない。

- トップレベルに `"language": "japanese"`
- `hooks.SessionStart` に、matcher 無しで `bash "$HOME/.claude/hooks/session-title-promote.sh"`
- `hooks.UserPromptSubmit` に、matcher 無しで同じコマンド

コマンドの書き方は、直近に足した `guard-destructive-git.sh` などと同じ `bash "$HOME/.claude/hooks/<名前>"` に揃える。
`SessionStart` に matcher を付けないのは、`clear` と `compact` でも `session_title` を見て印を置く分には害が無く、条件を増やす理由が無いためである。

`~/.claude/settings.json` はソースの `linked/claude/settings.json` への symlink なので、`chezmoi re-add` は要らない。
新しい2本のスクリプトは `dot_claude/hooks/` に置けば `chezmoi apply` で配られる。

### テスト

このリポジトリの慣行に合わせる。
bash のフックは、ソースの `dot_claude/hooks/` に `<名前>.bats` を置いて bats で検証している（`statusline-context-window.bats` など）。
pytest は Python のフック（`memory_recall.py`）にだけ使っている。
`.bats` は `.chezmoiignore` の `.claude/hooks/*.bats` でターゲットへ配らない。

よって次の3本を bats で書く。
偽の `herdr` は、既存の `statusline-context-window.bats` が `ccstatusline` を偽物に差し替えているのと同じく、`setup()` で一時ディレクトリに作って `PATH` の先頭に置く。
偽の `herdr` は受け取った引数をファイルに追記し、`tab get` には環境変数で与えた `pane_count` の JSON を返す。
`TMPDIR` も一時ディレクトリへ向け、本物の印ファイルに触れない。

`dot_claude/hooks/session-title-promote.bats`:

- `SessionStart` で `session_title` あり → 印が置かれ、stdout は空
- `SessionStart` で `session_title` 無し → 印は置かれない
- `UserPromptSubmit` で ai-title の行が複数ある → 最後の行の `aiTitle` が `sessionTitle` として出て、印が置かれる
- `UserPromptSubmit` で印あり → 何も出さない
- `UserPromptSubmit` で custom-title の行あり → 何も出さず、印が置かれる
- `UserPromptSubmit` で ai-title の行が無い → 何も出さず、印も置かれない（次で取り直せる）
- `transcript_path` が存在しない、壊れた JSON の入力、`session_id` にパストラバーサル → exit 0、副作用なし
- タイトルに `"` や日本語を含む → 出力が妥当な JSON で、値が元のまま

`dot_claude/hooks/herdr-tab-title-sync.bats`:

- `HERDR_ENV` が無い → herdr を呼ばない
- `session_name` が無い → herdr を呼ばない
- `pane_count` が 1 → `tab rename <TAB_ID> <session_name>` が呼ばれ、前回値が記録される
- 同じ入力で2回目 → herdr を呼ばない
- `pane_count` が 2 → rename を呼ばず、前回値も記録しない
- `tab get` が JSON を返さない → rename を呼ばない
- 偽の `herdr` が rename で失敗する → 前回値を記録しない、exit 0
- `HERDR_PANE_ID` にパストラバーサル → 記録ディレクトリ外に副作用なし

`dot_claude/hooks/statusline-context-window.bats` に足すもの:

- `HERDR_ENV` を立てて偽の `herdr` を置いたとき、statusline の stdout が従来どおり入力のまま通り、rename が呼ばれる。バックグラウンド実行なので、呼ばれたかどうかは偽の `herdr` の引数記録ファイルの出現を短い上限つきで待って確かめる
- `herdr-tab-title-sync.sh` が見つからないときも、statusline の stdout と exit 0 は変わらない

ソースでは2本のスクリプトが `executable_` 付きの名前なので、`$HOOK_DIR/herdr-tab-title-sync.sh` はソース上に存在しない。
この2件のテストでは、`setup()` で2本をターゲットの名前にして一時ディレクトリへ写し、そこから statusline のスクリプトを走らせる。
既存の10件は従来どおりソースのスクリプトを直接走らせ、呼び出し先が見つからない状態で表示が壊れないことを兼ねて確かめる。

`dot_claude/hooks/settings-wiring.bats` に足すもの（`production-asset` タグ）:

- `language` が `japanese`
- `SessionStart` と `UserPromptSubmit` の両方に `session-title-promote.sh` が配線されている
- `statusLine.command` が従来どおり `statusline-context-window.sh` を指す

最後に実機で確かめる。
herdr の1ペインのタブで新しいセッションを起動し、2回目のプロンプトのあとにチップとタブ名が自動タイトルに変わること、`/rename` でタブ名が追従することを見る。

## 範囲外

- 1つのタブに複数ペインがあるときのタブ名の決め方
- ai-title 以外の情報（ブランチ名、issue 番号）をタブ名やタイトルに足すこと
- herdr 本体への機能追加
