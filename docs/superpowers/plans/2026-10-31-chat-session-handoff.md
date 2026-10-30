# 対話セッションの引き継ぎと掃除 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 対話セッションが使用率 40% を越えたら、キリの良いところで Herdr の同じワークスペースの新しいタブへ引き継ぎ、そのとき「閉じていい」と書いた idle のセッションのタブを閉じる。

**Architecture:** `context-level.sh` に対話用の段（40% / 60%）を足し、`chat-context-guard.sh` の知らせを `/clear` の勧めから引き継ぎの指示に替える。手順はスキル `session-handoff` にまとめ、機械的な部分（新しいタブで `claude` を起動、掃除の候補の一覧、タブを閉じる）はスクリプトが行う。新しいタブの起動は `loop-handoff.sh` と共有する。

**Tech Stack:** bash、jq、herdr CLI、bats

**Spec:** `docs/superpowers/specs/2026-10-30-chat-session-handoff-design.md`（決定の記録は haoblackj/dotfiles#73）

## Global Constraints

- 対話セッションの閾値は使用率だけで判定する。引き継ぎ 40%（`CONTEXT_GUARD_CHAT_HANDOFF_PCT`）、予備の段 60%（`CONTEXT_GUARD_CHAT_URGENT_PCT`）。トークン数の閾値は対話には使わない。
- ループの閾値と `loop-guard.sh` の挙動は変えない（50% / 75%、300K / 400K）。`loop-handoff.bats` と `loop-guard.bats` は無変更で通ること。
- フックは fail-open（読めない、値が無いときは黙って exit 0）。サブエージェント内とループのセッションでは何もしない（今と同じ）。
- 引き継ぎのファイルは `~/.cache/claude-handoff/` の下。`/tmp` に成果物を置かない（テストの `mktemp -d` は既存どおりでよい）。
- 閉じない条件: 元のセッション自身、引き継ぎで立てたペイン、`agent_status` が `idle` 以外、ループのセッション、transcript が見つからないか複数ある、最後のアシスタントの応答のあとにユーザーの入力がある、タブに他のペインがある、ワークスペースの最後のタブ。
- クラウドへは配らない（`install-cloud.sh` は変えない）。
- コメント、文面、コミットメッセージは日本語。既存のスクリプトの書き方（冒頭の説明コメント、`die`、`--dry-run`）に揃える。
- コミットはパスを名指し（`git commit -- <パス>`、新規は `git add -N -- <パス>`）。閉じる語と issue 番号を並べない（`（#73）` で添える）。

## Review Focus

1. `herdr pane list` は全ワークスペースのペインを返す。別のワークスペースのペインを候補に出さないこと（Task 3 の `list 他のワークスペースは出さない`）。
2. 一覧を出してから閉じるまでに、相手が動き出す（`idle` から `working`）。閉じる直前に確かめ直して残すこと（Task 3 の `close 直前に working なら残す`）。
3. 1M の窓で 30%（300K トークン）は、ループなら一段目だが、対話では何も出ないこと（Task 1 の `1M の窓で 30% は対話では何も出さない`）。
4. Herdr の外の端末で 40% を越えたとき、引き継げないので `/clear` の勧めに落ちること（Task 1 の `Herdr の外では /clear を勧める`）。
5. 作業フォルダにスペースを含むパス。新しいタブがその cwd で立つこと（Task 2 の `cwd にスペースがあっても渡る`）。

---

### Task 0: ワークツリー

- [ ] **Step 1:** `EnterWorktree` でワークツリーを切る（ブランチ名は `chat-session-handoff`）。
- [ ] **Step 2:** `bats --version` と `herdr --version` が通ることを確かめる（依存の導入は無い）。

### Task 1: 対話用の段と知らせ

**Files:**
- Modify: `dot_claude/hooks/context-level.sh`
- Modify: `dot_claude/hooks/executable_chat-context-guard.sh`
- Test: `dot_claude/hooks/chat-context-guard.bats`

**Interfaces:**
- Produces: `context-level.sh` が決める `CHAT_CTX`（`low` / `handoff` / `urgent` / 空）。`CTX` と同じく使用率のマーカーが無ければ空。既存の `CTX`、`PCT`、`TOKENS` は変えない。
- Produces: 知らせの文面が、スキル名 `session-handoff` を名指しする。

- [ ] **Step 1: 既存の一段目と二段目のテストを、次のテストに置き換える**

`setup` の `unset` に `CHAT_HANDOFF_PCT CHAT_URGENT_PCT` を足し、`HERDR_ENV=1` を export する。

```bash
@test "40% -> いまの依頼をキリの良いところまで進めてから session-handoff で移らせる。一度だけ" {
    ctx 40
    prompt "ふつうの依頼"
    [[ "$(context_of)" == "[chat-context-guard] "*"キリの良いところ"*"session-handoff"* ]]
    prompt "次"
    [ -z "$output" ]
    grep -q "notice:handoff" "$LOG"
}
@test "60% -> 依頼に入る前に session-handoff で移らせる。一度だけ" {
    ctx 60
    prompt "a"
    [[ "$(context_of)" == *"入る前に"*"session-handoff"* ]]
    prompt "b"
    [ -z "$output" ]
    grep -q "notice:urgent" "$LOG"
}
@test "40% の知らせのあとに 60% を越えたら、60% も一度出す" { ctx 40; prompt a; ctx 60; prompt b; [[ "$(context_of)" == *"入る前に"* ]]; }
@test "1M の窓で 30% は対話では何も出さない" { ctx 30 1000000; prompt a; [ -z "$output" ]; }
@test "40% を下回ったら、次に越えたときにまた知らせる" { ctx 40; prompt a; ctx 10; prompt b; ctx 41; prompt c; [[ "$(context_of)" == *"session-handoff"* ]]; }
@test "Herdr の外では /clear を勧める" { unset HERDR_ENV; ctx 40; prompt a; [[ "$(context_of)" == *"/clear"* ]]; [[ "$(context_of)" != *"session-handoff"* ]]; }
@test "閾値は環境変数で差し替えられる" { export CONTEXT_GUARD_CHAT_HANDOFF_PCT=20; ctx 21; prompt a; [[ "$(context_of)" == *"session-handoff"* ]]; }
```

ループのセッション、サブエージェント、fail-open の既存テストは残す。

- [ ] **Step 2:** `bats dot_claude/hooks/chat-context-guard.bats` を走らせ、新しいテストが落ちることを確かめる。
- [ ] **Step 3: `context-level.sh` に `CHAT_HANDOFF_PCT`（既定 40）、`CHAT_URGENT_PCT`（既定 60）と `CHAT_CTX` を足す。** 数でなければ `return 1`（既存の検査に並べる）。冒頭のコメントに対話の段を書き足す。
- [ ] **Step 4: `chat-context-guard.sh` を `CHAT_CTX` で判定するように替える。** 印は `$SID.handoff`（40%）と `$SID.urgent`（60%）、`CHAT_CTX` が `low` なら両方消す。文面:
  - 40%（Herdr の中）: 「`<ctx_desc>` が引き継ぎの閾値を越えた。いまの依頼をキリの良いところ（コミットや一区切りの報告が済んだところ）まで進めたら、スキル `session-handoff` の手順で新しいセッションへ移る。」
  - 60%（Herdr の中）: 「`<ctx_desc>` が引き継ぎの予備の閾値を越えた。この依頼に入る前に、スキル `session-handoff` の手順で新しいセッションへ移る。リーダーがこのまま続けるよう言ったら従う。」
  - Herdr の外（`HERDR_ENV` が `1` でない）: 今の二つの文面（状態を書き出して `/clear` を勧める）を、それぞれ 40% と 60% で出す。
  冒頭のコメントを新しい挙動に合わせて書き直す（#73 を添える）。
- [ ] **Step 5:** `bats dot_claude/hooks/chat-context-guard.bats dot_claude/hooks/loop-guard.bats` が全部通ることを確かめる。
- [ ] **Step 6: コミット** `feat: 対話セッションは 40% で引き継ぎを指示する（#73）`

### Task 2: 新しいタブで claude を起動する部分の共有と、対話の引き継ぎスクリプト

**Files:**
- Create: `dot_claude/scripts/herdr-start-claude.sh`（source する共通部分。実行属性なし）
- Modify: `dot_claude/scripts/executable_loop-handoff.sh`（共通部分を使うように替える。挙動は変えない）
- Create: `dot_claude/scripts/executable_session-handoff.sh`
- Test: `dot_claude/scripts/session-handoff.bats`（`loop-handoff.bats` の偽の herdr を写す）

**Interfaces:**
- Produces: `herdr-start-claude.sh` の関数 `start_claude_in_new_tab <ws> <dir> <model> <effort> <name> <prompt>`。成功で標準出力に `{"tab":"<tab_id>","pane":"<pane_id>"}`、失敗で手順名を標準エラーに出して 1。`DRY=1` のときは呼ぶはずのコマンドを出す（今の `loop-handoff.sh` の `run` と同じ）。
- Produces: `session-handoff.sh --state <URL か ~/.cache/claude-handoff/ 下のファイル> --cwd <dir> --model <m> --effort <e> [--dry-run]`。成功で `{"handed_off":true,"agent":"<name>","tab":"<tab_id>","pane":"<pane_id>","state":"<state>"}` を出す。

- [ ] **Step 1: 失敗するテストを書く**

```bash
@test "状態のコメントの URL で、指定の cwd に新しいタブを立てて渡す" {
    handoff --state "$URL" --cwd "$FAKE_CWD"
    [ "$status" -eq 0 ]
    grep -q -- "tab create --workspace w3 --cwd $FAKE_CWD --no-focus" "$CALLS"
    grep -q -- "agent start chat-.* --kind claude --pane w1:p42 --timeout 120000 -- --model opus --effort medium" "$CALLS"
    [ "$(jq -r .pane <<< "$output")" = "w1:p42" ]
    [ "$(jq -r .tab <<< "$output")" = "w1:t9" ]
}
@test "状態のファイルは ~/.cache/claude-handoff/ の下だけを受け付ける" {
    mkdir -p "$HOME/.cache/claude-handoff"; f="$HOME/.cache/claude-handoff/x.md"; echo s > "$f"
    handoff --state "$f" --cwd "$FAKE_CWD"; [ "$status" -eq 0 ]
    handoff --state "$TMPDIR_TEST/x.md" --cwd "$FAKE_CWD"; [ "$status" -eq 1 ]
}
@test "引き継ぎの文面は、状態の在りかを読んで次の一手から続けるよう言い、/loop を付けない" {
    handoff --state "$URL" --cwd "$FAKE_CWD"
    grep "agent prompt" "$CALLS" | grep -q "$URL"
    ! grep "agent prompt" "$CALLS" | grep -q "/loop"
}
@test "cwd にスペースがあっても渡る" { d="$TMPDIR_TEST/a b"; mkdir -p "$d"; handoff --state "$URL" --cwd "$d" --dry-run; [[ "$output" == *"a\\ b"* ]]; }
@test "cwd が無いディレクトリなら止まる" { handoff --state "$URL" --cwd /nonexistent; [ "$status" -eq 1 ]; }
@test "Herdr の外なら止まる" { unset HERDR_ENV; handoff --state "$URL" --cwd "$FAKE_CWD"; [ "$status" -eq 1 ]; }
```

`setup` で `HOME` を `$TMPDIR_TEST/home` に向ける。ワークスペースは `loop-handoff.sh` と同じく `pane current` から取る（偽物は `w3` を返す）。cwd は `pane current` から取らず、`--cwd` の値を使う。

- [ ] **Step 2:** `bats dot_claude/scripts/session-handoff.bats` が落ちることを確かめる。
- [ ] **Step 3: `herdr-start-claude.sh` に `loop-handoff.sh` のタブ作成から `agent prompt` までを移し、`loop-handoff.sh` はそれを呼ぶ形にする。** 待ちと再試行しない方針のコメントは共通部分へ移す。
- [ ] **Step 4:** `bats dot_claude/scripts/loop-handoff.bats` が無変更で通ることを確かめる。
- [ ] **Step 5: `session-handoff.sh` を書く。** agent の名前は `chat-$(date +%m%d%H%M%S)`。引き継ぎの文面:

```
前のセッションからの引き継ぎ。最初に状態 <state> を読み（issue のコメントなら、それより新しい `## 状態` も）、そこに書かれた作業フォルダ、ワークツリー、ブランチ、issue と PR を確かめてから「次の一手」から続ける。
```

- [ ] **Step 6:** `bats dot_claude/scripts/` が全部通ることを確かめる。
- [ ] **Step 7: コミット** `feat: 対話セッションを新しいタブへ引き継ぐスクリプトを足す（#73）`

### Task 3: 掃除の候補の一覧と、タブを閉じるスクリプト

**Files:**
- Create: `dot_claude/scripts/executable_herdr-closable.sh`
- Test: `dot_claude/scripts/herdr-closable.bats`

**Interfaces:**
- Produces: `herdr-closable.sh list --exclude-pane <pane_id> [--exclude-pane ...]`。自分のワークスペース（`pane current` の `workspace_id`）の候補を 1 行 1 件の JSON で出す: `{"pane":"…","tab":"…","session_id":"…","title":"…","last_reply":"…"}`。
- Produces: `herdr-closable.sh close <pane_id>...`。ペインごとに `{"pane":"…","tab":"…","result":"closed"}` か `{"pane":"…","result":"kept","reason":"…"}` を出す。
- Consumes: transcript は `~/.claude/projects/*/<session_id>.jsonl`。ループの印は `${TMPDIR:-/tmp}/claude-loop-guard/<session_id>.prompts`。

- [ ] **Step 1: 失敗するテストを書く。** 偽の herdr の `pane list` は、実機の `herdr pane list` の出力（`.result.panes[]` に `pane_id`、`tab_id`、`workspace_id`、`agent`、`agent_status`、`agent_session.value`、`terminal_title_stripped`）と同じ形で答える。実機の出力を一度取り、形が合っていることを確かめてから偽物を書く。transcript は `$HOME/.claude/projects/p/<sid>.jsonl` に、`{"type":"user","message":{"role":"user","content":"…"}}` と `{"type":"assistant","message":{"content":[{"type":"text","text":"…"}]}}` の行で置く（実機の transcript の形を確かめて合わせる）。

```bash
@test "list 同じワークスペースの idle の Claude を、最後の応答の文面つきで出す" { …; [ "$(jq -r .last_reply <<< "$output")" = "終わったよ。このタブは閉じていいよ" ]; }
@test "list 他のワークスペースは出さない" { … }
@test "list 自分と --exclude-pane のペインは出さない" { … }
@test "list working のものは出さない" { … }
@test "list ループのセッションは出さない" { … }
@test "list transcript が無いか二つあるものは出さない" { … }
@test "list 最後の応答のあとにユーザーの入力があるものは出さない" { … }
@test "close idle で一つきりのペインのタブを閉じる" { …; grep -q "tab close w3:t2" "$CALLS"; }
@test "close 直前に working なら残す" { …; [ "$(jq -r .reason <<< "$output")" = "not_idle" ]; }
@test "close タブに他のペインがあれば残す" { … reason は "shared_tab" }
@test "close ワークスペースの最後のタブは閉じない" { … reason は "last_tab" }
```

`last_reply` は最後のアシスタントのメッセージの text 部分をつないだもの。tool_result だけの user 行は「ユーザーの入力」に数えない。

- [ ] **Step 2:** `bats dot_claude/scripts/herdr-closable.bats` が落ちることを確かめる。
- [ ] **Step 3: `herdr-closable.sh` を書く。** `list` の除外条件と `close` の確かめ直しは Global Constraints のとおり。`close` は `herdr pane list` を取り直し、そのペインの `agent_status` が `idle`、同じ `tab_id` のペインが一つ、同じ `workspace_id` のタブが二つ以上、のときだけ `herdr tab close <tab_id>`。冒頭のコメントに、閉じてよいかの判断はここではせず Claude が `last_reply` を読んで決めることを書く。
- [ ] **Step 4:** `bats dot_claude/scripts/herdr-closable.bats` が通ることを確かめる。
- [ ] **Step 5: コミット** `feat: 閉じていいセッションの候補を出し、タブを閉じるスクリプトを足す（#73）`

### Task 4: スキル session-handoff と文書

**Files:**
- Create: `skills/session-handoff/SKILL.md`
- Create: `dot_claude/skills/symlink_session-handoff.tmpl`（中身は `{{ .chezmoi.sourceDir }}/skills/session-handoff`）
- Modify: `README.md`（「ループ以外の対話セッションの見張り」の節）
- Modify: `dot_claude/CLAUDE.md`（「委譲と情報の流通」のループの行の近くに、対話セッションの引き継ぎを 1〜2 行）

**Interfaces:**
- Consumes: Task 2 の `session-handoff.sh`、Task 3 の `herdr-closable.sh`。

- [ ] **Step 1: `SKILL.md` を書く。** description は「コンテキストの知らせ（chat-context-guard）で引き継ぎを指示されたとき、またはリーダーに『移って』『新しいセッションへ移って』と言われたときに使う」。手順は spec の「引き継ぎの手順」の 1〜5 をそのまま写す。具体的には:
  1. 状態を書く。issue があればその `## 状態` コメント（一つ前をたたむ）。無ければ issue を立てることをリーダーに提案して待ち、却下なら `~/.cache/claude-handoff/<日付>-<session_id>.md`。中身は、済んだこと、決定、次の一手、作業フォルダ、ワークツリーのパスとブランチ、issue と PR、元の session_id、裏で走っている処理とその扱い。
  2. モデルとエフォートを残りの仕事から選ぶ（理由を一言）。
  3. `~/.claude/scripts/session-handoff.sh --state … --cwd <作業フォルダかワークツリー> --model … --effort …` を呼ぶ。失敗したら出力をリーダーに出して止まる（掃除へ進まない）。
  4. `~/.claude/scripts/herdr-closable.sh list --exclude-pane <立てたペイン>` の候補ごとに `last_reply` を読み、そのセッションが自分の仕事について「閉じていい」とはっきり書いているものだけを `close` に渡す。迷えば残す。セッションに宣言を求めない。
  5. 応答で、引き継いだ先（タブ）、閉じたタブ、残した候補とその理由を報告し、最後に「このセッションは閉じていい」と書いて止まる。
- [ ] **Step 2:** `chezmoi apply --dry-run --verbose ~/.claude/skills/session-handoff ~/.claude/scripts ~/.claude/hooks` で、symlink とスクリプトが配られる予定であることを確かめる。
- [ ] **Step 3:** README の節を新しい挙動（40% / 60% の表、Herdr の外の `/clear`、スキル、二つのスクリプト、テストのファイル）に書き換える。`dot_claude/CLAUDE.md` に行を足し、`wc -l` で 200 行を越えていないか確かめる。
- [ ] **Step 4:** `bats dot_claude/hooks/ dot_claude/scripts/` が全部通ることを確かめる。
- [ ] **Step 5: コミット** `feat: 引き継ぎの手順をスキル session-handoff にまとめる（#73）`

### Task 5: 実機での確かめ

- [ ] **Step 1:** ブランチを main へ入れて `chezmoi apply` したあと、グローバルの CLAUDE.md の「対話セッションでの実機検証」に従い、scratchpad の作業ディレクトリに Herdr のタブを二つ立てる。一つは最後に「閉じていいよ」と書かせ、もう一つは「閉じていいか確認させて」と書かせて止める。
- [ ] **Step 2:** 三つ目のタブで `CONTEXT_GUARD_CHAT_HANDOFF_PCT=1` を入れて立て、一往復して知らせが出ること、「移って」で新しいタブが同じ cwd に立つこと、一つ目だけが閉じられ二つ目が残ること、報告が元のセッションに出ることを確かめる。
- [ ] **Step 3:** 自分で立てたタブを閉じ、結果を #73 の `## 状態` コメントに書く。
