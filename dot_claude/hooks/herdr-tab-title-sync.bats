#!/usr/bin/env bats
# herdr-tab-title-sync.sh のユニットテスト。本物の herdr は呼ばない。
set -u

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_herdr-tab-title-sync.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST/tmp"
    export XDG_STATE_HOME="$TMPDIR_TEST/state"
    mkdir -p "$TMPDIR"
    STATE_DIR="$XDG_STATE_HOME/herdr-tab-title"

    # 偽の herdr。呼ばれるたびに引数を | 区切りで1行記録する。
    #   tab get    -> FAKE_HANG=1 なら応答せず sleep 30 で固まる（exec で置き換えるので、
    #                 timeout に殺されたときに子プロセスが残らない）。
    #                 それ以外は FAKE_TAB_GET があればそれを、無ければ
    #                 pane_count=FAKE_PANE_COUNT、label=今のラベル（$LABEL_FILE、無ければ "3"）の JSON を返す
    #   tab rename -> FAKE_RENAME_FAIL=1 なら exit 1。成功したらラベルを $LABEL_FILE に書く
    FAKE_BIN="$TMPDIR_TEST/fakebin"
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/herdr" <<'EOS'
#!/bin/bash
{ printf '%s|' "$@"; printf '\n'; } >> "$HERDR_LOG"
if [ "$1" = tab ] && [ "$2" = get ]; then
  if [ "${FAKE_HANG:-0}" = 1 ]; then
    exec sleep 30
  fi
  if [ -n "${FAKE_TAB_GET+x}" ]; then
    printf '%s' "$FAKE_TAB_GET"
  else
    label=3
    [ -f "$LABEL_FILE" ] && label=$(cat "$LABEL_FILE")
    jq -nc --argjson n "${FAKE_PANE_COUNT:-1}" --arg t "$3" --arg l "$label" \
      '{id:"cli:tab:get",result:{tab:{pane_count:$n,tab_id:$t,label:$l,number:42},type:"tab_info"}}'
  fi
  exit 0
fi
if [ "$1" = tab ] && [ "$2" = rename ]; then
  [ "${FAKE_RENAME_FAIL:-0}" = 1 ] && exit 1
  printf '%s' "$4" > "$LABEL_FILE"
  exit 0
fi
exit 2
EOS
    chmod +x "$FAKE_BIN/herdr"
    export PATH="$FAKE_BIN:$PATH"

    export HERDR_LOG="$TMPDIR_TEST/herdr.log"
    export LABEL_FILE="$TMPDIR_TEST/label"
    : > "$HERDR_LOG"
    export HERDR_ENV=1
    export HERDR_TAB_ID="w1:t1"
    export HERDR_PANE_ID="w1:p1"
    unset FAKE_TAB_GET FAKE_PANE_COUNT FAKE_RENAME_FAIL FAKE_HANG
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

input_with_name() { # session_name [session_id]
    jq -nc --arg n "$1" --arg s "${2:-sess}" '{session_id:$s,session_name:$n}'
}

sync() { # session_name [session_id]
    run bash "$SCRIPT" <<< "$(input_with_name "$@")"
}

label() { cat "$LABEL_FILE" 2>/dev/null || echo 3; }
renamed() { grep -q '^tab|rename|' "$HERDR_LOG"; }
hand_rename() { printf '%s' "$1" > "$LABEL_FILE"; }

@test "HERDR_ENVが無い -> herdrを呼ばない" {
    unset HERDR_ENV
    sync "タイトル"
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}

@test "HERDR_TAB_IDが空 -> herdrを呼ばない" {
    export HERDR_TAB_ID=""
    sync "タイトル"
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}

@test "session_nameが無い -> herdrを呼ばない" {
    run bash "$SCRIPT" <<< '{"session_id":"sess"}'
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}

@test "既定のラベル（番号）のタブ -> session_nameへrenameする。stdoutは空" {
    sync "タイトル"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -qxF 'tab|rename|w1:t1|タイトル|' "$HERDR_LOG"
    [ "$(label)" = "タイトル" ]
}

@test "前回値は TMPDIR でなく XDG_STATE_HOME の下に置く（WSL の再起動で /tmp が消えても残る）" {
    sync "タイトル"
    [ -n "$(ls -A "$STATE_DIR")" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "XDG_STATE_HOMEが無ければ ~/.local/state の下に置く" {
    unset XDG_STATE_HOME
    export HOME="$TMPDIR_TEST/home"
    sync "タイトル"
    [ -n "$(ls -A "$HOME/.local/state/herdr-tab-title")" ]
}

@test "同じsession_nameで2回目 -> herdrを呼ばない" {
    sync "タイトル"
    : > "$HERDR_LOG"
    sync "タイトル"
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}

@test "自分が付けた名前のままsession_nameが変わった（/rename、/clear） -> 付け直す" {
    sync "前のタイトル"
    sync "次のタイトル"
    grep -qxF 'tab|rename|w1:t1|次のタイトル|' "$HERDR_LOG"
    [ "$(label)" = "次のタイトル" ]
}

@test "/clear で session_id が変わっても、自分が付けた名前のタブなら新しい名前へ付け直す" {
    sync "前のタイトル" "sess-a"
    sync "次のタイトル" "sess-b"
    [ "$(label)" = "次のタイトル" ]
}

@test "手で付けた名前は、session_nameが変わっても上書きしない" {
    sync "前のタイトル"
    hand_rename "手の名前"
    : > "$HERDR_LOG"
    sync "次のタイトル"
    [ "$status" -eq 0 ]
    ! renamed || false
    [ "$(label)" = "手の名前" ]
}

@test "手で付けた名前を見たあとは、同じsession_nameの間はherdrを呼ばない" {
    hand_rename "手の名前"
    sync "タイトル"
    ! renamed || false
    : > "$HERDR_LOG"
    sync "タイトル"
    [ ! -s "$HERDR_LOG" ]
}

@test "前回値が無く（導入直後）、ラベルが番号でもsession_nameでもない -> 手の名前とみなして触らない" {
    hand_rename "コイカツ読込高速化"
    sync "penguinEx #98 からの引き継ぎ"
    [ "$status" -eq 0 ]
    ! renamed || false
    [ "$(label)" = "コイカツ読込高速化" ]
}

@test "前回値が無く、ラベルがsession_nameと同じ -> 自分の名前とみなし、以後のsession_nameに追従する" {
    hand_rename "タイトル"
    sync "タイトル"
    ! renamed || false
    sync "次のタイトル"
    [ "$(label)" = "次のタイトル" ]
}

@test "resumeで別のタブに入った（タブIDが変わり、ラベルは番号） -> 付け直す" {
    sync "タイトル"
    export HERDR_TAB_ID="w1:t2" HERDR_PANE_ID="w1:p2"
    hand_rename "5"
    sync "タイトル"
    grep -qxF 'tab|rename|w1:t2|タイトル|' "$HERDR_LOG"
}

@test "herdrの再起動でタブIDが変わり、手の名前が復元されている -> 触らない" {
    sync "タイトル"
    hand_rename "手の名前"
    export HERDR_TAB_ID="w1:t7" HERDR_PANE_ID="w1:p7"
    : > "$HERDR_LOG"
    sync "タイトル"
    ! renamed || false
    [ "$(label)" = "手の名前" ]
}

@test "herdrの再起動でタブIDが変わり、自分の名前が復元されている -> 以後のsession_nameに追従する" {
    sync "タイトル"
    export HERDR_TAB_ID="w1:t7" HERDR_PANE_ID="w1:p7"
    sync "タイトル"
    sync "次のタイトル"
    grep -qxF 'tab|rename|w1:t7|次のタイトル|' "$HERDR_LOG"
}

@test "pane_countが2 -> renameを呼ばず、前回値も記録しない" {
    export FAKE_PANE_COUNT=2
    sync "タイトル"
    [ "$status" -eq 0 ]
    ! renamed || false
    [ ! -e "$STATE_DIR" ] || [ -z "$(ls -A "$STATE_DIR")" ]
}

@test "tab getがJSONを返さない -> renameを呼ばない" {
    export FAKE_TAB_GET="not json"
    sync "タイトル"
    [ "$status" -eq 0 ]
    ! renamed || false
}

@test "tab getの応答にlabelが無い -> renameを呼ばない" {
    export FAKE_TAB_GET='{"result":{"tab":{"pane_count":1,"tab_id":"w1:t1"}}}'
    sync "タイトル"
    [ "$status" -eq 0 ]
    ! renamed || false
}

@test "renameが失敗 -> 前回値を記録せず、次の実行でまた試す。exit 0" {
    export FAKE_RENAME_FAIL=1
    sync "タイトル"
    [ "$status" -eq 0 ]
    unset FAKE_RENAME_FAIL
    : > "$HERDR_LOG"
    sync "タイトル"
    grep -qxF 'tab|rename|w1:t1|タイトル|' "$HERDR_LOG"
}

@test "session_nameが-で始まる、空白や引用符を含む -> 1引数のまま変形されずに渡る" {
    name='-x "引用" と 空白'
    sync "$name"
    [ "$status" -eq 0 ]
    grep -qxF "tab|rename|w1:t1|$name|" "$HERDR_LOG"
}

@test "HERDR_TAB_ID、session_idにパストラバーサル -> 記録ディレクトリ外に副作用なし、herdrを呼ばない" {
    for bad in '../evil' '..' 'w1/t1'; do
        export HERDR_TAB_ID="$bad"
        sync "タイトル"
        [ "$status" -eq 0 ]
    done
    export HERDR_TAB_ID="w1:t1"
    for bad in '../evil' '..' 'a/b'; do
        sync "タイトル" "$bad"
        [ "$status" -eq 0 ]
    done
    [ ! -e "$TMPDIR_TEST/evil" ] && [ ! -e "$XDG_STATE_HOME/evil" ]
    [ ! -s "$HERDR_LOG" ]
}

@test "herdrがPATHに無い -> exit 0、stdoutは空" {
    # jq だけを通した PATH にする。jq まで消すと session_name を読む段で抜けてしまい、
    # herdr が無い経路を通らない。
    mkdir -p "$TMPDIR_TEST/onlyjq"
    ln -s "$(command -v jq)" "$TMPDIR_TEST/onlyjq/jq"
    export PATH="$TMPDIR_TEST/onlyjq:/usr/bin:/bin"
    ! command -v herdr || false
    sync "タイトル"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "壊れた入力JSON -> herdrを呼ばない" {
    run bash "$SCRIPT" <<< 'not json'
    [ "$status" -eq 0 ]
    [ ! -s "$HERDR_LOG" ]
}

@test "tab getがハングする -> timeoutで打ち切られ8秒以内にexit 0、renameを呼ばない" {
    export FAKE_HANG=1
    start_ns=$(date +%s%N)
    sync "タイトル"
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    [ "$status" -eq 0 ]
    [ "$elapsed_ms" -lt 8000 ]
    ! renamed || false
}
