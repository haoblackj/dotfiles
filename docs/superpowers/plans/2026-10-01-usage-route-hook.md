# 利用枠の見張りと振り分けのフック Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CodexBar の `serve` を常駐させ、PostToolUse のフックが Claude と Codex の利用枠から振り先を決めて、変わったときだけ Claude に知らせる。Claude の週枠が尽きたときは、2段階で強制的に止める。

**Architecture:** 値とペースは CodexBar（`codexbar serve`、systemd のユーザーサービス）が持ち、キャッシュも CodexBar に任せる。フック（`~/.claude/hooks/usage-route.sh`）は `curl -m 2` で `/usage?provider=both` を読み、しきい値で振り先を決め、セッションごとの状態ファイルと比べて変化を知らせる。読めないときは黙る。

**Tech Stack:** bash、jq、curl、bats、systemd（ユーザー）、Homebrew（`steipete/tap/codexbar` v0.70.0）

**Spec:** https://github.com/haoblackj/dotfiles/issues/14 （本文、2026-09-30 の決定、2026-10-01 の実機確認と3つの決定、訂正）

## Global Constraints

- 振り分けの規則: 両方に余裕があれば、実装は Codex、レビューは Claude。Codex だけ尽きたら、実装も Claude。Claude が尽きたら止める。
- 5時間枠のしきい値は 85%（Claude、Codex とも）。
- 週枠は `pace.secondary.deltaPercent` が 25 以上、または週枠の使用率が 90% 以上で「尽きた」とする（Claude、Codex とも）。`willLastToReset` は使わない。
- Claude の5時間枠で止める側になったときは、知らせるだけにする（`additionalContext`）。`continue: false` で強制的に打ち切らない。
- Claude の週枠で止める側になったときは2段階: 最初に `additionalContext` で知らせ、そのあともツールの呼び出しが続いたら、数回目で `"continue": false` と `stopReason` を返して打ち切る。
- CodexBar の Claude の取得元は `oauth` に固定する（`auto` と `cli` は WSL で timed out になる。実測）。
- `serve` は `127.0.0.1:8080`、`--refresh-interval` は 300（キャッシュの寿命の秒数）。
- フックは `curl -m 2` で読み、読めないとき（サーバー停止、エラー、Claude の取得失敗）は何も出さず exit 0。Codex だけ読めないときは Claude の判定（5時間枠、週枠）だけをし、Claude に余裕があれば振り先を変えない（2026-10-01 の決定）。ただし直前が Claude の枠で止める側なら、claude-only に切り替えて知らせる（2026-10-01 の決定）。作業を止めない。
- キャッシュは自作しない。定期ジョブ（CronCreate）は使わない。
- Codex の無料リセットの権利は、リーダーの許可なく使わない（CLAUDE.md に書く）。
- フックはクラウドへ配らない（`install-cloud.sh` は hooks を写さない）。CLAUDE.md はクラウドへ配られるので、クラウドの読み替えに1句足す。
- コメントと文書は日本語。グローバル CLAUDE.md の「文章の作法」に従う。
- コミットはパスを名指しする（`git commit -- <パス>`、新規ファイルは1つずつ `git add -N -- <パス>`）。`git commit -a` と裸の `git commit` は使わない。コミットメッセージの本文に `Refs #14` を入れ、末尾にセッションの指示どおりの Co-Authored-By と Claude-Session の行を付ける。

## プランで決めたこと（リーダーの確認が要る）

issue では「実装のときに決める」とした2点を、次のとおりに置いた。

1. 強制的に打ち切るのは、知らせたあとの5回目のツール呼び出し。Claude が issue に状態を書く（`gh issue comment` と `gh issue edit` で2〜3回）余裕を残す。数はフックの変数 `FORCE_AFTER` で変えられる。
2. 打ち切りは、週枠で止める側に入るたびに1回だけ。打ち切ったあと、リーダーが「続けて」と再開したら、同じ状態の間は再び打ち切らない（リーダーの判断で続ける余地を残す）。振り先がいったん別へ変わり、また週枠で止める側に入ったら、もう一度2段階が動く。

## File Structure

| ファイル | 役割 |
|---|---|
| `run_once_80_cli-tools.sh.tmpl`（変更） | Brewfile に `tap "steipete/tap"` と `brew "steipete/tap/codexbar"` を足す |
| `dot_config/codexbar/private_config.json`（新規） | CodexBar の設定。Claude の source を `oauth` に固定 |
| `dot_config/systemd/user/codexbar-serve.service`（新規） | `codexbar serve` の常駐 |
| `run_once_after_87_codexbar-serve.sh.tmpl`（新規） | unit を enable して起動する |
| `dot_claude/hooks/executable_usage-route.sh`（新規） | 判定と通知のフック |
| `dot_claude/hooks/usage-route.bats`（新規） | フックの単体テスト |
| `linked/claude/settings.json`（変更） | PostToolUse に全ツールで配線 |
| `dot_claude/hooks/settings-wiring.bats`（変更） | 配線のテストを1件足す |
| `dot_claude/CLAUDE.md`（変更） | 「委譲と情報の流通」に3行、クラウドの読み替えに1句 |
| `README.md`（変更） | systemd の行と run_once の表に1行ずつ |

## Review Focus

- `serve` が応答しないまま固まる: `curl -m 2` で2秒で打ち切り、何も出さずに exit 0（Task 2 のテスト「応答しないサーバー」）。
- Codex のエントリーが複数ある（CodexBar は見えている Codex のアカウントを全部返す）: 先頭の1件で判定する（Task 2 のテスト「Codex が2件」）。
- どちらかの provider が `error` を返す（Claude の OAuth のトークン切れなど）: 振り先を変えず、状態ファイルも書き換えない（Task 2 のテスト「Claude がエラー」）。
- `pace.secondary` が無い（週の頭や、ペースを出せない状態）: ペースの条件は偽として扱い、使用率 90% だけで判定する（Task 2 のテスト「pace が無い」）。
- 並列のサブエージェントが同時に状態ファイルを書く: 一時ファイルから `mv` で置き換え、書きかけを読ませない（Task 2 の実装。数え漏れは許す）。

---

### Task 1: CodexBar の導入と `serve` の常駐

**Files:**
- Modify: `run_once_80_cli-tools.sh.tmpl`
- Create: `dot_config/codexbar/private_config.json`
- Create: `dot_config/systemd/user/codexbar-serve.service`
- Create: `run_once_after_87_codexbar-serve.sh.tmpl`
- Modify: `README.md`（17行目の systemd の行、134行目付近の run_once の表）

**Interfaces:**
- Produces: `http://127.0.0.1:8080/usage?provider=both` が、`provider` が `codex` と `claude` のエントリーを持つ JSON の配列を返す。各エントリーは `usage.primary.usedPercent`、`usage.secondary.usedPercent`、`usage.primary.resetsAt`、`usage.secondary.resetsAt`、`pace.secondary.deltaPercent`、失敗時は `error.message` を持つ。

- [ ] **Step 1: Brewfile に足す**

`run_once_80_cli-tools.sh.tmpl` の `brew bundle install ... <<'BREWFILE'` の直後（`brew "aicommit2"` の前）に tap を、アルファベット順の位置（bitwarden-cli の `{{ end -}}` の次、`brew "ffmpeg"` の前）に本体を足す。

```
tap "steipete/tap"    # codexbar の配布元
```

```
brew "steipete/tap/codexbar" # Claude と Codex の利用枠を JSON で返す（usage-route.sh が serve を読む）
```

- [ ] **Step 2: CodexBar の設定を書く**

`dot_config/codexbar/private_config.json`:

```json
{
  "version": 1,
  "providers": [
    { "id": "codex", "enabled": true, "source": "auto" },
    { "id": "claude", "enabled": true, "source": "oauth" }
  ]
}
```

- [ ] **Step 3: 設定を検証する**

Run: `CODEXBAR_CONFIG=$PWD/dot_config/codexbar/private_config.json codexbar config validate`
Expected: `Config: OK`

- [ ] **Step 4: unit を書く**

`dot_config/systemd/user/codexbar-serve.service`:

```ini
[Unit]
Description=CodexBar usage server for Claude Code hooks (haoblackj/dotfiles#14)

[Service]
Type=simple
# usage-route.sh が PostToolUse のたびに読む。--refresh-interval はキャッシュの寿命の秒数で、
# 期限が切れても直前の値をすぐ返して裏で取り直す（CodexBar の docs/cli.md）。
Environment=PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/linuxbrew/.linuxbrew/bin/codexbar serve --host 127.0.0.1 --port 8080 --refresh-interval 300
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

- [ ] **Step 5: unit を検証する**

Run: `systemd-analyze --user verify dot_config/systemd/user/codexbar-serve.service`
Expected: 出力なし、exit 0

- [ ] **Step 6: enable するスクリプトを書く**

`run_once_after_87_codexbar-serve.sh.tmpl`:

```bash
#!/bin/bash
set -eu

# codexbar serve を常駐させる（haoblackj/dotfiles#14）。unit は dot_config/systemd/user/ が配り、
# codexbar 本体は run_once_80 の Brewfile が入れる。after にして、unit が配られた後に走らせる。
systemctl --user daemon-reload
systemctl --user enable --now codexbar-serve
```

Run: `chezmoi execute-template < run_once_after_87_codexbar-serve.sh.tmpl | bash -n && echo OK`
Expected: `OK`

- [ ] **Step 7: README を直す**

17行目の表の行を次に置き換える。

```
| systemd user unit | `dot_config/systemd/user/` | Bitwarden SSH agent ブリッジ、herdr の umask override、CodexBar の usage サーバー（`codexbar-serve`） |
```

134行目の `run_once_99_services` の行の直前に足す。

```
| `run_once_after_87_codexbar-serve` | `codexbar-serve`（利用枠の JSON を返す常駐。`usage-route.sh` が読む）の enable/start |
```

- [ ] **Step 8: Commit**

```bash
git add -N -- dot_config/codexbar/private_config.json
git add -N -- dot_config/systemd/user/codexbar-serve.service
git add -N -- run_once_after_87_codexbar-serve.sh.tmpl
git commit -m "feat(codexbar): 利用枠の usage サーバーを常駐させる" -- run_once_80_cli-tools.sh.tmpl dot_config/codexbar/private_config.json dot_config/systemd/user/codexbar-serve.service run_once_after_87_codexbar-serve.sh.tmpl README.md
```

### Task 2: 判定と通知のフック

**Files:**
- Create: `dot_claude/hooks/executable_usage-route.sh`
- Test: `dot_claude/hooks/usage-route.bats`

**Interfaces:**
- Consumes: Task 1 の `/usage?provider=both` の JSON。URL は環境変数 `USAGE_ROUTE_URL` で差し替えられる（既定 `http://127.0.0.1:8080/usage?provider=both`）。テストは `file://` の URL を渡す。
- Produces: PostToolUse の stdout に、振り先が変わったとき `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"..."}}`、強制的に打ち切るとき `{"continue":false,"stopReason":"..."}`。状態ファイル `${TMPDIR:-/tmp}/claude-usage-route/<session_id>` に `<route> <count> <forced>` の1行。route は `split` / `claude-only` / `stop-5h` / `stop-weekly`。

- [ ] **Step 1: 失敗するテストを書く**

`dot_claude/hooks/usage-route.bats`:

```bash
#!/usr/bin/env bats
# usage-route.sh のユニットテスト。本物の codexbar serve は呼ばず、file:// の JSON を読ませる。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_usage-route.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
    FIXTURE="$TMPDIR_TEST/usage.json"
    export USAGE_ROUTE_URL="file://$FIXTURE"
    STATE="$TMPDIR_TEST/claude-usage-route/sess"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

# usage <claude5h> <claude週> <claudeペース差> <codex5h> <codex週> <codexペース差>
# ペース差に - を渡すと pace を省く
usage() {
    jq -n --argjson c5 "$1" --argjson cw "$2" --arg cd "$3" \
          --argjson x5 "$4" --argjson xw "$5" --arg xd "$6" '
      def e($p; $h; $w; $d): {provider: $p, source: "oauth",
        usage: {primary: {usedPercent: $h, resetsAt: "2026-10-01T13:49:59Z"},
                secondary: {usedPercent: $w, resetsAt: "2026-10-08T07:59:59Z"}}}
        + (if $d == "-" then {} else {pace: {secondary: {deltaPercent: ($d | tonumber)}}} end);
      [e("codex"; $x5; $xw; $xd), e("claude"; $c5; $cw; $cd)]' > "$FIXTURE"
}

call() {
    run bash "$SCRIPT" <<< '{"session_id":"sess","hook_event_name":"PostToolUse","tool_name":"Bash"}'
}

context_of() { jq -r '.hookSpecificOutput.additionalContext // empty' <<< "$output"; }

@test "サーバーに届かない -> 何も出さない" {
    export USAGE_ROUTE_URL="http://127.0.0.1:1/usage"
    call
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$STATE" ]
}

@test "応答しないサーバー -> 2秒ほどで諦めて何も出さない" {
    # listen するが accept も応答もしないソケット。接続は backlog で成立し、curl は応答を待つ
    python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8); print(s.getsockname()[1], flush=True); time.sleep(30)' \
        > "$TMPDIR_TEST/port" &
    HANG_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMPDIR_TEST/port" ] && break; sleep 0.2; done
    export USAGE_ROUTE_URL="http://127.0.0.1:$(cat "$TMPDIR_TEST/port")/usage"
    SECONDS=0
    call
    kill "$HANG_PID" 2>/dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$SECONDS" -le 4 ]
}

@test "session_id が不正 -> 何も出さない" {
    usage 90 10 0 0 10 0
    run bash "$SCRIPT" <<< '{"session_id":"../x"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "初回で両方に余裕 -> 黙って split を記録" {
    usage 10 10 0 10 10 0
    call
    [ -z "$output" ]
    [ "$(cut -d' ' -f1 "$STATE")" = split ]
}

@test "初回で Codex の5時間枠が 85% -> claude-only を知らせる" {
    usage 10 10 0 85 10 0
    call
    [[ "$(context_of)" == *"実装も Claude"* ]]
    [ "$(cut -d' ' -f1 "$STATE")" = claude-only ]
}

@test "Codex の週枠のペース差が 25 -> claude-only" {
    usage 10 10 0 10 50 25
    call
    [ "$(cut -d' ' -f1 "$STATE")" = claude-only ]
}

@test "Codex の週枠のペース差 24、使用率 89 -> split" {
    usage 10 10 0 10 89 24
    call
    [ "$(cut -d' ' -f1 "$STATE")" = split ]
}

@test "Claude の5時間枠 85% -> stop-5h を知らせ、その後は何度呼んでも打ち切らない" {
    usage 10 10 0 10 10 0
    call
    usage 85 10 0 10 10 0
    call
    [[ "$(context_of)" == *"5時間枠"* ]]
    for _ in 1 2 3 4 5 6 7; do
        call
        [ -z "$output" ]
    done
}

@test "Claude の週枠の使用率 90%（ペース差 0） -> stop-weekly" {
    usage 10 90 0 10 10 0
    call
    [[ "$(context_of)" == *"週枠"* ]]
    [ "$(cut -d' ' -f1 "$STATE")" = stop-weekly ]
}

@test "Claude の週枠のペース差 25（使用率 30） -> stop-weekly" {
    usage 10 30 25 10 10 0
    call
    [ "$(cut -d' ' -f1 "$STATE")" = stop-weekly ]
}

@test "pace が無い -> 使用率だけで判定する" {
    usage 10 50 - 10 10 -
    call
    [ "$(cut -d' ' -f1 "$STATE")" = split ]
}

@test "stop-weekly: 知らせたあと4回は黙り、5回目で continue:false、6回目以降は黙る" {
    usage 10 95 0 10 10 0
    call
    [ -n "$(context_of)" ]
    for _ in 1 2 3 4; do
        call
        [ -z "$output" ]
    done
    call
    [ "$(jq -r '.continue' <<< "$output")" = false ]
    [[ "$(jq -r '.stopReason' <<< "$output")" == *"週枠"* ]]
    for _ in 1 2 3; do
        call
        [ -z "$output" ]
    done
}

@test "stop-weekly から戻る -> split を知らせ、再び入ったら2段階をやり直す" {
    usage 10 95 0 10 10 0
    for _ in 1 2 3 4 5 6; do call; done
    usage 10 10 0 10 10 0
    call
    [[ "$(context_of)" == *"実装は Codex"* ]]
    usage 10 95 0 10 10 0
    call
    [ -n "$(context_of)" ]
    for _ in 1 2 3 4; do call; done
    call
    [ "$(jq -r '.continue' <<< "$output")" = false ]
}

@test "振り先が同じ -> 黙る" {
    usage 10 10 0 90 10 0
    call
    call
    [ -z "$output" ]
}

@test "Claude がエラー -> 振り先も状態も変えない" {
    usage 10 10 0 10 10 0
    call
    jq '(.[] | select(.provider == "claude")) |= {provider: "claude", error: {message: "timed out"}}' \
        "$FIXTURE" > "$FIXTURE.tmp" && mv "$FIXTURE.tmp" "$FIXTURE"
    call
    [ -z "$output" ]
    [ "$(cut -d' ' -f1 "$STATE")" = split ]
}

@test "Codex が2件 -> 先頭の1件で判定する" {
    usage 10 10 0 90 10 0
    jq '[.[0]] + [.[0] | .usage.primary.usedPercent = 0] + [.[1]]' "$FIXTURE" > "$FIXTURE.tmp" \
        && mv "$FIXTURE.tmp" "$FIXTURE"
    call
    [ "$(cut -d' ' -f1 "$STATE")" = claude-only ]
}
```

- [ ] **Step 2: テストが落ちるのを確かめる**

Run: `bats dot_claude/hooks/usage-route.bats`
Expected: スクリプトが無いので、ほぼ全件 FAIL（「サーバーに届かない」などの出力が空のものは偶然通りうる）

- [ ] **Step 3: フックを書く**

`dot_claude/hooks/executable_usage-route.sh`:

```bash
#!/bin/bash
# PostToolUse（全ツール）: Claude と Codex の利用枠から、実装とレビューの振り先を決め、
# 変わったときだけ Claude に知らせる（haoblackj/dotfiles#14）。
#
# 値とペースは CodexBar の serve（systemd の codexbar-serve）が持つ。serve はキャッシュを
# 内蔵し、期限が切れても直前の値をすぐ返すので、ここでは毎回読むだけでキャッシュしない。
#
# 振り先（状態ファイルの route）:
#   split        両方に余裕。実装は Codex、レビューは Claude
#   claude-only  Codex が尽きた。実装も Claude
#   stop-5h      Claude の5時間枠が尽きた。知らせるだけ（週枠から少し借りて区切りまで進む
#                仕組みがあり、越えた分は週枠に表れるので、強制はしない）
#   stop-weekly  Claude の週枠が尽きた。知らせたあともツールが FORCE_AFTER 回呼ばれたら
#                continue:false で打ち切る。打ち切りは、この状態に入るたびに1回だけ
# 尽きた: 5時間枠は使用率 85% 以上。週枠は使用率 90% 以上、または pace.secondary.deltaPercent
# （使用率 − 経過率）25 以上。deltaPercent はステータスライン（usage-battery.sh）の
# 「経過率 − 使用率」と符号が逆なだけで同じ計算。
#
# 状態ファイル: ${TMPDIR:-/tmp}/claude-usage-route/<session_id> に "<route> <count> <forced>"。
# サブエージェントのツール呼び出しも同じ session_id で数える。
#
# fail-open: serve に届かない、どちらかの provider がエラー、JSON が想定と違う、どの場合も
# 何も出さず exit 0。状態ファイルも書き換えない。

set -uo pipefail

FORCE_AFTER=5
URL="${USAGE_ROUTE_URL:-http://127.0.0.1:8080/usage?provider=both}"

SID=$(jq -r '.session_id // empty' 2>/dev/null) || exit 0
[[ "$SID" =~ ^[A-Za-z0-9._-]+$ && "$SID" != *..* ]] || exit 0

BODY=$(curl -s -f -m 2 "$URL" 2>/dev/null) || exit 0

VERDICT=$(jq -r '
  def first_of($n): [.[] | select(.provider == $n)][0];
  def ok($e): $e != null and $e.error == null
    and ($e.usage.primary.usedPercent | type) == "number"
    and ($e.usage.secondary.usedPercent | type) == "number";
  def delta($e): ($e.pace.secondary.deltaPercent // null);
  def h5_out($e): $e.usage.primary.usedPercent >= 85;
  def week_out($e): $e.usage.secondary.usedPercent >= 90
    or ((delta($e) | type) == "number" and delta($e) >= 25);
  def fmt($name; $e): "\($name) 5時間枠 \($e.usage.primary.usedPercent)%、週枠 \($e.usage.secondary.usedPercent)%"
    + (if (delta($e) | type) == "number" then "（ペース差 \(if delta($e) >= 0 then "+" else "" end)\(delta($e))）" else "" end);
  if type != "array" then empty else
    first_of("claude") as $c | first_of("codex") as $x
    | if (ok($c) and ok($x)) | not then empty else
        (if week_out($c) then "stop-weekly"
         elif h5_out($c) then "stop-5h"
         elif h5_out($x) or week_out($x) then "claude-only"
         else "split" end) + "\t" + fmt("Claude"; $c) + " / " + fmt("Codex"; $x)
      end
  end' <<< "$BODY" 2>/dev/null) || exit 0
[[ -n "$VERDICT" ]] || exit 0
ROUTE=${VERDICT%%$'\t'*}
SUMMARY=${VERDICT#*$'\t'}

STATE_DIR="${TMPDIR:-/tmp}/claude-usage-route"
STATE="$STATE_DIR/$SID"
PREV_ROUTE="" COUNT=0 FORCED=0
if [[ -f "$STATE" && ! -L "$STATE" ]]; then
  read -r PREV_ROUTE COUNT FORCED < "$STATE" 2>/dev/null
  [[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
  [[ "$FORCED" =~ ^[01]$ ]] || FORCED=0
fi

# 一時ファイルから置き換え、並列のサブエージェントに書きかけを読ませない
save() {
  local tmp
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  tmp=$(mktemp "$STATE_DIR/.tmp.XXXXXX" 2>/dev/null) || return 0
  if ! { printf '%s %s %s\n' "$1" "$2" "$3" > "$tmp" && mv -f -- "$tmp" "$STATE"; } 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
  fi
}

notify() {
  jq -nc --arg c "$1" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
}

if [[ "$ROUTE" != "$PREV_ROUTE" ]]; then
  save "$ROUTE" 0 0
  # 初回で平常なら知らせない（どのセッションでも最初のツールのたびに出ると邪魔になる）
  [[ -z "$PREV_ROUTE" && "$ROUTE" == split ]] && exit 0
  case "$ROUTE" in
    split)
      notify "利用枠: 両方に余裕が戻った（$SUMMARY）。実装は Codex、レビューは Claude に振る。" ;;
    claude-only)
      notify "利用枠: Codex の枠が尽きた（$SUMMARY）。実装も Claude で行う。Codex の無料リセットの権利は、リーダーの許可なく使わない。" ;;
    stop-5h)
      notify "利用枠: Claude の5時間枠が 85% を越えた（$SUMMARY）。issue に状態（どこまで進んだか、次の一手）を書いてから、ターンを終える。" ;;
    stop-weekly)
      notify "利用枠: Claude の週枠が尽きた（$SUMMARY）。issue に状態（どこまで進んだか、次の一手）を書いてから、ターンを終える。このあとツールを ${FORCE_AFTER} 回呼ぶと、フックが強制的に打ち切る。" ;;
  esac
  exit 0
fi

if [[ "$ROUTE" == stop-weekly && "$FORCED" == 0 ]]; then
  COUNT=$((COUNT + 1))
  if (( COUNT >= FORCE_AFTER )); then
    save "$ROUTE" "$COUNT" 1
    jq -nc --arg r "Claude の週枠が尽きたため、利用枠のフック（usage-route.sh）が打ち切った（$SUMMARY）。" \
      '{continue: false, stopReason: $r}'
  else
    save "$ROUTE" "$COUNT" 0
  fi
fi
exit 0
```

- [ ] **Step 4: テストが通るのを確かめる**

Run: `bats dot_claude/hooks/usage-route.bats`
Expected: 全件 PASS

Run: `shellcheck dot_claude/hooks/executable_usage-route.sh`
Expected: 出力なし

- [ ] **Step 5: 本物の serve で1回動かす**

Task 1 の unit はまだ配っていないので、試験用のポートで立てて読む（本番の 8080 と状態ファイルの置き場を分ける）。

```bash
SCR=$(mktemp -d)
CODEXBAR_CONFIG=$PWD/dot_config/codexbar/private_config.json \
  codexbar serve --port 18080 --refresh-interval 300 >"$SCR/serve.log" 2>&1 & PID=$!
sleep 2
TMPDIR=$SCR USAGE_ROUTE_URL='http://127.0.0.1:18080/usage?provider=both' \
  bash dot_claude/hooks/executable_usage-route.sh <<< '{"session_id":"live"}'; echo "exit=$?"
cat "$SCR/claude-usage-route/live"
kill $PID
```

Expected: `exit=0`。状態ファイルに、その時点の実測に合う route（例: `split 0 0`）。

- [ ] **Step 6: Commit**

```bash
git add -N -- dot_claude/hooks/executable_usage-route.sh
git add -N -- dot_claude/hooks/usage-route.bats
git commit -m "feat(claude): 利用枠から振り先を決めて知らせる PostToolUse フック" -- dot_claude/hooks/executable_usage-route.sh dot_claude/hooks/usage-route.bats
```

### Task 3: settings.json への配線

**Files:**
- Modify: `linked/claude/settings.json`（`.hooks.PostToolUse`）
- Test: `dot_claude/hooks/settings-wiring.bats`

**Interfaces:**
- Consumes: Task 2 の `~/.claude/hooks/usage-route.sh`

- [ ] **Step 1: 失敗するテストを足す**

`dot_claude/hooks/settings-wiring.bats` の末尾に足す。

```bash
# bats test_tags=production-asset
@test "PostToolUseに usage-route.sh が全ツールで配線されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
groups=[g for g in h.get("PostToolUse",[]) if any("usage-route.sh" in x.get("command","") for x in g.get("hooks",[]))]
assert len(groups)==1, f"usage-route.sh の配線が {len(groups)} 件"
assert groups[0].get("matcher")=="*", f"matcher={groups[0].get('matcher')!r}"
print("PASS")
PY
}
```

注意: このテストは既定で本番のソース（`$HOME/.local/share/chezmoi/linked/...`）を読む。ワークツリーでは `S_OVERRIDE=$PWD/linked/claude/settings.json` を付けて走らせる。

- [ ] **Step 2: 落ちるのを確かめる**

Run: `S_OVERRIDE=$PWD/linked/claude/settings.json bats dot_claude/hooks/settings-wiring.bats`
Expected: 足した1件だけ FAIL（`usage-route.sh の配線が 0 件`）

- [ ] **Step 3: 配線する**

`linked/claude/settings.json` の `.hooks.PostToolUse` 配列の末尾に足す（jq で書き換え、キーの並びは既存に合わせる）。

```bash
jq '.hooks.PostToolUse += [{"hooks":[{"command":"bash \"$HOME/.claude/hooks/usage-route.sh\"","type":"command"}],"matcher":"*"}]' \
  linked/claude/settings.json > linked/claude/settings.json.tmp && mv linked/claude/settings.json.tmp linked/claude/settings.json
git diff -- linked/claude/settings.json
```

差分が PostToolUse の1件の追加だけであることを確かめる（jq が他のキーの書式を変えていたら、手で戻す）。

- [ ] **Step 4: 通るのを確かめる**

Run: `S_OVERRIDE=$PWD/linked/claude/settings.json bats dot_claude/hooks/settings-wiring.bats`
Expected: 全件 PASS

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(claude): usage-route.sh を PostToolUse の全ツールに配線する" -- linked/claude/settings.json dot_claude/hooks/settings-wiring.bats
```

### Task 4: グローバル CLAUDE.md に規則を足す

**Files:**
- Modify: `dot_claude/CLAUDE.md`（「委譲と情報の流通」の末尾、「クラウドセッション」の1つ目の箇条）

- [ ] **Step 1: 「委譲と情報の流通」の末尾（`status:実装中` の行の次）に足す**

```markdown
- 実装とレビューの振り先は、利用枠のフック（`usage-route.sh`）の知らせに従う。両方に余裕があれば、実装は Codex、レビューは Claude。Codex が尽きたら、実装も Claude。Claude が尽きたら止める。
- 止めると知らされたら、issue に状態（どこまで進んだか、次の一手）を書いてからターンを終える。Claude の週枠が尽きたときは、そのあとツールを呼び続けるとフックが強制的に打ち切る。
- Codex の無料リセットの権利は、リーダーの許可なく使わない。
```

- [ ] **Step 2: クラウドの読み替えに1句足す**

1つ目の箇条の「Codex への委譲の記述は適用しない。」を次に置き換える。

```markdown
「ホーム配下の設定ファイルはchezmoi前提で扱う」「Herdr でのセッションの立て方」「環境の境界（WSL/Windows）」と、Codex への委譲と利用枠のフックの記述は適用しない。chezmoi / herdr / codex / trash-put と利用枠のフックはコンテナに無い。
```

- [ ] **Step 3: 行数を確かめる**

Run: `wc -l dot_claude/CLAUDE.md`
Expected: 140 前後（200 を超えない）

- [ ] **Step 4: Commit**

```bash
git commit -m "docs(claude): 利用枠のフックに従う規則をグローバル CLAUDE.md に足す" -- dot_claude/CLAUDE.md
```

### Task 5: マージ後の配備と実機での確認

ブランチを main へ入れた後に、本体のチェックアウトで行う。マージのしかたは superpowers:finishing-a-development-branch でリーダーに選んでもらう。

- [ ] **Step 1: 配備する**

```bash
cd ~/.local/share/chezmoi && git pull
chezmoi apply
systemctl --user is-active codexbar-serve
curl -s -m 5 http://127.0.0.1:8080/health
ls -l ~/.claude/hooks/usage-route.sh
```

Expected: `active`、`{"version":"0.70.0","status":"ok"}`、実行権つきのフック。マージ後はワークツリーを片付ける（memory「Worktree と .chezmoitemplates の衝突」）。

- [ ] **Step 2: 本番のフックが黙っているのを確かめる**

いまのセッションで何かツールを1回呼び、`${TMPDIR:-/tmp}/claude-usage-route/<このセッションの session_id>` に `split 0 0` などの状態が書かれ、平常なら何も知らされないことを確かめる。

- [ ] **Step 3: サブエージェントでの `continue: false` の効き方を Herdr のタブで確かめる**

グローバル CLAUDE.md の「対話セッションでの実機検証」に従う。scratchpad に作業ディレクトリを作り、`USAGE_ROUTE_URL` に週枠 95% の偽の JSON（`file://`）を指す検証用の settings.json（PostToolUse に `usage-route.sh` だけ）を `--settings` で差し込み、`TMPDIR` も検証用にして `herdr agent start` で立てる。サブエージェントに Bash を6回呼ばせるプロンプトを1つ送り、5回目で止まるのがサブエージェントだけか、親のセッションまでかを transcript で見る。終わったらタブを閉じる。

- [ ] **Step 4: issue に結果を書く**

Step 1〜3 の実測（とくに Step 3 の止まる範囲）を issue 14 にコメントで書き、ラベル `status:実装中` を外す。
