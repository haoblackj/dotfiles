# 発言元の識別と開発工程の立て直し Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude の連絡を送り手つきの経路（peer）に寄せ、prts が記録から確定できる性質だけで入力を分類し、dotfiles のレビューの未対応の指摘と開発工程の欠けを直す。

**Architecture:** prts は時刻と文字の照合をやめ、会話の記録の項目だけで入力を `terminal`、`script`、`prts`、`other` に分ける。引き継ぎの指示は `SendMessage` で送る。CLAUDE.md とスキルは、確定できる範囲だけを書き、修正の依頼とレビューの指摘の場面で superpowers の工程に入る対応を持つ。

**Tech Stack:** Python 3.13（prts、uv、pytest）、bash（bats）、Python のフック（unittest を pytest で回す）、Markdown の文書。

**Spec:** `/home/yagu001/.local/share/chezmoi/docs/superpowers/specs/2026-11-20-speaker-identification-design.md`

## Global Constraints

- 推定を「リーダー」と表示する経路を作らない。prts の出力、画面、CLAUDE.md、スキルのどれにも「リーダーと確定」「リーダーの入力（確定）」と書かない。
- 端末からの入力の表示は「端末からの入力（発言者は記録から確定できない）」。
- 時刻の近さ、文字の照合、Herdr のログを発言者の判定に使わない。
- 端末への打ち込みを止めるガードを作らない。サンドボックスを入れない。
- main へマージしない。prts は `~/repo/github.com/haoblackj/prts`（`feat/work-record`）、dotfiles は `~/.local/share/chezmoi`（`ops/work-records`）。本チェックアウトで作業する（追加のワークツリーを作らない）。
- dotfiles のコミットはパスを名指しする（`git commit -- <パス>`、新しいファイルは `git add -N -- <パス>`）。`/tmp` は使わない（一時ファイルは scratchpad）。
- 削除は `trash-put`。破壊的な git の操作をしない。
- コミットの末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` と `Claude-Session: https://claude.ai/code/session_01J2p3EWHasPk5wCrNZbMzPu`。見出しの番号は `Refs #86`（prts では `Refs haoblackj/dotfiles#86`）。
- 文書とコメントは日本語。CLAUDE.md の書き方は既存の行に合わせる（一文ごとの具体、造語を使わない）。

## Review Focus

- 作業の途中で届いた入力（queued_command）が、同じ文の `type: user` の記録としても残る場合、二重に数えない（Task 1 の試験）。
- PRTS の束の中の「選択」の文と定型の行を、端末からの入力の原文として引かない（Task 2 の試験）。
- 発言の中で鉤括弧で引いた文、自分の文に添えて貼り付けた文を、原文として引かない（Task 2 の試験）。
- 圧縮のあとの差し込みが、別のワークツリーの記録の更新で消えない（基準が圧縮の境目なので、記録の mtime に依らない。Task 5 の試験）。
- 引き継ぎで新しいセッションの名前が `ListAgents` に出ないとき、黙って続けず止まる（Task 4 のスキルの文と、スクリプトの出力）。

---

### Task 1: prts が作業の途中の入力（queued_command）を読む

**Files:**
- Modify: `src/prts/transcript.py`（`user_utterances`）
- Test: `tests/test_transcript.py`

**Interfaces:**
- Produces: `transcript.user_utterances(path) -> list[Utterance]`。`Utterance(index, text, at, source)` の `source` は `promptSource` の値、queued_command なら `"queued_command"`。

- [ ] **Step 1: 試験を書く** `test_queued_command_attachment_is_an_utterance`: `type: attachment`、`attachment: {type: queued_command, prompt: "途中で打った文", origin: {kind: human}, humanTurn: true}`、`timestamp` の行を書き、`user_utterances` が `("途中で打った文", "queued_command")` を返す。`test_queued_command_not_counted_twice`: 同じ文が直後に `type: user`（promptSource queued）でも残る場合、1 件だけ返す。`test_queued_command_from_non_human_is_skipped`: `origin.kind` が `task-notification` なら返さない。
- [ ] **Step 2: 走らせて失敗を確かめる** `cd ~/repo/github.com/haoblackj/prts && uv run pytest -q tests/test_transcript.py`
- [ ] **Step 3: 実装** `user_utterances` で attachment の queued_command を読む。二重は「直前の発言と同じ文なら足さない」（今の重複の扱いを使う）。
- [ ] **Step 4: 通ることを確かめる** 同じコマンドで PASS。
- [ ] **Step 5: コミット** `fix: 作業の途中で届いた入力（queued_command）を人の入力として読む`

### Task 2: prts の入力の分類を、記録の項目だけで行う

**Files:**
- Modify: `src/prts/speaker.py`（作り直し）、`src/prts/transcript.py`（`find_quote`、`QuoteHit`）、`src/prts/cli.py`（`_cmd_quote`、`_cmd_candidates`、`_origin_entries`、`_KIND_LABEL`）、`src/prts/quotes.py`（置き場の名前）
- Test: `tests/test_speaker.py`（作り直し）、`tests/test_transcript.py`

**Interfaces:**
- Produces: `speaker.classify(text: str, source: str, want: str | None = None) -> Verdict`、`Verdict(kind: str, reason: str, quotable: bool)`。`kind` は `speaker.TERMINAL = "terminal"`、`SCRIPT = "script"`、`PRTS = "prts"`、`OTHER = "other"`。`quotable` は `kind == TERMINAL` かつ引用の位置に問題が無いときだけ True。`speaker.norm`、`speaker.norm_quote`、`speaker.MIN_QUOTE_CHARS = 8`、`speaker.quote_position(text, want) -> str | None` は残す。`Judge`、`sent_texts`、`prts_notes`、`strip_shell` は消す。
- Produces: `transcript.find_quote(quote: str) -> list[QuoteHit]`、`QuoteHit(session, project, at, text, kind, reason, quotable)`。
- Produces: `quotes._path()` は `state/terminal-quotes.json`。`quotes.remember(want, session, at)`、`quotes.load()`、`quotes.verified(line, known)` は今の形のまま。

- [ ] **Step 1: 試験を書く**（`tests/test_speaker.py` を置き換える。Herdr のログと送信の照合の試験は消す）
  - `classify("ふつうの指示です", "typed").kind == "terminal"`、`reason` に「端末からの入力」と「発言者は記録から確定できない」を含み、「リーダー」を含まない。`quotable` は True。
  - `source` が `queued`、`queued_command` でも `terminal`。
  - 書き出し「前のセッションからの引き継ぎ」「<agent-message」「別のセッション（」と、文中の「（前のセッションからの引き継ぎ。」は `script`、`quotable` False。
  - 書き出し `[prts] 指摘` は `prts`、`quotable` False、`reason` に「PRTS から届いた指摘」。
  - `suggestion_accepted`、`sdk`、空の `source` は `other`、`quotable` False。
  - 鉤括弧の中の文、自分の文に添えて貼り付けた文を `want` に渡すと `kind` は `terminal` のまま `quotable` False、`reason` に位置の理由。文全体を貼り付けた依頼は `quotable` True。
  - CLI: `prts quote` は `quotable` の当たりがあれば終了コード 0 で、出力に「端末からの入力の原文が記録にある（発言者は記録から確定できない）」を含み、「[リーダー」を含まない。当たりが無ければ 1。8 文字未満は 1。成功のときだけ `quotes.load()` に入る。`prts candidates --json` の各行に `kind`、`reason`、`quotable`。`wish add --pick` は `quotable` でない発言を断る。
  - `tests/conftest.py` から Herdr のログの準備が無いことを確かめる（入っていれば消す）。
- [ ] **Step 2: 失敗を確かめる** `uv run pytest -q tests/test_speaker.py`
- [ ] **Step 3: 実装** 上の Interfaces どおり。`find_quote` は全部の記録を `mmap` で絞り込み、`user_utterances` の当たりに `classify` を付ける（送信の照合の読み込みをしない）。
- [ ] **Step 4: 全部の試験** `uv run pytest -q` が全部通る。
- [ ] **Step 5: コミット** `fix: 入力を記録の項目だけで分類し、発言者を名乗らない`

### Task 3: prts の画面と文書を新しい分類に合わせる

**Files:**
- Modify: `src/prts/record.py`（`to_html` の `>` の行）、`src/prts/static/style.css`、`docs/operations.md`、`docs/dashboard-contract.md`
- Test: `tests/test_record.py`

**Interfaces:**
- Consumes: `quotes.verified(line, known)`（Task 2）。

- [ ] **Step 1: 試験を書く** `test_input_quote_is_not_leader_style`: 覚えた引用と一致する `>` の行は `class="input-quote"` で、「端末からの入力の原文」を含み、`leader-words` を含まない。一致しない行は `unverified-quote` と「原文未確認」。既存の `leader-words` を期待する試験は直す。
- [ ] **Step 2: 失敗を確かめる** `uv run pytest -q tests/test_record.py`
- [ ] **Step 3: 実装** `record.to_html` の `>` の行を上のとおりに出す。CSS に `.input-quote`（ゴシック、細い左の線、明朝を使わない）を足す。`docs/operations.md` の「引用の確かめ」を、分類（terminal、script、prts、other）と保証の範囲（同じ利用者の権限で動く Claude やほかのプログラムが端末に書き込んだ文と区別できない、確定にはサンドボックスが要る）に書き直す。`dashboard-contract.md` の作業記録の段落で、引用は「端末からの入力の原文」として出ると書く。
- [ ] **Step 4: 全部の試験** `uv run pytest -q`
- [ ] **Step 5: コミット** `fix: 作業記録の引用を、端末からの入力の原文として出す`

### Task 4: dotfiles の引き継ぎを SendMessage に寄せる

**Files:**
- Modify: `dot_claude/scripts/herdr-start-claude.sh`（`start_claude_in_new_tab`）、`dot_claude/scripts/executable_session-handoff.sh`、`dot_claude/scripts/session-handoff.bats`、`skills/session-handoff/SKILL.md`、`dot_claude/CLAUDE.md`（「Herdr でのセッションの立て方」）、`README.md`（引き継ぎの段落）
- Test: `dot_claude/scripts/session-handoff.bats`、`dot_claude/scripts/loop-handoff.bats`

**Interfaces:**
- Produces: `start_claude_in_new_tab ws dir model effort title name prompt` は `prompt` が空なら `herdr agent prompt` を呼ばない。`session-handoff.sh` の成功の JSON は `{handed_off: false, started: true, agent, tab, pane, state, title, prompt}`。`prompt` は今の引き継ぎの文と同じ文面。`loop-handoff.sh` は変えない（`/loop` を打つ）。

- [ ] **Step 1: 試験を書く** session-handoff.bats: 偽の herdr の呼び出しに `agent prompt` が無いこと、出力の JSON の `prompt` が今の期待の文と一致し、`title` が `--title` の値であること。loop-handoff.bats は今のまま通ること。
- [ ] **Step 2: 失敗を確かめる** `cd ~/.local/share/chezmoi && bats dot_claude/scripts/session-handoff.bats`
- [ ] **Step 3: 実装** スクリプトを直す。スキル `session-handoff` の手順 3 を「スクリプトでセッションを立てる。`ListAgents` に `--title` の名前が出たことを確かめ、出力の `prompt` を `SendMessage` でその名前へ送る。名前が出ない、または届けた結果に承認待ちや拒否の知らせがあれば、出力をリーダーに報告して止まる」に書き換える。CLAUDE.md の Herdr の節に「別のセッションへの連絡と引き継ぎの指示は `SendMessage` で送る（受けた側の記録に送り手が残る）。`herdr agent prompt` は、スラッシュコマンドを打つときと、試しのセッションでの実機の検証に限る」を足す。README の引き継ぎの段落も合わせる。
- [ ] **Step 4: 試験** `bats dot_claude/scripts/*.bats dot_claude/hooks/*.bats` が全部通る。
- [ ] **Step 5: コミット** `feat(claude): 引き継ぎの指示を SendMessage で送り、受けた側の記録に送り手を残す`

### Task 5: dotfiles のレビューの未対応の指摘を直す

**Files:**
- Modify: `dot_claude/hooks/executable_work-record-context.py`、`dot_claude/hooks/tests/test_work_record_context.py`、`dot_claude/scripts/herdr-start-claude.sh`（`check_state_file`）、`dot_claude/scripts/session-handoff.bats`、`dot_claude/scripts/loop-handoff.bats`、`dot_claude/CLAUDE.md`、`skills/work-record/SKILL.md`、`skills/session-handoff/SKILL.md`、`README.md`
- Test: `dot_claude/hooks/tests/test_work_record_context.py`、bats

**Interfaces:**
- Produces: フックの `inputs_since_boundary(transcript_path) -> tuple[list[tuple[str, str]], int]`（差し込む入力と省いた件数）。

- [ ] **Step 1: 試験を書く**（`test_work_record_context.py`）
  - 圧縮のあと: 記録の中の二つ目に新しい `compact_boundary`（`type: system`、`subtype: compact_boundary`）より後の人の入力（`type: user` の typed、queued、queued_command の attachment、suggestion_accepted）を差し込む。境目が一つなら会話の始めから。8 件を超えたら新しい 8 件と「ほか N 件」、全部を読むコマンド `prts candidates --session <session_id>`。差し込む文に「端末からの入力」と「発言者は記録から確定できない」を含み、「リーダー」と「記録の判断に従う」を含まない。
  - 別のワークツリーの記録の mtime が新しくても、差し込みが消えない。
  - 開始時の文が、優先の順として「いまの会話でのリーダーの指示」が記録より上、「安全と権限の決まり」が最上であることを書く。
  - 書き忘れの知らせ: 記録の最後のコミットの時刻（`git log -1 --format=%ct -- <記録>`）が HEAD のコミットの時刻より古く、記録に未コミットの変更が無いときだけ知らせる。記録とコードを同じコミットに入れたら知らせない。記録に未コミットの変更があれば知らせない。
  - 前書きが CRLF の記録の状態を読める。
  - bats: `check_state_file` は、`mkdir .git` だけの偽のディレクトリを断り、`git init` した作業コピーを受ける。
- [ ] **Step 2: 失敗を確かめる** `uv run --no-project --with pytest pytest -q dot_claude/hooks/tests` と `bats dot_claude/scripts/session-handoff.bats`
- [ ] **Step 3: 実装** フックと `check_state_file`（`git -C "$dir" rev-parse --show-toplevel` が `$dir` と一致）を直す。文書を直す:
  - CLAUDE.md の優先の順の行: 「安全と権限の決まり（指示範囲の厳守、本番データの保護、GitHub の名義と書き込みの制限、chezmoi の扱い、破壊的な操作）、いまの会話でのリーダーの指示、作業記録のうちリーダーが決めた有効な判断、この CLAUDE.md の一般の決まり、作業記録のうち Claude の技術の判断、そのほか（memory、issue、圧縮の要約）」。分類は記録と引用の扱いだけを決め、従う範囲は変えないと書く。
  - 「仕事の任され方」のリーダーが持つ判断に「安全と権限の決まりを緩める、消す」を足す。教訓と刈り込みの行で、安全と権限の決まりの行は Claude が緩めない、消さないと書く。
  - 異論の行（「新しく示された希望…元の判断を保つ」）を「Claude の技術の判断への異論」に限り、リーダーが「やめて」と言ったことは条件が無くても従うと書く。
  - 「指示範囲の厳守」のファイルの作成の行に、作業記録（`docs/work/`）の作成と更新は例外と書く。
  - 引用の行（「リーダーの言葉を他へ運ぶとき」「memory にリーダーの言葉を書くとき」「作業記録」の節）を「`prts quote` が成功した端末からの入力の原文だけを引用し、出典（会話、時刻）と『端末からの入力』を添える。発言者をリーダーと断定しない」に合わせる。
  - スキル work-record: 「食い違う側を直す」から安全と権限の決まりを除き、着手の手順 2 に「この会話の依頼が別にあれば依頼を先にする」。書式の「決めた人」を「出どころ: 端末からの入力（会話、時刻）」か「Claude の判断」に。引用の節を `prts quote` の分類に合わせる。
  - スキル session-handoff と README の引用の記述を合わせる。README の usage-route の表の stop の行を作業記録に合わせる。
- [ ] **Step 4: 試験** フックの pytest と bats が全部通る。CLAUDE.md の行数を数える（200 行を超えたら統合で減らす）。
- [ ] **Step 5: コミット**（Task 5 はファイルの多い直しなので、フックと試験、CLAUDE.md とスキルと README の 2 回に分けてよい）

### Task 6: 開発工程の欠けを直し、今回の場面で確かめる

**Files:**
- Modify: `dot_claude/CLAUDE.md`（「開発の工程（superpowers）」）、設計書の付録
- Test: サブエージェントによる試し（結果を設計書の付録に書く）

- [ ] **Step 1: 直す前の試し（RED）** サブエージェント 2 体（sonnet）に、直す前の「開発の工程」と「仕事の任され方」の文と、場面（2026-11-20 01:33 の指示、案 1 の判定の要点、レビューの 6 種類の抜け道の要約）を渡し、「次に何をするか」を一段落で答えさせる。答えに「条件を足して直す」が含まれるかを記録する。
- [ ] **Step 2: 直す** 「開発の工程」に次の三点だけを足す（設計書の付録の原因 2〜5 に対応）:
  - 指摘された欠陥の直しは superpowers:systematic-debugging から入る。小さく見える直しも、設計と計画を省く対象に含めない。
  - 審査は superpowers:requesting-code-review で頼み、レビュー役に「設計の前提（要件を満たせる根拠）を崩す指摘か」を必ず答えさせる。戻った指摘は superpowers:receiving-code-review で受け、前提を崩す指摘があれば、修正を足さずに systematic-debugging の作りの問い直しへ戻る。
  - 要件が「確定」「保証」を求めるときは、その根拠になる情報源を実装の前に実測して設計書に書く。見つからなければ実装せず、実証した範囲、制約、代替、推奨をリーダーに報告する（「頼まれた成果物は全部済ませてから報告する」より、この報告を先にする）。
- [ ] **Step 3: 直した後の試し（GREEN）** Step 1 と同じ場面を、直した後の文で同じ数のサブエージェントに渡す。合格は、答えが「方式の問い直し」か「要件を満たせない制約の報告」を選び、条件の追加を選ばないこと。合格しなければ文を直してやり直す。
- [ ] **Step 4: 記録** 試しの答えの要点と合否を設計書の付録に書く。
- [ ] **Step 5: コミット** `fix(claude): 欠陥の直しとレビューの指摘の場面で superpowers の工程に入る（Refs #86）`

### Task 7: 作業記録の書き直しと、本番への反映と確かめ

**Files:**
- Modify: `docs/work/claude-ops-records.md`

- [ ] **Step 1** 作業記録の引用を新しい書式（出どころ、`prts quote` の分類）に直し、今回の判断（4.1 の制約、A の採用、ガードとサンドボックスを採らない理由）を「判断の経緯」に足す。コミット。
- [ ] **Step 2** prts を入れ直す: `cd ~/repo/github.com/haoblackj/prts && uv tool install --force --reinstall . && systemctl --user restart prts-web.service`。画面が 200 を返すまで待つ。前の判定で覚えた引用の置き場 `~/.local/share/prts/state/verified-quotes.json` を `trash-put` で外す。
- [ ] **Step 3** dotfiles を反映: `chezmoi diff ~/.claude` を見てから `chezmoi apply ~/.claude`。
- [ ] **Step 4** 本番で確かめる: `prts quote` を作業記録の引用で回して「端末からの入力の原文」と出ること、`prts candidates --session 3f8034b1-a008-4bec-a6ed-2bc115163166 --json` に queued_command の入力（02:04 の文）が出ること、望みの画面（`curl -s http://127.0.0.1:8097/w/state-context/`）に `leader-words` が無く `input-quote` があること、`session-handoff.sh --dry-run` の出力に `agent prompt` が無いこと、圧縮のあとのフックを本物の会話の記録で動かして差し込みの文を確かめること。
- [ ] **Step 5** 両方のブランチを push（送り先を名指し: `git push origin ops/work-records`、`git push origin feat/work-record`）。
