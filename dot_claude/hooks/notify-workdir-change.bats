#!/usr/bin/env bats
# notify-workdir-change.sh のユニットテスト。
#
# run_hook_socket() だけは bats の run に置き換えていない（裁定1）。stdin を
# python3 の socket.socketpair() でソケット越しに渡す検査で、run はパイプで
# stdin を渡すためこれを再現できない。トップレベルのヘルパーとして残し、
# 該当の @test の中では生の subprocess 呼び出しとして扱い、出力を自分で
# 変数へ受ける。層4b の中で run を使わない唯一の箇所。
#
# 実運用の状態ファイルには触らない。XDG_STATE_HOME を @test ごとに新しい
# 一時ディレクトリへ向ける（setup()）。
set -u

# ペイロード JSON を組む。build_payload <session> <agent> <tool> <cwd> [file_path]
build_payload() {
  local session="$1" agent="$2" tool="$3" cwd="$4" fp="${5-}"
  jq -nc --arg s "$session" --arg a "$agent" --arg t "$tool" --arg c "$cwd" --arg f "$fp" '
    {session_id: $s, hook_event_name: "PreToolUse", tool_name: $t, cwd: $c}
    + (if $a == "" then {} else {agent_id: $a} end)
    + (if $f == "" then {tool_input: {}} else {tool_input: {file_path: $f}} end)'
}

# フックを1回呼び、標準出力をそのまま返す。call_hook <session> <agent> <tool> <cwd> [file_path]
call_hook() {
  local session="$1" agent="$2" tool="$3" cwd="$4" fp="${5-}" payload
  payload=$(build_payload "$session" "$agent" "$tool" "$cwd" "$fp")
  printf '%s' "$payload" | bash "$SCRIPT" 2>/dev/null
}

# フックの出力(additionalContext を含む JSON)から文面だけを取り出す。無ければ空。
context_of() {
  local out="$1"
  [ -z "$out" ] && { printf ''; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

# 一時的な git リポジトリを作る。既定でブランチ main、初期コミットあり。
# make_repo <パス> [--no-commit]
make_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" symbolic-ref HEAD refs/heads/main
  git -C "$path" config user.email t@example.invalid
  git -C "$path" config user.name test
  if [ "${2-}" != "--no-commit" ]; then
    : > "$path/seed"
    git -C "$path" add seed
    git -C "$path" commit -qm init
  fi
}

# stdin をソケットで与えてフックを呼ぶ（裁定1）。Claude Code は実際にソケットで
# 渡すので、パイプだけの検証では bash の読み方の違いを見逃す。
run_hook_socket() {
  local payload="$1"
  python3 - "$SCRIPT" "$payload" <<'PY'
import socket, subprocess, sys
hook, payload = sys.argv[1], sys.argv[2]
parent, child = socket.socketpair()
p = subprocess.Popen(["bash", hook], stdin=child.fileno(),
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
child.close()
parent.sendall(payload.encode())
parent.shutdown(socket.SHUT_WR)
out, _ = p.communicate()
parent.close()
sys.stdout.write(out.decode())
PY
}

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/executable_notify-workdir-change.sh"
    WORK="$(mktemp -d)"
    export XDG_STATE_HOME="$WORK/state"
}

teardown() {
    rm -rf -- "$WORK"
}

# 元 "16."
@test "tool_name が Read なら無音で状態ファイルも作らない" {
    make_repo "$WORK/r1"
    run call_hook sess-read "" Read "$WORK/r1"
    [ -z "$output" ] || { echo "対象外の tool_name なのに出力があった: [$output]" >&2; return 1; }
    local sd="$XDG_STATE_HOME/claude-workdir-notice"
    if [ -d "$sd" ] && [ -n "$(ls -A "$sd" 2>/dev/null)" ]; then
        echo "対象外の tool_name で状態ファイルが作られた: $(ls -A "$sd")" >&2
        return 1
    fi
}

# 元 "20."
@test "出力の形: additionalContext を持ち permissionDecision を持たない" {
    make_repo "$WORK/r1"
    run call_hook sess-shape "" Bash "$WORK/r1"
    local ev pd
    ev=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
    [ "$ev" = "PreToolUse" ] || { echo "hookEventName が PreToolUse でない: [$ev]" >&2; return 1; }
    pd=$(printf '%s' "$output" | jq -r 'if (.hookSpecificOutput | has("permissionDecision")) then "ある" else "ない" end' 2>/dev/null)
    [ "$pd" = "ない" ] || { echo "permissionDecision を返している" >&2; return 1; }
}

# 元 "21."（裁定1: run を使わない唯一の箇所）
@test "ソケット stdin でも通知が出る" {
    make_repo "$WORK/r1"
    local payload out ctx
    payload=$(build_payload sess-socket "" Bash "$WORK/r1")
    out=$(run_hook_socket "$payload")
    ctx=$(context_of "$out")
    [[ "$ctx" == *"$WORK/r1"* ]] || { echo "ソケット stdin で通知が出なかった: [$ctx]" >&2; return 1; }
}

# 元 "1."
@test "shell レーンの初回で通知が出る" {
    make_repo "$WORK/r1"
    run call_hook sess-first "" Bash "$WORK/r1"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/r1"* ]] || { echo "トップレベルが出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"ブランチ main"* ]] || { echo "ブランチが出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"このセッションの"* ]] || { echo "初回の文言でない: [$ctx]" >&2; return 1; }
    [[ "$ctx" != *"直前は"* ]] || { echo "初回なのに直前が書かれている: [$ctx]" >&2; return 1; }
}

# 元 "2."（裁定2: まず記録してから検査する）
@test "同じ作業先の2回目は無音" {
    make_repo "$WORK/r1"
    run call_hook sess-same "" Bash "$WORK/r1"   # まず記録
    run call_hook sess-same "" Bash "$WORK/r1"
    [ -z "$output" ] || { echo "同じ作業先の2回目で出力があった: [$output]" >&2; return 1; }
}

# 元 "6."（裁定2: まず記録してから検査する）
@test "同じリポジトリのサブディレクトリでも無音" {
    make_repo "$WORK/r1"
    mkdir -p "$WORK/r1/sub"
    run call_hook sess-sub "" Bash "$WORK/r1"   # まず記録
    run call_hook sess-sub "" Bash "$WORK/r1/sub"
    [ -z "$output" ] || { echo "サブディレクトリで出力があった: [$output]" >&2; return 1; }
}

# 元 "3."（裁定2: まず記録してから検査する）
@test "別のリポジトリへ移ると通知が出て直前が文面に入る" {
    make_repo "$WORK/r1"
    make_repo "$WORK/r2"
    run call_hook sess-switch "" Bash "$WORK/r1"   # まず記録
    run call_hook sess-switch "" Bash "$WORK/r2"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/r2"* ]] || { echo "現在のトップレベルが出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"直前は $WORK/r1（ブランチ main）でした"* ]] || { echo "直前が出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"意図した作業先か確かめてから続けてください"* ]] || { echo "確認を促す一文がない: [$ctx]" >&2; return 1; }
}

# 元 "4."
@test "同一リポジトリの別ワークツリーへ移ると通知が出る" {
    make_repo "$WORK/r1"
    git -C "$WORK/r1" worktree add -q -b feat/wt "$WORK/wt1"
    run call_hook sess-wt "" Bash "$WORK/wt1"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/wt1"* ]] || { echo "ワークツリーのパスが出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"ブランチ feat/wt"* ]] || { echo "ワークツリーのブランチが出ていない: [$ctx]" >&2; return 1; }
}

# 元 "5."（裁定2: まず記録してから検査する）
@test "トップレベルが同じでブランチだけ変わると通知が出る" {
    make_repo "$WORK/r1"
    git -C "$WORK/r1" branch -q other
    run call_hook sess-branch "" Bash "$WORK/r1"   # まず記録(main)
    git -C "$WORK/r1" checkout -q other
    run call_hook sess-branch "" Bash "$WORK/r1"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"ブランチ other"* ]] || { echo "変化後のブランチが出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"直前は $WORK/r1（ブランチ main）でした"* ]] || { echo "直前のブランチが出ていない: [$ctx]" >&2; return 1; }
}

# 元 "18."
@test "コミットが1つも無いリポジトリを管理外と誤判定しない" {
    make_repo "$WORK/fresh" --no-commit
    run call_hook sess-fresh "" Bash "$WORK/fresh"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/fresh"* ]] || { echo "トップレベルが出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" != *"管理外"* ]] || { echo "コミット無しを管理外にした: [$ctx]" >&2; return 1; }
}

# 元 "11."
@test "絶対パスの file_path は cwd を無視して解決する" {
    make_repo "$WORK/r1"
    make_repo "$WORK/r2"
    run call_hook sess-write-abs "" Write "$WORK/r2" "$WORK/r1/a.txt"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"書き込み先 $WORK/r1/a.txt"* ]] || { echo "書き込み先パスが出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"$WORK/r1（ブランチ main）の中です"* ]] || { echo "書き込み先のリポジトリが出ていない: [$ctx]" >&2; return 1; }
}

# 元 "10."
@test "相対パスの file_path は cwd を前置して解決する" {
    make_repo "$WORK/r2"
    run call_hook sess-write-rel "" Write "$WORK/r2" "b.txt"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"書き込み先 $WORK/r2/b.txt"* ]] || { echo "相対パスが cwd で解決されていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"$WORK/r2（ブランチ main）の中です"* ]] || { echo "解決先のリポジトリが出ていない: [$ctx]" >&2; return 1; }
}

# 元 "15."
@test "親ディレクトリが存在しないときは存在する祖先まで遡る" {
    make_repo "$WORK/r1"
    run call_hook sess-write-anc "" Write "$WORK/r1" "$WORK/r1/no/such/dir/c.txt"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/r1（ブランチ main）の中です"* ]] || { echo "存在する祖先で解決されていない: [$ctx]" >&2; return 1; }
}

# 元 "12."
@test "レーン分離: shell と write が互いを上書きしない" {
    make_repo "$WORK/r1"
    make_repo "$WORK/r2"
    local L=sess-lanes ctx
    run call_hook "$L" "" Bash "$WORK/r1"
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/r1"* ]] || { echo "レーン分離: shell 初回が鳴らない: [$ctx]" >&2; return 1; }
    run call_hook "$L" "" Write "$WORK/r1" "$WORK/r2/d.txt"
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/r2"* ]] || { echo "レーン分離: write 初回が鳴らない: [$ctx]" >&2; return 1; }
    run call_hook "$L" "" Bash "$WORK/r1"
    [ -z "$output" ] || { echo "レーン分離: shell 2回目で出力があった: [$output]" >&2; return 1; }
    run call_hook "$L" "" Write "$WORK/r1" "$WORK/r2/e.txt"
    [ -z "$output" ] || { echo "レーン分離: write 2回目で出力があった: [$output]" >&2; return 1; }
}

# 元 "Edit は write レーンを共有する"（裁定2: まず記録してから検査する）
@test "Edit は write レーンを共有する" {
    make_repo "$WORK/r1"
    make_repo "$WORK/r2"
    local L=sess-lanes-edit ctx
    run call_hook "$L" "" Write "$WORK/r1" "$WORK/r2/x.txt"   # まず記録(write現在=r2)
    run call_hook "$L" "" Edit "$WORK/r1" "$WORK/r2/f.txt"
    [ -z "$output" ] || { echo "同じ作業先への Edit で出力があった: [$output]" >&2; return 1; }
    run call_hook "$L" "" Edit "$WORK/r1" "$WORK/r1/g.txt"
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/r1（ブランチ main）"* ]] || { echo "別の作業先への Edit で通知が出ない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"直前は $WORK/r2（ブランチ main）でした"* ]] || { echo "別の作業先への Edit で直前が出ない: [$ctx]" >&2; return 1; }
}

# 元 "7."（裁定2: この手順はすでに「まず記録してから検査する」の形でコード化されている）
@test "管理外で通知が出て、管理外である旨と基準ディレクトリが文面に入る" {
    make_repo "$WORK/r1"
    mkdir -p "$WORK/plain/x"
    run call_hook sess-nogit "" Bash "$WORK/r1"   # まずリポジトリを記録
    run call_hook sess-nogit "" Bash "$WORK/plain/x"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"git 管理外のディレクトリ"* ]] || { echo "管理外である旨が出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"作業ディレクトリ $WORK/plain/x は"* ]] || { echo "基準ディレクトリが出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"直前は $WORK/r1（ブランチ main）でした"* ]] || { echo "直前が出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" != *"ブランチ main）です"* ]] || { echo "管理外なのにブランチを書いた: [$ctx]" >&2; return 1; }
}

# 元 "8."（裁定2: まず記録してから検査する）
@test "管理外どうしの移動は2回目無音" {
    mkdir -p "$WORK/plain/x" "$WORK/plain/y"
    run call_hook sess-nogit2 "" Bash "$WORK/plain/x"   # まず記録
    run call_hook sess-nogit2 "" Bash "$WORK/plain/y"
    [ -z "$output" ] || { echo "管理外どうしの移動で出力があった: [$output]" >&2; return 1; }
}

# 元 "9. と 19."（裁定2: まず記録してから検査する）
@test "管理外から戻ると鳴り、直前は管理外のディレクトリと出てパスを含まない" {
    make_repo "$WORK/r2"
    mkdir -p "$WORK/plain/x"
    run call_hook sess-nogit3 "" Bash "$WORK/plain/x"   # まず記録
    run call_hook sess-nogit3 "" Bash "$WORK/r2"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/r2（ブランチ main）"* ]] || { echo "管理外から戻っても鳴らない: [$ctx]" >&2; return 1; }
    [[ "$ctx" == *"直前は git 管理外のディレクトリでした"* ]] || { echo "直前が管理外と出ていない: [$ctx]" >&2; return 1; }
    [[ "$ctx" != *"$WORK/plain"* ]] || { echo "直前に plain のパスが出た: [$ctx]" >&2; return 1; }
}

# 元 "write レーンの管理外の文面"
@test "write レーンの管理外の文面" {
    mkdir -p "$WORK/plain/x"
    run call_hook sess-nogit-w "" Write "$WORK/plain/x" "$WORK/plain/x/z.txt"
    local ctx
    ctx=$(context_of "$output")
    [[ "$ctx" == *"書き込み先 $WORK/plain/x/z.txt は git 管理外のディレクトリです"* ]] || { echo "管理外への書き込み先の文面が違う: [$ctx]" >&2; return 1; }
}

# 元 "13."
@test "session_id にパストラバーサルを入れると何も書かず何も出さない" {
    make_repo "$WORK/r1"
    local sd="$XDG_STATE_HOME/claude-workdir-notice" before after
    before=$(find "$sd" -type f 2>/dev/null | wc -l)
    run call_hook "../escape" "" Bash "$WORK/r1"
    [ -z "$output" ] || { echo "session_id にパストラバーサルで出力があった: [$output]" >&2; return 1; }
    after=$(find "$sd" -type f 2>/dev/null | wc -l)
    [ "$before" = "$after" ] || { echo "パストラバーサルでファイルが増えた: $before -> $after" >&2; return 1; }
    [ ! -e "$XDG_STATE_HOME/escape.state" ] || { echo "状態ディレクトリの外へ書けた" >&2; return 1; }
}

# 元 "agent_id にパストラバーサル"
@test "agent_id にパストラバーサルを入れると外へ書けない" {
    make_repo "$WORK/r1"
    local sd="$XDG_STATE_HOME/claude-workdir-notice"
    mkdir -p "$sd/ok-esc"
    run call_hook ok "esc/../../escaped" Bash "$WORK/r1"
    [ -z "$output" ] || { echo "agent_id にパストラバーサルで出力があった: [$output]" >&2; return 1; }
    [ ! -e "$XDG_STATE_HOME/escaped.state" ] || { echo "agent_id 経由で状態ディレクトリの外へ書けた" >&2; return 1; }
}

# 元 "14."
@test "agent_id の有無で別の状態ファイルを使う" {
    make_repo "$WORK/r1"
    local sd="$XDG_STATE_HOME/claude-workdir-notice" ctx
    run call_hook sess-ag ""    Bash "$WORK/r1"
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/r1"* ]] || { echo "親: 初回が鳴らない: [$ctx]" >&2; return 1; }
    run call_hook sess-ag ""    Bash "$WORK/r1"
    [ -z "$output" ] || { echo "親: 2回目に出力があった: [$output]" >&2; return 1; }
    run call_hook sess-ag agent Bash "$WORK/r1"
    ctx=$(context_of "$output")
    [[ "$ctx" == *"$WORK/r1"* ]] || { echo "子: 別ファイルなのに初回として鳴らない: [$ctx]" >&2; return 1; }
    { [ -f "$sd/sess-ag.state" ] && [ -f "$sd/sess-ag-agent.state" ]; } \
        || { echo "agent_id で状態ファイルが分かれていない" >&2; return 1; }
}

# 元 "17."（前半: 新規作成のときの掃除。ループはブリーフの裁定3どおり診断つきで保つ）
@test "新規作成のときに7日を超えた *.state だけ消える" {
    make_repo "$WORK/r1"
    local sd="$XDG_STATE_HOME/claude-workdir-notice"
    mkdir -p "$sd/keepdir"
    : > "$sd/old.state";    touch -d '8 days ago' "$sd/old.state"
    : > "$sd/recent.state"; touch -d '2 days ago' "$sd/recent.state"
    : > "$sd/other.log";    touch -d '8 days ago' "$sd/other.log"
    run call_hook sess-sweep "" Bash "$WORK/r1"
    [ ! -e "$sd/old.state" ] || { echo "7日超の .state が残った" >&2; return 1; }
    local keep
    for keep in "$sd/recent.state" "$sd/other.log" "$sd/keepdir"; do
        [ -e "$keep" ] || { echo "消してはいけないものが消えた: $keep" >&2; return 1; }
    done
}

# 元 "17."（後半: 更新時は掃除しない、裁定2: まず記録してから検査する）
@test "既存の状態ファイルを更新するだけのときは掃除しない" {
    make_repo "$WORK/r1"
    make_repo "$WORK/r2"
    local sd="$XDG_STATE_HOME/claude-workdir-notice"
    run call_hook sess-sweep-upd "" Bash "$WORK/r1"   # まず記録して state_file を作る
    : > "$sd/old2.state"; touch -d '8 days ago' "$sd/old2.state"
    run call_hook sess-sweep-upd "" Bash "$WORK/r2"
    [ -e "$sd/old2.state" ] || { echo "更新のときにも掃除した" >&2; return 1; }
}

# 元 "一時ファイルを残さない"
@test "一時ファイルを残さない" {
    make_repo "$WORK/r1"
    local sd="$XDG_STATE_HOME/claude-workdir-notice" leftovers
    run call_hook sess-tmp "" Bash "$WORK/r1"
    leftovers=$(find "$sd" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l)
    [ "$leftovers" = "0" ] || { echo "一時ファイルが $leftovers 個残っている" >&2; return 1; }
}

# 元 "Important 3: exit 0 を守っているかの検査"
@test "4つの経路すべてで exit 0 を守る" {
    make_repo "$WORK/r1"
    run call_hook sess-ec "" Bash "$WORK/r1"
    [ "$status" -eq 0 ] || { echo "通知が出る経路で exit $status" >&2; return 1; }
    run call_hook sess-ec "" Bash "$WORK/r1"
    [ "$status" -eq 0 ] || { echo "無音の経路(同じ作業先)で exit $status" >&2; return 1; }
    run call_hook "../escape-exitcode" "" Bash "$WORK/r1"
    [ "$status" -eq 0 ] || { echo "鍵が不正な経路(session_id にパストラバーサル)で exit $status" >&2; return 1; }
    run call_hook sess-ec "" Read "$WORK/r1"
    [ "$status" -eq 0 ] || { echo "対象外の tool_name(Read)で exit $status" >&2; return 1; }
}

# 元 "配線"。検証の対象は chezmoi ソース側。ターゲットだけ見ると「配線したが
# re-add していない」状態を合格にしてしまう(既存の settings-wiring.bats と同じ理由)。
# bats test_tags=production-asset
@test "PreToolUse の Bash と Write|Edit に配線されている" {
    local settings="$HOME/.local/share/chezmoi/dot_claude/private_settings.json"
    [ -f "$settings" ] || { echo "chezmoi ソース側の settings が無い: $settings" >&2; return 1; }
    local wiring
    wiring=$(python3 - "$settings" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pre = d.get("hooks", {}).get("PreToolUse", [])
def wired(matcher):
    for group in pre:
        if group.get("matcher") != matcher:
            continue
        for h in group.get("hooks", []):
            if "notify-workdir-change.sh" in h.get("command", ""):
                return True
    return False
missing = [m for m in ("Bash", "Write|Edit") if not wired(m)]
print("ok" if not missing else "missing:" + ",".join(missing))
PY
)
    [ "$wiring" = "ok" ] || { echo "配線が足りない: $wiring" >&2; return 1; }
}
