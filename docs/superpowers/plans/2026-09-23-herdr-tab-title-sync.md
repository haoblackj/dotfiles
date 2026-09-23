# herdr タブ名のセッションタイトル同期 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 自動生成のセッションタイトルを custom-title に格上げしてチップに出し、herdr のタブ名を statusline の `session_name` に追従させる。

**Architecture:** 部品1の `session-title-promote.sh` は `SessionStart` と `UserPromptSubmit` のフックで、transcript の jsonl から最新の ai-title を拾って `sessionTitle` として返す。部品2の `herdr-tab-title-sync.sh` は、既存の `statusline-context-window.sh` からバックグラウンドで呼ばれ、`session_name` が変わったときだけ `herdr tab rename` を呼ぶ。部品3で `linked/claude/settings.json` にフックと `language` を足す。

**Tech Stack:** bash、jq、bats 1.14（テスト）、herdr 0.9.1 CLI、Claude Code 2.1.280

**Spec:** `docs/superpowers/specs/2026-09-23-herdr-tab-title-sync-design.md`（決定の正本は haoblackj/dotfiles#11）

## Global Constraints

- 作業はワークツリーで行う（`EnterWorktree`、サブエージェントは `isolation: "worktree"`）。Task 1 と Task 6 は herdr を操作するため、コントローラーが本体のセッションで行う
- フックは `dot_claude/hooks/executable_<名前>.sh` に置き、テストはソース側の `dot_claude/hooks/<名前>.bats`（`.chezmoiignore` がターゲットへ配らない）
- 印ファイルは `${TMPDIR:-/tmp}/claude-session-titled/<session_id>`、前回値は `${TMPDIR:-/tmp}/herdr-tab-title/<HERDR_PANE_ID>`
- `session_id` の検査は `^[A-Za-z0-9._-]+$`、herdr の ID の検査は `^[A-Za-z0-9:._-]+$` に加えて `..` を含まないこと
- どのスクリプトも fail-open（常に exit 0）。statusline の stdout を変えない
- `herdr tab rename` にはタブIDとラベルの2引数だけを渡す。`--` を挟まない（herdr 0.9.1 は `--` もラベルの一部として扱う。2026-09-23 に実測）
- タブ名に issue 番号などの接頭辞を付けない。タイトルに何も付け足さない
- テストは本物の `herdr` を呼ばない。偽の `herdr` を `PATH` の先頭に置き、`HERDR_*` 環境変数は各テストで明示的に設定する（テストを走らせるペイン自体が herdr の中にあるため）
- コミットはパスを名指しする。新規ファイルは `git add -N -- <パス>` を1ファイルずつ行ってから `git commit -- <パス>...`。`git commit -a` と裸の `git commit` は使わない
- コミットメッセージの末尾に次の2行を付ける:
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_013oF3vFZ9dTLBBuZUffaEim`
- テストの実行は `bats dot_claude/hooks/<名前>.bats`（リポジトリのルートから）。pre-commit の shellcheck がコミット時に走る

## Review Focus

1. 利用者のプロンプト本文に `{"type":"ai-title","aiTitle":"偽"}` という文字列が含まれる → jsonl ではエスケープされた文字列の中にあるので、タイトルとして拾わない（Task 2 のテスト）
2. jsonl に JSON として壊れた行が混ざる（書き込み途中の最終行など） → 残りの行から ai-title を拾う（Task 2 のテスト）
3. `session_name` が `-` で始まる、空白や `"` や日本語を含む → 1つの引数のまま、変形されずに `herdr tab rename` へ渡る（Task 3 のテスト）
4. herdr の応答が遅い → statusline の表示は待たされない（Task 4 のテスト）
5. herdr の外（`HERDR_ENV` 無し）で動く Claude Code、または herdr が無いマシン → statusline の出力は従来と同じで、エラーも出ない（Task 3 と Task 4 のテスト）

---

### Task 1: custom-title の行の形を実機で確かめる（コントローラーが行う）

spec で未検証とした、`/rename` が jsonl に書く行の形を確かめる。
Task 2 の custom-title 判定はこの結果に依存する。
コードは書かない。

**Files:** なし

**Interfaces:**
- Produces: jsonl 上の custom-title の行の `type` の値。Task 2 は `custom-title` を前提に書いてある

- [ ] **Step 1: 使い捨てのタブを立てる**

```bash
test "${HERDR_ENV:-}" = 1
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr tab create --workspace "$HERDR_WORKSPACE_ID" --label "rename検証" \
  --cwd /home/yagu001/.local/share/chezmoi --no-focus
```

返った JSON の `.result.tab.tab_id` と `.result.root_pane.pane_id` を控える（以下 `<TAB>` と `<PANE>`）。
ラベルは `herdr tab list` の既存ラベルの表記に揃える。

- [ ] **Step 2: Claude Code を起動する**

```bash
herdr agent start titleprobe --kind claude --pane <PANE>
herdr agent get titleprobe
```

期待: `agent_status` が `idle`。

- [ ] **Step 3: 最初のプロンプトの前に `/rename` し、そのあと1回プロンプトを送る**

```bash
herdr agent prompt titleprobe "/rename 検証用の名前0923"
herdr agent read titleprobe --source recent-unwrapped --lines 20
herdr agent prompt titleprobe "OK とだけ返してください" --wait --timeout 120000
```

`/rename` はモデルを呼ばないので `--wait` を付けない。

- [ ] **Step 4: jsonl の行を読む**

```bash
SID=$(herdr pane get <PANE> | jq -r '.result.pane.agent_session.value')
J=~/.claude/projects/-home-yagu001--local-share-chezmoi/$SID.jsonl
grep -F '検証用の名前0923' "$J" | grep -v '"type":"user"' | cut -c1-300
```

期待: `{"type":"custom-title",...}` の形の行が1行以上ある。
`type` の値と、名前が入っているキー名を控える。

- [ ] **Step 5: 片付けて issue に記録する**

```bash
herdr tab close <TAB>
gh issue comment 11 --body "<Step 4 で見た行をそのまま貼り、type の値を書く>"
```

次のどちらかなら、ここで止めてリーダーに報告する。

- `type` が `custom-title` でない。Task 2 の判定文字列を変えることになるため
- 名前を含む行が1行も無い（最初のプロンプト前の `/rename` が jsonl に残らない）。spec で足した custom-title の判定では守れないことになり、設計を見直す必要があるため

---

### Task 2: 部品1 `session-title-promote.sh`

**Files:**
- Create: `dot_claude/hooks/executable_session-title-promote.sh`
- Test: `dot_claude/hooks/session-title-promote.bats`

**Interfaces:**
- Consumes: Task 1 で確かめた custom-title の行の `type` の値（`custom-title`）
- Produces: `~/.claude/hooks/session-title-promote.sh`。stdin にフックの入力 JSON を受ける。`UserPromptSubmit` で格上げするときだけ stdout に `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"<タイトル>"}}` を1行出す。印ファイルは `${TMPDIR:-/tmp}/claude-session-titled/<session_id>`（中身は空）

- [ ] **Step 1: 失敗するテストを書く**

`dot_claude/hooks/session-title-promote.bats`:

```bash
#!/usr/bin/env bats
# session-title-promote.sh のユニットテスト。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_session-title-promote.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    TRANSCRIPT="$TMPDIR_TEST/transcript.jsonl"
    : > "$TRANSCRIPT"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

marked() { # session_id
    [ -f "$TMPDIR_TEST/claude-session-titled/$1" ]
}

ss_input() { # session_id [session_title]
    if [ $# -ge 2 ]; then
        jq -nc --arg s "$1" --arg t "$2" \
            '{session_id:$s,hook_event_name:"SessionStart",source:"startup",session_title:$t}'
    else
        jq -nc --arg s "$1" '{session_id:$s,hook_event_name:"SessionStart",source:"startup"}'
    fi
}

ups_input() { # session_id [transcript_path]
    jq -nc --arg s "$1" --arg t "${2:-$TRANSCRIPT}" \
        '{session_id:$s,hook_event_name:"UserPromptSubmit",transcript_path:$t,prompt:"x"}'
}

add_ai_title() { # title
    jq -nc --arg t "$1" '{type:"ai-title",aiTitle:$t,sessionId:"sess"}' >> "$TRANSCRIPT"
}

@test "SessionStartでsession_titleあり -> 印を置き、stdoutは空" {
    run bash "$SCRIPT" <<< "$(ss_input sess-ss1 "付けた名前")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    marked sess-ss1
}

@test "SessionStartでsession_title無し -> 印を置かない" {
    run bash "$SCRIPT" <<< "$(ss_input sess-ss2)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-ss2
}

@test "UserPromptSubmitでai-titleが複数 -> 最後のaiTitleをsessionTitleとして出し、印を置く" {
    add_ai_title "古いタイトル"
    add_ai_title "新しいタイトル"
    run bash "$SCRIPT" <<< "$(ups_input sess-u1)"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "UserPromptSubmit" ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle')" = "新しいタイトル" ]
    marked sess-u1
}

@test "UserPromptSubmitで印あり -> 何も出さない" {
    add_ai_title "タイトル"
    mkdir -p "$TMPDIR_TEST/claude-session-titled"
    : > "$TMPDIR_TEST/claude-session-titled/sess-u2"
    run bash "$SCRIPT" <<< "$(ups_input sess-u2)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "UserPromptSubmitでcustom-titleの行あり -> 何も出さず、印を置く" {
    add_ai_title "自動のタイトル"
    jq -nc '{type:"custom-title",customTitle:"手で付けた名前",sessionId:"sess"}' >> "$TRANSCRIPT"
    run bash "$SCRIPT" <<< "$(ups_input sess-u3)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    marked sess-u3
}

@test "UserPromptSubmitでai-titleの行が無い -> 何も出さず、印も置かない" {
    jq -nc '{type:"user",message:{content:"こんにちは"}}' >> "$TRANSCRIPT"
    run bash "$SCRIPT" <<< "$(ups_input sess-u4)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-u4
}

@test "プロンプト本文にai-titleやcustom-titleの形の文字列 -> タイトルとして拾わない" {
    jq -nc '{type:"user",message:{content:"{\"type\":\"ai-title\",\"aiTitle\":\"偽\"} {\"type\":\"custom-title\"}"}}' >> "$TRANSCRIPT"
    run bash "$SCRIPT" <<< "$(ups_input sess-u5)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-u5
}

@test "壊れた行が混ざる -> 残りの行からai-titleを拾う" {
    add_ai_title "正しいタイトル"
    printf '%s\n' '{"type":"ai-title","aiTitle":"書きかけ' >> "$TRANSCRIPT"
    run bash "$SCRIPT" <<< "$(ups_input sess-u6)"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle')" = "正しいタイトル" ]
}

@test "タイトルに引用符やバックスラッシュ -> 出力が妥当なJSONで値が元のまま" {
    add_ai_title 'say "hi" \ 日本語'
    run bash "$SCRIPT" <<< "$(ups_input sess-u7)"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.sessionTitle')" = 'say "hi" \ 日本語' ]
}

@test "transcript_pathが存在しない -> exit 0、出力なし、印なし" {
    run bash "$SCRIPT" <<< "$(ups_input sess-u8 "$TMPDIR_TEST/nope.jsonl")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    ! marked sess-u8
}

@test "壊れた入力JSON -> exit 0、出力なし" {
    run bash "$SCRIPT" <<< 'not json'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "session_idにパストラバーサル -> 印のディレクトリ外に副作用なし" {
    add_ai_title "タイトル"
    run bash "$SCRIPT" <<< "$(ups_input '../evil')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$TMPDIR_TEST/evil" ]
}
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `bats dot_claude/hooks/session-title-promote.bats`
Expected: FAIL（スクリプトが無いので、出力を期待するテストと印を期待するテストが落ちる）

- [ ] **Step 3: 実装する**

`dot_claude/hooks/executable_session-title-promote.sh`:

```bash
#!/bin/bash
# SessionStart / UserPromptSubmit hook: 自動生成のセッションタイトル（ai-title）を
# custom-title へ格上げし、入力欄の枠のチップに出す（haoblackj/dotfiles#11）。
#
# チップは custom-title しか表示しない。ai-title を渡すフックの入力欄は無いので、
# transcript の jsonl にある {"type":"ai-title","aiTitle":...} の最後の行を読む。
# jsonl の形式は内部仕様でバージョンごとに変わりうるため、読めなければ何もしない。
#
# 一度名前を付けたセッションには印（${TMPDIR:-/tmp}/claude-session-titled/<session_id>）
# を置き、二度は付けない。利用者が付けた名前を上書きしないよう、次の2つでも印を置く。
#   SessionStart:      入力の session_title がある（claude -n、名前付きセッションの resume）
#   UserPromptSubmit:  jsonl に custom-title の行がある（最初のプロンプト前の /rename）
#
# fail-open: 常に exit 0。

set -uo pipefail

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# session_id は英数字・ドット・アンダースコア・ハイフンのみ許可(パストラバーサル対策)。
[[ -z "$SESSION_ID" || ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]] && exit 0

MARK_DIR="${TMPDIR:-/tmp}/claude-session-titled"
MARK="$MARK_DIR/$SESSION_ID"

mark() {
  mkdir -p "$MARK_DIR" 2>/dev/null && : > "$MARK" 2>/dev/null
}

# jsonl から指定した type の行だけを取り出す。grep で候補を絞ってから jq で type を
# 確かめる。本文中の同じ文字列はエスケープされているので grep の段で外れ、
# 書きかけの壊れた行は fromjson? で読み飛ばす。
records_of_type() { # $1 = type, $2 = transcript path
  grep -F "\"$1\"" "$2" 2>/dev/null |
    jq -c -R --arg t "$1" 'fromjson? | select(type == "object" and .type == $t)' 2>/dev/null
}

case "$EVENT" in
  SessionStart)
    TITLE=$(printf '%s' "$INPUT" | jq -r '.session_title // empty' 2>/dev/null)
    [[ -n "$TITLE" ]] && mark
    ;;
  UserPromptSubmit)
    [[ -f "$MARK" ]] && exit 0
    TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
    [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || exit 0
    if [[ -n "$(records_of_type custom-title "$TRANSCRIPT" | head -n1)" ]]; then
      mark
      exit 0
    fi
    AI_TITLE=$(records_of_type ai-title "$TRANSCRIPT" | tail -n1 | jq -r '.aiTitle // empty' 2>/dev/null)
    [[ -n "$AI_TITLE" ]] || exit 0
    jq -nc --arg t "$AI_TITLE" \
      '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",sessionTitle:$t}}' && mark
    ;;
esac
exit 0
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bats dot_claude/hooks/session-title-promote.bats`
Expected: 12 tests, 0 failures

- [ ] **Step 5: コミットする**

```bash
git add -N -- dot_claude/hooks/executable_session-title-promote.sh
git add -N -- dot_claude/hooks/session-title-promote.bats
git commit -F - -- dot_claude/hooks/executable_session-title-promote.sh dot_claude/hooks/session-title-promote.bats <<'EOF'
feat(hooks): 自動タイトルを custom-title に格上げするフックを追加

transcript の最新の ai-title を UserPromptSubmit の sessionTitle として返し、
入力欄のチップに出す。利用者が付けた名前は上書きしない。

Refs #11

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013oF3vFZ9dTLBBuZUffaEim
EOF
```

---

### Task 3: 部品2 `herdr-tab-title-sync.sh`

**Files:**
- Create: `dot_claude/hooks/executable_herdr-tab-title-sync.sh`
- Test: `dot_claude/hooks/herdr-tab-title-sync.bats`

**Interfaces:**
- Produces: `~/.claude/hooks/herdr-tab-title-sync.sh`。stdin に statusline の入力 JSON を受ける。stdout には何も出さない。環境変数 `HERDR_ENV`、`HERDR_TAB_ID`、`HERDR_PANE_ID` を読む。前回値は `${TMPDIR:-/tmp}/herdr-tab-title/<HERDR_PANE_ID>`（中身は改行なしの `session_name`）。Task 4 がこのファイル名で呼ぶ

- [ ] **Step 1: 失敗するテストを書く**

`dot_claude/hooks/herdr-tab-title-sync.bats`:

```bash
#!/usr/bin/env bats
# herdr-tab-title-sync.sh のユニットテスト。本物の herdr は呼ばない。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_herdr-tab-title-sync.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"

    # 偽の herdr。呼ばれるたびに引数を | 区切りで1行記録する。
    #   tab get    -> FAKE_TAB_GET があればそれを、無ければ pane_count=FAKE_PANE_COUNT の JSON を返す
    #   tab rename -> FAKE_RENAME_FAIL=1 なら exit 1
    FAKE_BIN="$TMPDIR_TEST/fakebin"
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/herdr" <<'EOS'
#!/bin/bash
{ printf '%s|' "$@"; printf '\n'; } >> "$HERDR_LOG"
if [ "$1" = tab ] && [ "$2" = get ]; then
  if [ -n "${FAKE_TAB_GET+x}" ]; then
    printf '%s' "$FAKE_TAB_GET"
  else
    printf '{"id":"cli:tab:get","result":{"tab":{"pane_count":%s,"tab_id":"%s"},"type":"tab_info"}}' \
      "${FAKE_PANE_COUNT:-1}" "$3"
  fi
  exit 0
fi
if [ "$1" = tab ] && [ "$2" = rename ]; then
  [ "${FAKE_RENAME_FAIL:-0}" = 1 ] && exit 1
  exit 0
fi
exit 2
EOS
    chmod +x "$FAKE_BIN/herdr"
    export PATH="$FAKE_BIN:$PATH"

    export HERDR_LOG="$TMPDIR_TEST/herdr.log"
    : > "$HERDR_LOG"
    export HERDR_ENV=1
    export HERDR_TAB_ID="w1:t1"
    export HERDR_PANE_ID="w1:p1"
    unset FAKE_TAB_GET FAKE_PANE_COUNT FAKE_RENAME_FAIL
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

input_with_name() { # session_name
    jq -nc --arg n "$1" '{session_id:"sess",session_name:$n}'
}

state_of() { # pane_id
    cat "$TMPDIR_TEST/herdr-tab-title/$1" 2>/dev/null || echo ''
}

@test "HERDR_ENVが無い -> herdrを呼ばない" {
    unset HERDR_ENV
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}

@test "HERDR_TAB_IDが空 -> herdrを呼ばない" {
    export HERDR_TAB_ID=""
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}

@test "session_nameが無い -> herdrを呼ばない" {
    run bash "$SCRIPT" <<< '{"session_id":"sess"}'
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}

@test "pane_countが1 -> tab renameが呼ばれ、前回値を記録する。stdoutは空" {
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -qxF 'tab|rename|w1:t1|タイトル|' "$HERDR_LOG"
    [ "$(state_of w1:p1)" = "タイトル" ]
}

@test "同じsession_nameで2回目 -> herdrを呼ばない" {
    bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    : > "$HERDR_LOG"
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}

@test "session_nameが変わった -> もう一度renameする" {
    bash "$SCRIPT" <<< "$(input_with_name "前のタイトル")"
    run bash "$SCRIPT" <<< "$(input_with_name "次のタイトル")"
    grep -qxF 'tab|rename|w1:t1|次のタイトル|' "$HERDR_LOG"
    [ "$(state_of w1:p1)" = "次のタイトル" ]
}

@test "pane_countが2 -> renameを呼ばず、前回値も記録しない" {
    export FAKE_PANE_COUNT=2
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    ! grep -q '^tab|rename|' "$HERDR_LOG"
    [ "$(state_of w1:p1)" = "" ]
}

@test "tab getがJSONを返さない -> renameを呼ばない" {
    export FAKE_TAB_GET="not json"
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    ! grep -q '^tab|rename|' "$HERDR_LOG"
}

@test "renameが失敗 -> 前回値を記録しない、exit 0" {
    export FAKE_RENAME_FAIL=1
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    [ "$(state_of w1:p1)" = "" ]
}

@test "session_nameが-で始まる、空白や引用符を含む -> 1引数のまま変形されずに渡る" {
    name='-x "引用" と 空白'
    run bash "$SCRIPT" <<< "$(input_with_name "$name")"
    [ "$status" -eq 0 ]
    grep -qxF "tab|rename|w1:t1|$name|" "$HERDR_LOG"
}

@test "HERDR_PANE_IDにパストラバーサル -> 記録ディレクトリ外に副作用なし、herdrを呼ばない" {
    for bad in '../evil' '..' 'w1/p1'; do
        export HERDR_PANE_ID="$bad"
        run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
        [ "$status" -eq 0 ]
    done
    [ ! -e "$TMPDIR_TEST/evil" ]
    [ ! -s "$HERDR_LOG" ]
}

@test "herdrがPATHに無い -> exit 0、stdoutは空" {
    # jq だけを通した PATH にする。jq まで消すと session_name を読む段で抜けてしまい、
    # herdr が無い経路を通らない。
    mkdir -p "$TMPDIR_TEST/onlyjq"
    ln -s "$(command -v jq)" "$TMPDIR_TEST/onlyjq/jq"
    export PATH="$TMPDIR_TEST/onlyjq:/usr/bin:/bin"
    ! command -v herdr
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "壊れた入力JSON -> herdrを呼ばない" {
    run bash "$SCRIPT" <<< 'not json'
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `bats dot_claude/hooks/herdr-tab-title-sync.bats`
Expected: FAIL（rename と前回値を期待するテストが落ちる）

- [ ] **Step 3: 実装する**

`dot_claude/hooks/executable_herdr-tab-title-sync.sh`:

```bash
#!/bin/bash
# herdr のタブ名を、そのタブで動く Claude Code の session_name に揃える
# （haoblackj/dotfiles#11）。statusline-context-window.sh がバックグラウンドで呼ぶ。
#
# herdr はタブ名をターミナルタイトルへ追従させる機能を持たない（herdrdev/herdr#4359 は
# not_planned）。statusline の入力の session_name は custom-title があればそれ、
# 無ければ ai-title なので、/rename にもそのまま追従する。
#
# 値が変わったときだけ rename する。前回値は ${TMPDIR:-/tmp}/herdr-tab-title/<pane_id>
# に置き、rename が成功したときだけ書く。statusline の実行が打ち切られても、
# 次の実行で書き直せる。herdr 側で手で付けたタブ名は、次に session_name が変わるまで残る。
#
# 1つのタブに複数のペインがあるときは、どのセッション名を使うか決まらないので何もしない。
# herdr tab rename はタブIDより後ろの引数をすべてラベルとして扱い、-- も文字どおり
# ラベルに入る（0.9.1 で実測）。ラベルは1引数で渡し、-- を挟まない。
#
# fail-open: 常に exit 0。stdout には何も出さない。

set -uo pipefail

[[ "${HERDR_ENV:-}" == 1 ]] || exit 0

TAB_ID="${HERDR_TAB_ID:-}"
PANE_ID="${HERDR_PANE_ID:-}"
# herdr の ID（w9:p6 の形）以外は受け付けない（パストラバーサル対策）。
valid_id() { [[ "$1" =~ ^[A-Za-z0-9:._-]+$ && "$1" != *..* ]]; }
valid_id "$TAB_ID" && valid_id "$PANE_ID" || exit 0

NAME=$(jq -r '.session_name // empty' 2>/dev/null) || exit 0
[[ -n "$NAME" ]] || exit 0

STATE_DIR="${TMPDIR:-/tmp}/herdr-tab-title"
STATE="$STATE_DIR/$PANE_ID"
[[ -f "$STATE" && "$(cat -- "$STATE" 2>/dev/null)" == "$NAME" ]] && exit 0

PANE_COUNT=$(herdr tab get "$TAB_ID" 2>/dev/null | jq -r '.result.tab.pane_count // empty' 2>/dev/null)
[[ "$PANE_COUNT" == 1 ]] || exit 0

herdr tab rename "$TAB_ID" "$NAME" >/dev/null 2>&1 || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s' "$NAME" > "$STATE" 2>/dev/null
exit 0
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bats dot_claude/hooks/herdr-tab-title-sync.bats`
Expected: 13 tests, 0 failures

- [ ] **Step 5: コミットする**

```bash
git add -N -- dot_claude/hooks/executable_herdr-tab-title-sync.sh
git add -N -- dot_claude/hooks/herdr-tab-title-sync.bats
git commit -F - -- dot_claude/hooks/executable_herdr-tab-title-sync.sh dot_claude/hooks/herdr-tab-title-sync.bats <<'EOF'
feat(hooks): herdr のタブ名を session_name に揃えるスクリプトを追加

statusline の入力の session_name が変わったときだけ herdr tab rename を呼ぶ。
複数ペインのタブと herdr の外では何もしない。

Refs #11

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013oF3vFZ9dTLBBuZUffaEim
EOF
```

---

### Task 4: statusline から部品2を呼ぶ

**Files:**
- Modify: `dot_claude/hooks/executable_statusline-context-window.sh`（冒頭コメントと `INPUT=$(cat)` の直後）
- Test: `dot_claude/hooks/statusline-context-window.bats`

**Interfaces:**
- Consumes: Task 3 の `herdr-tab-title-sync.sh`（statusline のスクリプトと同じディレクトリにある前提。stdin に入力 JSON、stdout なし）

- [ ] **Step 1: 失敗するテストを書く**

`dot_claude/hooks/statusline-context-window.bats` の `setup()` の末尾（`export PATH="$FAKE_BIN:$PATH"` の直後）に次を足す。
テストを走らせるペインが herdr の中にあっても、既存のテストが本物の herdr の環境変数を引き継がないようにするためである。

```bash
    unset HERDR_ENV HERDR_TAB_ID HERDR_PANE_ID
```

ファイルの末尾に次を足す。

```bash
# 以下は herdr のタブ名同期（haoblackj/dotfiles#11）の統合テスト。
# ソースでは2本とも executable_ 付きの名前なので、ターゲットの名前で一時ディレクトリへ写し、
# statusline のスクリプトが同じディレクトリの herdr-tab-title-sync.sh を呼べるようにする。
install_hooks_as_target() {
    HOOKS="$TMPDIR_TEST/hooks"
    mkdir -p "$HOOKS"
    cp "$BATS_TEST_DIRNAME/executable_statusline-context-window.sh" "$HOOKS/statusline-context-window.sh"
    cp "$BATS_TEST_DIRNAME/executable_herdr-tab-title-sync.sh" "$HOOKS/herdr-tab-title-sync.sh"

    # 偽の herdr。引数を | 区切りで1行記録する。FAKE_HERDR_DELAY 秒だけ tab get を遅らせる。
    cat > "$FAKE_BIN/herdr" <<'EOS'
#!/bin/bash
if [ "$1" = tab ] && [ "$2" = get ]; then
  sleep "${FAKE_HERDR_DELAY:-0}"
  printf '{"result":{"tab":{"pane_count":1}}}'
fi
{ printf '%s|' "$@"; printf '\n'; } >> "$HERDR_LOG"
exit 0
EOS
    chmod +x "$FAKE_BIN/herdr"
    export HERDR_LOG="$TMPDIR_TEST/herdr.log"
    : > "$HERDR_LOG"
    export HERDR_ENV=1 HERDR_TAB_ID="w1:t1" HERDR_PANE_ID="w1:p1"
}

wait_for_rename() { # 上限5秒
    local i
    for i in $(seq 50); do
        grep -q '^tab|rename|' "$HERDR_LOG" && return 0
        sleep 0.1
    done
    return 1
}

@test "herdrの中 -> stdoutは入力のまま通り、バックグラウンドでtab renameが呼ばれる" {
    install_hooks_as_target
    input='{"session_id":"sess-h1","session_name":"同期するタイトル"}'
    run bash "$HOOKS/statusline-context-window.sh" <<< "$input"
    [ "$status" -eq 0 ]
    [ "$output" = "$input" ]
    wait_for_rename
    grep -qxF 'tab|rename|w1:t1|同期するタイトル|' "$HERDR_LOG"
}

@test "herdrの応答が遅い -> statuslineは待たずに返る" {
    install_hooks_as_target
    export FAKE_HERDR_DELAY=3
    input='{"session_id":"sess-h2","session_name":"遅いherdr"}'
    start=$(date +%s%N)
    run bash "$HOOKS/statusline-context-window.sh" <<< "$input"
    elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
    [ "$status" -eq 0 ]
    [ "$output" = "$input" ]
    [ "$elapsed_ms" -lt 2000 ]
    # teardown が一時ディレクトリを消した後に子が書き込まないよう、終わるのを待つ。
    wait_for_rename
}

@test "herdrの外 -> herdrを呼ばず、stdoutは入力のまま" {
    install_hooks_as_target
    unset HERDR_ENV
    input='{"session_id":"sess-h3","session_name":"外"}'
    run bash "$HOOKS/statusline-context-window.sh" <<< "$input"
    [ "$status" -eq 0 ]
    [ "$output" = "$input" ]
    sleep 0.3
    [ ! -s "$HERDR_LOG" ]
}

@test "herdr-tab-title-sync.shが無い -> stdoutは入力のまま、stderrも空" {
    install_hooks_as_target
    rm -f -- "$HOOKS/herdr-tab-title-sync.sh"
    input='{"session_id":"sess-h4","session_name":"無い"}'
    run --separate-stderr bash "$HOOKS/statusline-context-window.sh" <<< "$input"
    [ "$status" -eq 0 ]
    [ "$output" = "$input" ]
    [ -z "$stderr" ]
}
```

`run --separate-stderr` は bats 1.5 以降の機能で、`bats_require_minimum_version` を求める警告が出る。
ファイル冒頭の `set -u` の直後に次を足す。

```bash
bats_require_minimum_version 1.5.0
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `bats dot_claude/hooks/statusline-context-window.bats`
Expected: 既存10件は PASS、新しい4件のうち「tab renameが呼ばれる」と「応答が遅い」が FAIL（まだ呼んでいないので `wait_for_rename` が落ちる）

- [ ] **Step 3: 実装する**

`dot_claude/hooks/executable_statusline-context-window.sh` の冒頭コメントの末尾（`# session_id は既存hookと同じ正規表現でパストラバーサル対策する。` の直後）に次を足す。

```bash
#
# herdr のタブ名の同期（haoblackj/dotfiles#11）は herdr-tab-title-sync.sh に任せ、
# 入力JSONを渡してバックグラウンドで呼ぶ。stdout と stderr を捨てるのは、子が
# 表示のパイプを握ったままにならないようにするため。握ったままだと Claude Code が
# パイプの終端を待ち、表示が遅れる。
```

`INPUT=$(cat)` の直後に次を足す。

```bash

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s' "$INPUT" | bash "$HOOK_DIR/herdr-tab-title-sync.sh" >/dev/null 2>&1 &
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bats dot_claude/hooks/statusline-context-window.bats`
Expected: 14 tests, 0 failures

- [ ] **Step 5: コミットする**

```bash
git commit -F - -- dot_claude/hooks/executable_statusline-context-window.sh dot_claude/hooks/statusline-context-window.bats <<'EOF'
feat(statusline): herdr のタブ名同期をバックグラウンドで呼ぶ

statusline の表示を待たせないよう、出力を捨てて herdr-tab-title-sync.sh を
バックグラウンドで起動する。

Refs #11

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013oF3vFZ9dTLBBuZUffaEim
EOF
```

---

### Task 5: 部品3 設定の配線

**Files:**
- Modify: `linked/claude/settings.json`
- Test: `dot_claude/hooks/settings-wiring.bats`

**Interfaces:**
- Consumes: Task 2 の `~/.claude/hooks/session-title-promote.sh`

`settings-wiring.bats` は `setup()` で `S=~/.local/share/chezmoi/linked/claude/settings.json`（本体のチェックアウト）を読む。
ワークツリーで走らせると本体のファイルを見てしまうので、この Task のテストは `setup()` を書き換えずに、ワークツリーのルートで次のように上書きして走らせる。

```bash
S_OVERRIDE="$PWD/linked/claude/settings.json" bats dot_claude/hooks/settings-wiring.bats
```

そのために `setup()` を次の形に変える（既定値は従来どおり）。

```bash
setup() {
    S="${S_OVERRIDE:-$HOME/.local/share/chezmoi/linked/claude/settings.json}"
}
```

- [ ] **Step 1: 失敗するテストを書く**

`dot_claude/hooks/settings-wiring.bats` の `setup()` を上の形に変え、末尾に次を足す。

```bash
# bats test_tags=production-asset
@test "languageがjapanese(自動タイトルを日本語に固定する。haoblackj/dotfiles#11)" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("language")=="japanese", "language!=japanese"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "session-title-promote.shがSessionStartとUserPromptSubmitの両方に配線されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
def cmds(ev): return " ".join(x.get("command","") for g in h.get(ev,[]) for x in g.get("hooks",[]))
assert "session-title-promote.sh" in cmds("SessionStart"), "SessionStart に無い"
assert "session-title-promote.sh" in cmds("UserPromptSubmit"), "UserPromptSubmit に無い"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "statusLineは従来どおりstatusline-context-window.shを指す" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert "statusline-context-window.sh" in d.get("statusLine",{}).get("command",""), "statusLine が変わっている"
print("PASS")
PY
}
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `S_OVERRIDE="$PWD/linked/claude/settings.json" bats dot_claude/hooks/settings-wiring.bats`
Expected: 既存10件と statusLine の1件は PASS、language と配線の2件が FAIL

- [ ] **Step 3: 設定を足す**

`linked/claude/settings.json` のトップレベルに `"language": "japanese",` を足す（`"env": {` の直前）。
キーの順序は git の clean filter が揃えるので、置く位置は結果に影響しない。

`hooks.SessionStart` の配列の末尾（`herdr-agent-state.sh` のグループの後ろ）に次のグループを足す。

```json
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/hooks/session-title-promote.sh\""
          }
        ]
      }
```

`hooks.UserPromptSubmit` の配列の末尾（`memory_recall.py` のグループの後ろ）に同じグループを足す。

足したあと JSON として読めることを確かめる。

Run: `jq -e '.language == "japanese"' linked/claude/settings.json`
Expected: `true`

- [ ] **Step 4: テストが通ることを確かめる**

Run: `S_OVERRIDE="$PWD/linked/claude/settings.json" bats dot_claude/hooks/settings-wiring.bats`
Expected: 13 tests, 0 failures

リポジトリ全体の bats も通ることを確かめる（pre-push と同じ範囲）。

Run: `bats -r dot_claude`
Expected: 落ちるのは settings-wiring.bats の language と配線の2件だけ。この実行では `S_OVERRIDE` が無く本体のチェックアウトを読むので、この2件は本体に取り込むまで落ちる（Task 6 の Step 1 で 0 failures を確かめる）

- [ ] **Step 5: コミットする**

```bash
git commit -F - -- linked/claude/settings.json dot_claude/hooks/settings-wiring.bats <<'EOF'
feat(settings): 自動タイトルの格上げフックと language を配線する

language を japanese に固定し、session-title-promote.sh を SessionStart と
UserPromptSubmit に登録する。statusLine の登録は変えない。

Refs #11

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013oF3vFZ9dTLBBuZUffaEim
EOF
```

---

### Task 6: 本体へ取り込んだあと実機で確かめる（コントローラーが行う）

superpowers:finishing-a-development-branch でリーダーが取り込み方を選び、main に入ったあとに行う。
`~/.claude/settings.json` は本体のチェックアウトへの symlink なので、main に入った時点でフックの登録が効く。
スクリプトは `chezmoi apply` で配る。

配った直後から、herdr の中で動くすべての1ペインのタブで、次の statusline の実行時にタブ名がセッション名へ書き換わる。
手で付けたタブ名（`#31 設計` など）も一度は上書きされる。
これは issue #11 の決定（タブ名はセッションタイトルそのまま）どおりの挙動である。

**Files:** なし

- [ ] **Step 1: 配る**

```bash
cd /home/yagu001/.local/share/chezmoi
git pull --ff-only
chezmoi diff ~/.claude/hooks
chezmoi apply ~/.claude/hooks
ls -l ~/.claude/hooks/session-title-promote.sh ~/.claude/hooks/herdr-tab-title-sync.sh
bats -r dot_claude
```

期待: 2本が実行権限付きで置かれ、bats が 0 failures。

- [ ] **Step 2: 検証用のタブで新しいセッションを立てる**

```bash
herdr tab create --workspace "$HERDR_WORKSPACE_ID" --label "タイトル同期検証" \
  --cwd /home/yagu001/.local/share/chezmoi --no-focus
herdr agent start titlecheck --kind claude --pane <PANE>
herdr agent get titlecheck
```

- [ ] **Step 3: プロンプトを2回送り、チップとタブ名を確かめる**

```bash
herdr agent prompt titlecheck "README.md の最初の見出しを1行で答えてください" --wait --timeout 180000
herdr agent prompt titlecheck "ありがとう、それだけで大丈夫です" --wait --timeout 180000
SID=$(herdr pane get <PANE> | jq -r '.result.pane.agent_session.value')
J=~/.claude/projects/-home-yagu001--local-share-chezmoi/$SID.jsonl
grep -F '"ai-title"' "$J" | tail -n1 | cut -c1-200
grep -F '"custom-title"' "$J" | tail -n1 | cut -c1-200
timeout 60 bash -c 'until herdr tab get <TAB> | jq -e ".result.tab.label != \"タイトル同期検証\"" >/dev/null; do sleep 2; done'
herdr tab get <TAB> | jq -r .result.tab.label
herdr agent read titlecheck --source visible --lines 10
```

期待: custom-title の行が ai-title と同じタイトルで出ている。
タブのラベルがそのタイトルに変わっている。
画面の入力欄の枠にタイトルのチップが出ている。

- [ ] **Step 4: `/rename` にタブ名が追従することを確かめる**

```bash
herdr agent prompt titlecheck "/rename 追従の確認"
herdr agent prompt titlecheck "OK とだけ返してください" --wait --timeout 120000
timeout 60 bash -c 'until [ "$(herdr tab get <TAB> | jq -r .result.tab.label)" = "追従の確認" ]; do sleep 2; done'
herdr tab get <TAB> | jq -r .result.tab.label
```

期待: `追従の確認`。

- [ ] **Step 5: 片付けて issue に記録する**

```bash
herdr tab close <TAB>
gh issue comment 11 --body "<Step 3 と Step 4 で見たラベルと jsonl の行を貼り、実機で確かめた結果を書く>"
```
