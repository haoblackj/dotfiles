# 端末からの入力の扱いと公開の最小化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 端末からの入力と PRTS の指摘をリーダーの判断として引き継げるようにし、GitHub に載る記録から会話の原文を外し、開発工程の決まりの直しを本番の設定の新しいセッションで確かめる。

**Architecture:** prts は出典（会話の 8 桁と JST の日時）で確かめた文を手元に覚え、望みの画面で出典の行の下に原文を出す。dotfiles は CLAUDE.md、スキル work-record、圧縮のあとの差し込みのフックの文言を、設計書 3〜5 節の扱いに直す。既存の記録は出典と要旨の書式へ書き換える。

**Tech Stack:** Python 3（prts、uv、pytest）、bash と bats、chezmoi。

**Spec:** `docs/superpowers/specs/2026-11-20-practical-trust-design.md`

**実行方式:** このセッションで自分で進める（executing-plans）。課題どうしが文言と書式でつながっていて、独立した仕事が少ないため。

## Global Constraints

- GitHub に載る物（作業記録、設計書、計画、issue、PR、コミットの本文）に、端末からの入力の原文を写さない。出典は `端末からの入力（会話 <8 桁>、<YYYY-MM-DD HH:MM>）`（日時は JST）。
- 表示と記録では、事実（端末から来た）と扱い（リーダーの入力として扱う）を分ける。「リーダーが打った」と書かない。札の文言は「端末からの入力（リーダーの入力として扱う）」。
- 決まりは足さず、既存の行を直す。グローバルの CLAUDE.md は 200 行以下。
- 試しは本番の設定で行い、新しい隔離環境、常駐、検証基盤を作らない。書き込みの道具を外した `claude -p --no-session-persistence` を使う。
- main へ取り込まない。履歴の書き換え、issue のコメントの削除はしない。
- dotfiles のコミットはパスを名指しする（`git commit -- <パス>`）。push 先は `git push origin <ブランチ>`。

## Review Focus

- 出典の日時の分が JST で、会話の記録の UTC の時刻から正しく変わること（日付をまたぐ 00:xx の入力）。
- 同じ分に二つの入力があるとき、`prts input` が両方を出し、画面は確かめた文だけを出すこと。
- 前の書式（`>` の引用）の記録も画面で崩れないこと。
- 出典の書き方が作業記録の箇条の中にあっても、段落の中にあっても見つかること。
- 圧縮のあとの差し込みで、同じ入力が `queued_command` と順番待ちの両方から二重に出ないこと。

---

### Task 1: prts の出典（`prts quote` の出力、手元の覚え、`prts input`）

**Files:**
- Modify: `src/prts/quotes.py`、`src/prts/cli.py`、`src/prts/transcript.py`
- Test: `tests/test_record.py`（quotes の試験がある所）、`tests/test_transcript.py`

**Interfaces:**
- Produces: `quotes.source_of(session: str, at: str) -> str`（`会話 3f8034b1、2026-11-20 02:40`）、`quotes.remember(want, session, at)`（出典ごとの文も覚える。置き場 `state/terminal-sources.json`、形 `{出典: [文, ...]}`、重複なし）、`quotes.phrases_for(source: str, known: dict | None = None) -> list[str]`、`quotes.load_sources() -> dict`、`transcript.inputs_at(session_prefix: str, minute_jst: str) -> list[Utterance]`。
- CLI: `prts quote` は最後に `出典: 端末からの入力（会話 <8 桁>、<日時>）` を出す。`prts input <会話の 8 桁> "<YYYY-MM-DD HH:MM>"` はその分の端末からの入力と PRTS の指摘の全文を出し、無ければ終了コード 1。

- [ ] 試験: `source_of("3f8034b1-a008-…", "2026-11-19T17:40:05.000Z") == "会話 3f8034b1、2026-11-20 02:40"`（UTC から JST、日付をまたぐ）。`remember` の後に `phrases_for` が文を返し、同じ文を二度覚えても一つ。`inputs_at` は同じ分の二つの入力を両方返し、SendMessage（peer）と別の分は返さない。
- [ ] 失敗を確かめる、実装する、`uv run pytest -q` で全件通す、コミットする。

### Task 2: prts の望みの画面で、出典の行の下に原文を出す

**Files:**
- Modify: `src/prts/record.py`（`to_html`）、呼び出し側（`pages.py` の `to_html` の呼び出し）
- Test: `tests/test_record.py`

**Interfaces:**
- Consumes: `quotes.phrases_for`、`quotes.load_sources`。
- Produces: `record.to_html(text, known_quotes=None, known_sources=None)`。箇条か段落の行に `端末からの入力（会話 ([0-9a-f]{8})、(\d{4}-\d{2}-\d{2} \d{2}:\d{2})）` があれば、その行の中に `<blockquote class="input-quote">「文」<span class="stale">端末からの入力の原文（手元の記録から。リーダーの入力として扱う）</span></blockquote>` を文ごとに足す。覚えていない出典は `<span class="stale">原文は手元で未確認（prts quote で確かめていない出典）</span>`。前の書式の `>` の行の札は「端末からの入力の原文（リーダーの入力として扱う）」。

- [ ] 試験: 箇条の出典の行の下に原文が出る。段落の中の出典も同じ。覚えていない出典に未確認の札。前の書式の `>` の行の札の文言。原文の中の `<` はエスケープされる。
- [ ] 失敗を確かめる、実装する、全件通す、コミットする。

### Task 3: prts の札、「いま」の材料、説明の文書

**Files:**
- Modify: `src/prts/speaker.py`（`TERMINAL_REASON` と冒頭の説明）、`src/prts/summary.py`（`PROMPT` と `window` の見出し）、`src/prts/cli.py`（分類の札と help）、`docs/operations.md`（信頼の範囲の節）、ほか `発言者は記録から確定できない` を含む所
- Test: `tests/test_summary.py`、`tests/test_speaker.py`

- [ ] `window` の見出しは `[リーダーの入力（端末と PRTS の指摘。Claude どうしの連絡と引き継ぎの定型文は除いた）]`、PRTS の指摘は `（PRTS の指摘）` を前に付ける。`PROMPT` は、材料の「リーダーの入力」をリーダーの指示や判断として書いてよく、「Claude の直近の発言」をリーダーの言葉として書かない、と指示する。
- [ ] `TERMINAL_REASON = "端末からの入力（リーダーの入力として扱う）"`。`docs/operations.md` に設計書 3 節の表の要約と残る危険を書く。
- [ ] 試験の期待値を直し、全件通す、コミットする。

### Task 4: dotfiles の決まり（CLAUDE.md、スキル work-record、差し込みのフック）

**Files:**
- Modify: `dot_claude/CLAUDE.md`、`skills/work-record/SKILL.md`、`dot_claude/hooks/executable_work-record-context.py`、`dot_claude/skills/session-handoff/` と `dot_claude/scripts/` のうち端末からの入力の扱いを書いた文
- Test: `dot_claude/hooks/tests/` の差し込みのフックの試験、bats

- [ ] CLAUDE.md: 設計書 5 節の 1〜4 と、引用の行（GitHub に載る物には原文を写さず要旨と出典、出典は `prts quote` で確かめる、手元から出ない指示では原文を引いてよい）を直す。「Claude が緩めない、消さない」の列挙の言い換えを合わせる。行数は 200 以下。
- [ ] スキル work-record: 書式を設計書 4.2 に、優先の順と出どころの扱いを 3 節に合わせる。
- [ ] フック: 差し込みの見出しを「端末からの入力（リーダーの入力として扱う。会話の記録から原文で、古い順）」にし、「記録には原文を写さず、要旨と出典を書く」と案内する。同じ入力が `queued_command` と順番待ちの両方にあるときは一つにする（試験を先に書く）。
- [ ] 試験（pytest と bats）を通す、パスを名指ししてコミットする。

### Task 5: 既存の記録の書き換えと、前回残した小さな指摘

**Files:**
- Modify: `docs/work/claude-ops-records.md`、`docs/superpowers/specs/2026-11-20-speaker-identification-design.md`、`docs/superpowers/plans/2026-11-20-speaker-identification.md`、`dot_claude/scripts/executable_session-handoff.sh`（`--dry-run`）

- [ ] 原文の引用をそれぞれ `prts quote` で確かめて出典を得て、出典と要旨に書き換える（確かめられない物は未確認）。これで手元の覚えにも入り、画面に原文が出る。
- [ ] `git grep` で、三つのファイルに端末からの入力の原文（`」（端末からの入力`）が残っていないことを確かめる。
- [ ] `session-handoff.sh --dry-run` が引き継ぎの文を出す（bats を先に書く）。前の設計書の付録が追跡外の素材を指す所は、手元にあることと公開しないことを書く。
- [ ] コミットして push する。PR #98 の本文に原文が無いことを確かめる。

### Task 6: 本番への反映と、実際の運用の場面での確かめ

- [ ] prts: `uv tool install --force --reinstall .`、`systemctl --user restart prts-web.service`、画面が 200。
- [ ] dotfiles: `chezmoi apply ~/.claude`、`chezmoi status ~/.claude` が空、本番の CLAUDE.md の行を grep で確かめる。
- [ ] 設計書 6 節の場面を直した後の設定で動かす（S1、S2、S5、S7 を 2 回、S3、S6 を 1 回）。合否を設計書の基準で判定し、結果を設計書の付録に書く。不合格があれば systematic-debugging から直す。
- [ ] state-context の望みの画面を 390px の幅で撮り、目的、いま、判断の経緯が原文と要旨を並べて読めることを見る。
- [ ] 圧縮のあとの差し込みのフックを本物の会話の記録で動かし、見出しと案内を確かめる。

### Task 7: 審査と完了

- [ ] requesting-code-review で両リポジトリの差分の審査を頼み、「設計の前提を崩す指摘か」「リーダーの持つ判断に触れる指摘か」を答えさせる。戻った指摘は receiving-code-review で受ける。
- [ ] verification-before-completion: リーダーの依頼の目的と条件（A、B、C、六つの性質、作業条件）から要件の表を作り、各行の証拠を並べる。
- [ ] 作業記録を今に合わせ、PR の本文を直し、reviewable-html で報告を作って単体の HTML を送る。
