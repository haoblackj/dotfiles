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
    ! grep -q '^tab|rename|' "$HERDR_LOG" || false
    [ "$(state_of w1:p1)" = "" ]
}

@test "tab getがJSONを返さない -> renameを呼ばない" {
    export FAKE_TAB_GET="not json"
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    ! grep -q '^tab|rename|' "$HERDR_LOG" || false
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
    ! command -v herdr || false
    run bash "$SCRIPT" <<< "$(input_with_name "タイトル")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "壊れた入力JSON -> herdrを呼ばない" {
    run bash "$SCRIPT" <<< 'not json'
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}
