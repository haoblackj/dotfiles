#!/usr/bin/env bats
# GitHub への投稿は実行せず、入力 JSON に対するフックの判定を検査する。
set -u

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/executable_guard-decision-quotes.py"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ" "$BATS_TEST_TMPDIR/wishes/w1"
  export PRTS_WISHES_DIR="$BATS_TEST_TMPDIR/wishes"
  {
    jq -nc '{type:"user",message:{role:"user",content:"今は変えない 再起動できないため\n速度半分になるのは流石に"}}'
    jq -nc '{type:"user",message:{role:"user",content:[{type:"text",text:"マージしましょう"}]}}'
    jq -nc '{type:"user",isCompactSummary:true,message:{role:"user",content:"WSL の上限を下げることはありえない"}}'
    jq -nc '{type:"user",message:{role:"user",content:"<task-notification>QRで渡す</task-notification>"}}'
    jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"承認が要る操作は全部断る"}]}}'
  } > "$PROJ/current.jsonl"
  jq -nc '{type:"user",message:{role:"user",content:"前のセッションで言ったこと"}}' > "$PROJ/previous.jsonl"
  jq -nc '{op:"add",id:"n1",kind:"選択",text:"Issue を立てる（おすすめ）"}' > "$PRTS_WISHES_DIR/w1/notes.jsonl"
}

body() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/body.md"
}

decide() {
  local cmd="$1" payload out code
  payload=$(jq -nc --arg c "$cmd" --arg cwd "$BATS_TEST_TMPDIR" --arg t "$PROJ/current.jsonl" \
    '{session_id:"test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,transcript_path:$t,tool_input:{command:$c}}')
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

post() {
  decide "gh issue comment 1 -R o/r --body-file $BATS_TEST_TMPDIR/body.md"
}

@test "発言どおりの引用は通す（空白の違いと … の省略を許す）" {
  body '## 決定: 題' '### リーダーが決めたこと' \
    '- WSL の上限は変えない（リーダー「今は変えない 再起動できないため」）' \
    '- 速度は落とさない（リーダー「速度半分に…流石に」）' \
    '- マージする（リーダー「マージしましょう」）'
  run post
  [ "$output" = allow ]
}

@test "言葉を強めた引用は止める" {
  body '## 決定: 題' '### リーダーが決めたこと' \
    '- WSL の上限は変えない（リーダー「WSL の上限を下げることはありえない」）'
  run post
  [ "$output" = deny ]
}

@test "引用の無い項目は止める" {
  body '## 決定: 題' '### リーダーが決めたこと' '- QR で合言葉を渡す'
  run post
  [ "$output" = deny ]
}

@test "節の外でもリーダーの直後に置いた引用は確かめる" {
  body '## 決定: 題' '### 決定' '- リーダーの言葉として「WSL の上限を下げることはありえない」'
  run post
  [ "$output" = deny ]
  body '## 決定: 題' '### 決定' '- リーダーが画面で「Issue を立てる（おすすめ）」を選んだ'
  run post
  [ "$output" = allow ]
}

@test "Claude の案の節とリーダーから離れた引用は確かめない" {
  body '## 決定: 題' '### リーダーが決めたこと' '- マージする（リーダー「マージしましょう」）' \
    '### Claude の案（リーダーの答え待ち）' '- 「承認が要る操作は全部断る」形で回す' \
    '### 断った案' '- 断った案は「QR で渡す」'
  run post
  [ "$output" = allow ]
}

@test "引用符を付けずにリーダーの言葉として書いた行は止める" {
  for line in '- リーダーの要件: WSL の上限を下げることはありえない' \
              '- WSL の上限を下げることはありえない（リーダー、2026-11-12）' \
              '- リーダー: 上限は下げない' \
              '- キャッシュを捨てた（リーダーの指示）' \
              '- 監視の目が無いのが怖い（リーダー）'; do
    body '## 決定: 題' '### 決定' "$line"
    run post
    [ "$output" = deny ] || { echo "$line: $output" >&2; return 1; }
  done
  for line in '- リーダーの指摘を受けて、試しの場を変える' \
              '- 測る時期はリーダーが指示する' \
              '- 画像の確かめはリーダーの指示を待つ' \
              '- リーダーの言葉を強めて書いた例が 1 件あった'; do
    body '## 決定: 題' '### 決定' "$line"
    run post
    [ "$output" = allow ] || { echo "$line: $output" >&2; return 1; }
  done
}

@test "中身の無い「」とコードの中の引用は確かめない" {
  body '## 決定: 題' '- リーダーの言葉の引用（「」）があること' \
    '- 例: `（リーダー「言っていないこと」）` の形'
  run post
  [ "$output" = allow ]
}

@test "前のセッションの発言と prts の指摘も引用元にする" {
  body '## 決定: 題' '### リーダーが決めたこと' \
    '- 続ける（リーダー「前のセッションで言ったこと」）' \
    '- Issue を立てる（リーダー「Issue を立てる」）'
  run post
  [ "$output" = allow ]
}

@test "要約、システムの知らせ、Claude の発言は引用元にしない" {
  for q in 'WSL の上限を下げることはありえない' 'QRで渡す' '承認が要る操作は全部断る'; do
    body '## 決定: 題' '### リーダーが決めたこと' "- 案（リーダー「$q」）"
    run post
    [ "$output" = deny ] || { echo "$q: $output" >&2; return 1; }
  done
}

@test "決定でない本文、書き込みでないコマンドは見ない" {
  body '## 状態' '### リーダーが決めたこと' '- QR で合言葉を渡す'
  run post
  [ "$output" = allow ]
  body '## 決定: 題' '### リーダーが決めたこと' '- QR で合言葉を渡す'
  run decide "cat $BATS_TEST_TMPDIR/body.md"
  [ "$output" = allow ]
}

@test "--body で直に渡した本文も確かめる" {
  run decide 'gh issue comment 1 -R o/r --body "## 決定: 題
### リーダーが決めたこと
- QR で合言葉を渡す"'
  [ "$output" = deny ]
}

@test "記録が読めないときは止めない" {
  body '## 決定: 題' '### リーダーが決めたこと' '- QR で合言葉を渡す'
  export PRTS_WISHES_DIR="$BATS_TEST_TMPDIR/none"
  PROJ="$BATS_TEST_TMPDIR/missing"
  run post
  [ "$output" = allow ]
}
