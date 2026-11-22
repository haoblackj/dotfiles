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

@test "時刻の無い書き込みは通す" {
  check_all allow \
    'gh issue comment 1 --body テスト' 'gh pr comment 1' \
    'gh issue create --title テスト --body テスト' 'gh issue edit 1 -b テスト' \
    'gh pr create -b テスト' 'gh pr edit 1 -b テスト' 'gh pr review 1 --approve' \
    'gh release create v1 -n テスト' 'gh release edit v1 -n テスト' \
    'gh api repos/o/r/issues/1 -X PATCH -f state=closed'
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

@test "対象があればコマンド全体を検査する" {
  check_all deny 'echo 02:37; gh issue comment 1 --body テスト'
}
