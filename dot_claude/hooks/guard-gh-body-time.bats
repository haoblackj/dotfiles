#!/usr/bin/env bats
# GitHub への投稿は実行せず、入力 JSON に対するフックの判定を検査する。
set -u

decide() {
  local cmd="$1" payload out code
  payload=$(jq -nc --arg c "$cmd" --arg cwd "$BATS_TEST_TMPDIR" \
    '{session_id:"test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$c}}')
  out=$(printf '%s' "$payload" | python3 "$SCRIPT")
  code=$?
  if [ "$code" -ne 0 ]; then
    printf 'hook-exit-%s' "$code"
  elif [ -z "$out" ]; then
    printf 'allow'
  else
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"'
  fi
}

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/executable_guard-gh-body-time.py"
}

check_all() {
  local expected="$1" cmd
  shift
  for cmd in "$@"; do
    run decide "$cmd"
    [ "$output" = "$expected" ] || { echo "$cmd: $output（期待: $expected）" >&2; return 1; }
  done
}

@test "本文とタイトルの手書き時刻を各書き込みで止める" {
  check_all deny \
    'gh issue comment 89 --body "## 状態（02:37）"' \
    'gh pr comment 1 -b "2:05 に開始"' \
    'gh issue comment 1 --body=02:37' \
    'gh issue create --title "02:37 の結果"' \
    'gh issue edit 1 --body 02:37' 'gh pr create -b02:37' \
    'gh pr edit 1 --title=02:37' 'gh pr review 1 -b 02:37' \
    'gh release create v1 --notes 02:37' 'gh release edit v1 -n02:37'
}

@test "ヒアドキュメントと字句分割不能時の本文も止める" {
  check_all deny \
    $'gh issue comment 1 --body "$(cat <<\'EOF\'\n02:45\nEOF\n)"' \
    $'gh issue comment 1 --body-file - <<\'EOF\'\ndon\'t guess 02:37\nEOF' \
    $'gh release create v1 --notes-file - <<\'EOF\'\ndon\'t guess 02:37\nEOF'
}

@test "前置き・パス・グローバル repo オプション・境界を読む" {
  check_all deny \
    'cd x && gh issue comment 1 --body 02:37' \
    'GH_TOKEN=x gh issue comment 1 --body 02:37' \
    'env -u GH_TOKEN gh issue comment 1 --body 02:37' \
    'env -i X=y command gh issue comment 1 --body 02:37' \
    'exec /usr/bin/gh pr comment 1 -b02:37' \
    'time nohup gh -R o/r issue comment 1 --body 02:37' \
    'gh --repo o/r issue comment 1 --body 02:37' \
    'gh --repo=o/r issue comment 1 --body 02:37' \
    'then gh pr comment 1 -b02:37' 'do gh pr comment 1 -b02:37' \
    '! gh pr comment 1 -b02:37' '{ gh pr comment 1 -b02:37; }' \
    '(gh pr comment 1 -b02:37)' 'echo x | gh pr comment 1 -b02:37' \
    $'echo x\ngh issue comment 1 --body 02:37'
}

@test "REST のメソッド・フィールド・結合形で書き込みを識別する" {
  check_all deny \
    "gh api repos/o/r/issues/comments/1 -X PATCH -f body='02:37'" \
    'gh api repos/o/r/issues/1/comments -f body=02:37' \
    'gh api -X POST repos/o/r/issues/1/comments --raw-field=body=02:37' \
    'gh api repos/o/r/issues/1 --method=PUT -fbody=02:37' \
    'gh api repos/o/r/issues/1 --field=body=02:37' \
    'gh api repos/o/r/issues/1 --raw-field body=02:37' \
    'gh api repos/o/r/issues/1 -XPATCH --header "X-Test: 02:37"' \
    'gh api repos/o/r/issues/1 --method POST --header "X-Test: 02:37"'
}

@test "GraphQL は mutation だけを対象にする" {
  check_all deny \
    'gh api graphql -f query='\''mutation { addComment(input:{subjectId:"x", body:"02:37"}) { clientMutationId } }'\''' \
    'gh api -f "query=mutation { minimizeComment(input: {}) { id } }" graphql -f note=02:37'
  check_all allow 'gh api graphql -f "query={ viewer { login } }" -f note=02:37'
}

@test "日本語・全角・AM/PM・ISO・秒つき時刻を止める" {
  local value
  for value in '０２：３７' '2時37分' '2 時 37 分' '14時半' '午後3時' \
    '夜11時' '午後 3:15' '朝 8' '夕方5' '深夜 1' '正午12' \
    '2時頃' '3pm' '3:15 PM' '3 p.m.' '11am' \
    '2026-10-31T02:24:00Z' '02:37:10' '開始02:37'; do
    check_all deny "gh issue comment 1 --body '$value'" || return 1
  done
}

@test "step 1:10 は時刻と区別できないので止める" {
  check_all deny 'gh issue comment 1 --body "step 1:10"'
}

@test "所要時間・行番号・比・ポート・識別子は通す" {
  check_all allow \
    'gh issue comment 1 --body "2時間かかった、3時限、4時点"' \
    'gh issue comment 1 --body "foo.py:12:34 16:9 localhost:8080 v1.2:30 a1:30 123:45"'
}

@test "date と API のコマンド置換に数字の時刻がなければ通す" {
  check_all allow \
    'gh issue comment 89 --body "## 状態（$(date '\''+%Y-%m-%d %H:%M'\'')）"' \
    $'gh issue comment 89 --body "$(cat <<EOF\n## 状態（$(date \'+%Y-%m-%d %H:%M\')）\n...\nEOF\n)"' \
    'gh issue comment 1 --body "$(gh api repos/o/r/issues/comments/1 --jq .created_at)"'
}

@test "時刻の無い書き込みは通す" {
  check_all allow \
    'gh issue comment 1 --body テスト' 'gh pr comment 1' \
    'gh issue create --title テスト --body テスト' 'gh issue edit 1 -b テスト' \
    'gh pr create -b テスト' 'gh pr edit 1 -b テスト' 'gh pr review 1 --approve' \
    'gh release create v1 -n テスト' 'gh release edit v1 -n テスト' \
    'gh api repos/o/r/issues/1 -X PATCH -f state=closed'
}

@test "Markdown のフェンス・インラインコードの時刻は通す" {
  check_all allow \
    $'gh issue comment 1 --body "```text\n02:37\n```"' \
    $'gh issue comment 1 --body "~~~log\n02:37\n~~~"' \
    $'gh issue comment 1 --body "\n```text\n02:37\n```\n"' \
    $'gh issue comment 1 --body "\n~~~log\n02:37\n~~~\n"' \
    'gh issue comment 1 --body "ログは `02:37` と ``2時``"' \
    $'gh issue comment 1 --body "\n````\n```\n02:37\n`````\n"' \
    $'gh issue comment 1 --body "\n~~~\n02:37\n"' \
    $'gh issue comment 1 --body "``ログ\n02:37``"'
  check_all deny \
    $'gh issue comment 1 --body "~~~\nログ\n~~~"; echo 02:37' \
    $'gh issue comment 1 --body "\n```\nログ\n```\n02:37"' \
    'gh issue comment 1 --body "`02:37``"' \
    $'gh issue comment 1 --body "\n~~~\nログ\n~~~\n02:37"'
}

@test "読み出し・本文なし編集・引用の言及・gh 以外は通す" {
  check_all allow \
    'gh issue view 89 --search 02:37' 'gh pr list --search 02:37' \
    'gh api repos/o/r/issues/1/comments --jq "02:37"' \
    'gh issue edit 1 --add-label 02:37' 'gh pr edit 1 --add-label 02:37' \
    'git commit -m "gh issue comment 1 --body 02:37"' \
    'echo "gh pr comment 02:37"' 'echo 02:37' 'date -d 02:37'
}

@test "cwd 基準の本文ファイルと結合形、API の入力ファイルを検査する" {
  printf '%s\n' '状態: 02:37' > "$BATS_TEST_TMPDIR/body.md"
  printf '%s\n' '{"body":"02:37"}' > "$BATS_TEST_TMPDIR/in.json"
  check_all deny \
    'gh issue comment 1 --body-file body.md' 'gh issue comment 1 --body-file=body.md' \
    'gh pr comment 1 -F body.md' 'gh pr edit 1 -Fbody.md' \
    'gh release create v1 --notes-file body.md' 'gh release edit v1 --notes-file=body.md' \
    'gh release create v1 -F body.md' \
    'gh api repos/o/r/issues/comments/1 -X PATCH -F body=@body.md' \
    'gh api repos/o/r/issues/comments/1 -Fbody=@body.md' \
    'gh api repos/o/r/issues/comments/1 --field=body=@body.md' \
    'gh api repos/o/r/issues/comments/1 --field body=@body.md' \
    'gh api repos/o/r/issues/1 --input in.json' 'gh api repos/o/r/issues/1 --input=in.json'
}

@test "絶対パスとチルダを展開してファイルを検査する" {
  printf '02:37' > "$BATS_TEST_TMPDIR/body.md"
  check_all deny "gh issue comment 1 --body-file '$BATS_TEST_TMPDIR/body.md'"
  HOME="$BATS_TEST_TMPDIR" check_all deny 'gh issue comment 1 --body-file ~/body.md'
}

@test "時刻の無いファイル・コード内時刻・読めないファイル・標準入力は通す" {
  printf 'テスト\n`02:37`\n' > "$BATS_TEST_TMPDIR/body.md"
  mkdir "$BATS_TEST_TMPDIR/directory"
  check_all allow \
    'gh issue comment 1 --body-file body.md' 'gh pr create -F body.md' \
    'gh issue comment 1 --body-file missing.md' 'gh issue comment 1 --body-file directory' \
    'gh issue comment 1 --body-file -' 'gh api repos/o/r/issues/1 --input missing.json'
}

@test "ファイルは先頭 1 MB だけを見る" {
  python3 - "$BATS_TEST_TMPDIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
(root / 'late.md').write_bytes(b'x' * (1024 * 1024) + b' 02:37')
(root / 'early.md').write_bytes(b'02:37 ' + b'x' * (1024 * 1024))
PY
  check_all allow 'gh issue comment 1 --body-file late.md'
  check_all deny 'gh issue comment 1 --body-file early.md'
}

@test "対象があればコマンド全体を検査する" {
  check_all deny 'echo 02:37; gh issue comment 1 --body テスト'
}

@test "不正な JSON や command の欠落は出力せず正常終了する" {
  local payload
  for payload in broken '{}' '[]' 'null' '{"tool_input":null}' \
    '{"tool_input":{"command":123}}'; do
    run bash -c 'printf "%s" "$1" | python3 "$2"' _ "$payload" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "拒否の形式・案内・検出箇所の最大 5 件を確認する" {
  local payload
  payload=$(jq -nc --arg cmd $'gh issue comment 1 --body "\n02:31\n02:32\n02:33\n02:34\n02:35\n02:36\n"' '{tool_input:{command:$cmd}}')
  run bash -c 'printf "%s" "$1" | python3 "$2"' _ "$payload" "$SCRIPT"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny"' >/dev/null
  local reason
  reason=$(printf '%s' "$output" | jq -r .hookSpecificOutput.permissionDecisionReason)
  [[ "$reason" == *'haoblackj/dotfiles#75'* ]]
  [[ "$reason" == *'02:35'* && "$reason" != *'02:36'* ]]
  [[ "$reason" == *'$(date '\''+%Y-%m-%d %H:%M'\'')'* ]]
  [[ "$reason" == *'issues/comments/<ID> --jq .created_at'* ]]
  [[ "$reason" == *'UTC'* && "$reason" == *'JST'* ]]
  [[ "$reason" == *'<<EOF'* && "$reason" == *"<<'EOF'"* ]]
  [[ "$reason" == *'\$'* && "$reason" == *'\`'* ]]
  [[ "$reason" == *'--body-file'* && "$reason" == *'インラインコード'* ]]
  [[ "$reason" != *'gh-post.py'* && "$reason" != *'{{now}}'* ]]
}
