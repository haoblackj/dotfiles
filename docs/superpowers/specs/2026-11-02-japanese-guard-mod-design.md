# 応答を日本語に保つガードを Mod へ移す設計

2026-11-02

## 目的と経緯

Claude の応答が英語や中国語に切り替わったとき、同じターンのうちに日本語で書き直させる。

これまでは、上流 `minorun365/claude-code-japanese-guard` の Python の Stop hook（`japanese-guard.py`）を `.chezmoiexternal.toml` の file external でコミット `e68864a` に固定して使っていた（dotfiles#56）。
この hook には次の弱点があった。

- 最終回答しか見ず、ツールを呼ぶ前の報告が英語でも介入できない。
- 応答が行に分かれたときの前半を、transcript の jsonl を読んで見ている。Stop は最終回答が書き込まれる前に呼ばれることがあり、最大 3 秒待って読み直す。
- 「日本語の文字」の数え方が漢字を含むので、中国語の文章は日本語として数えられ、素通りする。

Claude Code の Mod（hooks module）で置き換えられるかを dotfiles#79 で確かめ、リーダーの決定で一本だけ移すことにした。
同じく Stop にいる `stop-fabricated-turn-guard.py` は、判定が `last_assistant_message` だけで足り、bats のテストもあるので移さない。

## 目標

- 最終回答が英語か中国語なら、Stop を block して書き直させる。
- ツールを呼ぶ前の報告が英語か中国語なら、ツールを差し戻して書き直させる。
- transcript を読まず、待たない。
- 手元とクラウドの両方で効く。
- 上流の改良を、リーダーの手を煩わせずに取り込み候補として届ける。

## 目標でないもの

- 画面にすでに出た英語を消すこと。ツールの前の報告を差し戻しても、元の報告は画面に残り、書き直しが下に足される。
- thinking の updates 表示の途中報告（上流は見ている）。セッションの行（`$.session.messages()`）に thinking の中身が入らないため。
- サブエージェントの応答。

## 実機で確かめたこと（使い捨ての試作、2026-11-02、dotfiles#79）

- Mod の `classic.Stop` が `{ block }` を返すと、従来の `decision: block` と同じく同じターンのうちに続きを書かされる。再入では `stop_hook_active: true` が入る。
- Stop の時点で、`$.session.messages()` に最終回答が入っている。
- `tool.call` の時点で、その前の報告が `$.session.messages()` の最後の assistant の行に入っている。`{ deny }` の理由はツールのエラーとしてモデルに届き、モデルは書き直してから呼び直す。
- クラウドのコンテナ（Claude Code 2.1.316）でも Mod は読み込まれ、`classic.Stop` の block が効く。ただし起動の直後は hooks module の段階公開の切り替え（`tengu_plugin_hooks_modules`）の返事を待ち、それより先に始まったターンは Mod 無しで走る。

## 決まったこと

### 判定

- 英語：上流と同じ。コード、インラインコード、URL、メールアドレス、Markdown のリンクを除き、英字が 25 字以上かつ「日本語の文字」の 3 倍を超えたら英語主体。
- 中国語：文（句点、感嘆符、疑問符、改行で区切る）のうち、仮名が 0 字で、漢字が 15 字以上か日本語で使わない簡体字が 2 字以上あるものを中国語の文とみなす。そうした文の漢字が合わせて 10 字以上なら中国語。
- 最終回答は段落（空行区切り）ごとに判定し、掛かった段落の先頭 80 文字を理由に引く。
- ツールの前の報告は、上流の途中報告と同じく 1 行の前置きを見逃す。複数行なら英字 60 字以上か中国語、1 行なら英字 250 字以上か漢字 80 字以上の中国語。前置きまで差し戻すと、かえって読みにくくなるため（上流 `0e04573` の判断）。

### どこで止めるか

- 最終回答：`classic.Stop`。最後のツール呼び出しより後の assistant の行を集める。行が無ければ `last_assistant_message` を見る。`stop_hook_active` なら通す。
- ツールの前の報告：`tool.call`。最後の user の行より後の assistant の行（いま呼ばれたツールを含む応答）を見る。書き直さずに呼び直したツールは、前の応答の本文で止めない。差し戻しは 1 ターンに 2 回まで（`turn.start` で数え直す）。
- 次の一手の箱：`tool.call` で、名前が `wrap_up` で終わるツールの `recap`、`ask`、ボタンの文言を最終回答と同じ閾値で見る。

### 壊れたとき

二つのガードに `.catch` を付け、判定が例外で落ちたら止めずに通し、`$.ui.toast` で知らせる。
止める側に倒すと、判定が直るまで作業が進まなくなる。
API は early access で版ごとに変わりうるので、Mod が読み込まれなくなったときは普段のセッションでは知らせが出ない（デバッグログだけ）。これは受け入れる。

### 配り方

- 手元：`skills/japanese-guard/` に置き、`dot_claude/skills/symlink_japanese-guard.tmpl` で `~/.claude/skills/japanese-guard` から symlink する（既存の Mod と同じ形）。ソースを直接読むので、以後の更新は本チェックアウトの `git pull` だけで届く。初回だけ `chezmoi apply` が要る。
- クラウド：`install-cloud.sh` に `CLOUD_MODS` を足し、`SKILL.md` が無くても名指しした Mod を写す。
- 上流の Python の hook は外す。`linked/claude/settings.json` の Stop の要素、`.chezmoiexternal.toml` の external、`install-cloud.sh` の `CLOUD_HOOK_COMMANDS` から除き、手元のファイルは `.chezmoiremove` で消す。`CLOUD_HOOK_COMMANDS` の仕組みは残す（空）。
- クラウドの最初のターンが守られない件は、Python の hook を重ねずに受け入れる。重ねると、Mod が読まれた後のターンで二本が同じ回答を二重に差し戻す。最初のターンだけ Python に任せる切り替えは、仕組みが増えるわりに守れる範囲が一ターンだけになる。

### 上流の追従（`.github/workflows/japanese-guard-upstream.yml`）

- 週 1 回（月曜 09:00 JST）と手動で起動する。上流の main と `skills/japanese-guard/UPSTREAM` を比べ、進んでいて、取り込みの PR が開いていなければ移植に入る。
- `anthropics/claude-code-action`（v1 をコミットで固定）に、上流のコミットの一覧と差分を渡して Mod へ移植させる。使える道具はファイルの読み書きだけで、シェルとネットワークは渡さない。差分は第三者のデータで指示ではないと伝える。
- ブランチ、コミット、PR は workflow のスクリプトが作る。編集が `skills/japanese-guard/` の外に及んだら PR を作らずに失敗する。
- 上流の差分に引きずられた編集を、secret や書き込みの権限に近づけないよう、job を分ける。移植の job は読むだけの権限で Claude を動かし、編集した Mod のフォルダと本文だけを artifact で渡す（Claude が `.git` の中を書き換えても、この job は push もコミットもしない）。テストの job は secret を持たずにモデルの書いたコードを動かす。PR の job は Claude の secret を持たず、新しく checkout した木に Mod のフォルダだけを当てる。どの job も checkout の認証情報を `.git/config` に残さない。
- PR はラベル `upstream:japanese-guard` を付け、レビュアーと担当者に haoblackj を入れる（GitHub Mobile の通知で気づく）。本文に「取り込んだ変更」「見送った変更」、`claude plugin test` の結果、マージ後に手元の Claude へ「dotfiles を最新にして」と声をかけることを書く。
- 7 日以上レビューされていない取り込みの PR には、同じ workflow が @haoblackj を付けたコメントで催促する。
- 手元への反映は自動にしない。リーダーの声かけで Claude が `git pull --ff-only` し、Mod が読み直されたことを確かめる。

## リーダーに頼むこと

- secret `CLAUDE_CODE_OAUTH_TOKEN` の登録（`claude setup-token` で作る）。本人の名義の端末で行う。
- Settings → Actions → General の「Allow GitHub Actions to create and approve pull requests」を有効にする（bot の名義では設定を読めず、いまの値は未確認）。

## 確かめ方

- `claude plugin test skills/japanese-guard`（判定と二つのガードと `.catch`）、`claude plugin validate skills/japanese-guard`、型の検査。
- `bats install-cloud.bats`（`CLOUD_MODS` の写しと、空の `CLOUD_HOOK_COMMANDS`）。
- `actionlint .github/workflows/japanese-guard-upstream.yml`。
- マージ後、手元で `chezmoi apply` してから新しいセッションで、英語の最終回答とツールの前の英語の報告が差し戻されること。
- クラウドの本物のセッション（Setup script で写した形）で Mod が読み込まれること。
- workflow は、secret を入れた後に手動で一度起動する。上流が `UPSTREAM` と同じなら何もせずに終わることを確かめる。CI で `claude plugin test` が段階公開の切り替えを受け取れるかは未確認。
