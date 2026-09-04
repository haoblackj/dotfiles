#!/usr/bin/env bash
# notify-workdir-change.sh のユニットテスト。
#
# フック本体の名前は置き場所で変わる。chezmoi のソース側では
# executable_notify-workdir-change.sh、ターゲット（~/.claude/hooks/）では
# notify-workdir-change.sh。どちらでも動くよう両方を試す。
# 既存のテストはこれを怠って配置先で exit 127 になり、何も検証していなかった前例がある。
#
# 実運用の状態ファイルには触らない。XDG_STATE_HOME を一時ディレクトリへ向ける。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK=""
for cand in "$HERE/notify-workdir-change.sh" "$HERE/executable_notify-workdir-change.sh"; do
  if [ -f "$cand" ]; then HOOK="$cand"; break; fi
done
if [ -z "$HOOK" ]; then
  echo "フック本体が見つからない: $HERE/notify-workdir-change.sh も executable_notify-workdir-change.sh も無い" >&2
  exit 1
fi

pass=0
fail=0

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
export XDG_STATE_HOME="$WORK/state"

# --- ヘルパー ---------------------------------------------------------------

# フックを1回呼び、標準出力をそのまま返す。
# run_hook <session> <agent> <tool> <cwd> [file_path]
run_hook() {
  local session="$1" agent="$2" tool="$3" cwd="$4" fp="${5-}" payload
  payload=$(jq -nc --arg s "$session" --arg a "$agent" --arg t "$tool" --arg c "$cwd" --arg f "$fp" '
    {session_id: $s, hook_event_name: "PreToolUse", tool_name: $t, cwd: $c}
    + (if $a == "" then {} else {agent_id: $a} end)
    + (if $f == "" then {tool_input: {}} else {tool_input: {file_path: $f}} end)')
  printf '%s' "$payload" | bash "$HOOK" 2>/dev/null
}

# フックの出力から additionalContext を取り出す。出力が無ければ空。
context_of() {
  local out="$1"
  [ -z "$out" ] && { printf ''; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

expect_silent() {
  local what="$1" out="$2"
  if [ -z "$out" ]; then
    pass=$((pass + 1)); printf 'ok   - silent   : %s\n' "$what"
  else
    fail=$((fail + 1)); printf 'FAIL - silent   : %s\n   出力: [%s]\n' "$what" "$out"
  fi
}

expect_contains() {
  local what="$1" out="$2" needle="$3" ctx
  ctx=$(context_of "$out")
  case "$ctx" in
    *"$needle"*) pass=$((pass + 1)); printf 'ok   - contains : %s\n' "$what" ;;
    *) fail=$((fail + 1)); printf 'FAIL - contains : %s\n   期待に含む: [%s]\n   実際:       [%s]\n' "$what" "$needle" "$ctx" ;;
  esac
}

expect_not_contains() {
  local what="$1" out="$2" needle="$3" ctx
  ctx=$(context_of "$out")
  case "$ctx" in
    *"$needle"*) fail=$((fail + 1)); printf 'FAIL - excludes : %s\n   含んではいけない: [%s]\n   実際:             [%s]\n' "$what" "$needle" "$ctx" ;;
    *) pass=$((pass + 1)); printf 'ok   - excludes : %s\n' "$what" ;;
  esac
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

# stdin をソケットで与えてフックを呼ぶ。Claude Code は実際にソケットで渡すので、
# パイプだけの検証では bash の読み方の違いを見逃す。
run_hook_socket() {
  local payload="$1"
  python3 - "$HOOK" "$payload" <<'PY'
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

# --- テスト -----------------------------------------------------------------

make_repo "$WORK/r1"

# 16. 対象外の tool_name では何もしない。
out=$(run_hook s1 "" Read "$WORK/r1")
expect_silent "tool_name が Read なら無音" "$out"
if [ -d "$XDG_STATE_HOME/claude-workdir-notice" ] && [ -n "$(ls -A "$XDG_STATE_HOME/claude-workdir-notice" 2>/dev/null)" ]; then
  fail=$((fail + 1)); printf 'FAIL - 対象外の tool_name で状態ファイルが作られた\n'
else
  pass=$((pass + 1)); printf 'ok   - 対象外の tool_name で状態ファイルを作らない\n'
fi

# 20. 出力の形。additionalContext を持ち permissionDecision を持たない。
out=$(run_hook s2 "" Bash "$WORK/r1")
ev=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
if [ "$ev" = "PreToolUse" ]; then
  pass=$((pass + 1)); printf 'ok   - hookEventName が PreToolUse\n'
else
  fail=$((fail + 1)); printf 'FAIL - hookEventName が PreToolUse でない: [%s]\n' "$ev"
fi
pd=$(printf '%s' "$out" | jq -r 'if (.hookSpecificOutput | has("permissionDecision")) then "ある" else "ない" end' 2>/dev/null)
if [ "$pd" = "ない" ]; then
  pass=$((pass + 1)); printf 'ok   - permissionDecision を返さない\n'
else
  fail=$((fail + 1)); printf 'FAIL - permissionDecision を返している\n'
fi

# 21. stdin をソケットで与えても動く。
payload=$(jq -nc --arg c "$WORK/r1" '{session_id:"s3", hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$c, tool_input:{}}')
out=$(run_hook_socket "$payload")
expect_contains "ソケット stdin でも通知が出る" "$out" "$WORK/r1"

make_repo "$WORK/r2"
make_repo "$WORK/fresh" --no-commit
mkdir -p "$WORK/r1/sub"
git -C "$WORK/r1" worktree add -q -b feat/wt "$WORK/wt1"
git -C "$WORK/r1" branch -q other
S=sess-shell

# 1. shell レーンの初回で通知が出る。
out=$(run_hook "$S" "" Bash "$WORK/r1")
expect_contains "初回はトップレベルを出す"   "$out" "$WORK/r1"
expect_contains "初回はブランチを出す"       "$out" "ブランチ main"
expect_contains "初回は「このセッションの」で始まる" "$out" "このセッションの"
expect_not_contains "初回は直前を書かない"   "$out" "直前は"

# 2. 同じ作業先の2回目は無音。
out=$(run_hook "$S" "" Bash "$WORK/r1")
expect_silent "同じ作業先の2回目" "$out"

# 6. 同じリポジトリのサブディレクトリでも無音（トップレベルへ畳まれる）。
out=$(run_hook "$S" "" Bash "$WORK/r1/sub")
expect_silent "同じリポジトリのサブディレクトリ" "$out"

# 3. 別のリポジトリへ移ると通知が出て、直前が文面に入る。
out=$(run_hook "$S" "" Bash "$WORK/r2")
expect_contains "別リポジトリで現在を出す" "$out" "$WORK/r2"
expect_contains "別リポジトリで直前を出す" "$out" "直前は $WORK/r1（ブランチ main）でした"
expect_contains "確認を促す一文が入る"     "$out" "意図した作業先か確かめてから続けてください"

# 4. 同一リポジトリの別ワークツリーへ移ると通知が出る。
out=$(run_hook "$S" "" Bash "$WORK/wt1")
expect_contains "ワークツリーのパスを出す"   "$out" "$WORK/wt1"
expect_contains "ワークツリーのブランチを出す" "$out" "ブランチ feat/wt"

# 5. トップレベルが同じでブランチだけ変わると通知が出る。
out=$(run_hook "$S" "" Bash "$WORK/r1")   # r1 へ戻す（main）
git -C "$WORK/r1" checkout -q other
out=$(run_hook "$S" "" Bash "$WORK/r1")
expect_contains "ブランチだけの変化でも鳴る" "$out" "ブランチ other"
expect_contains "直前のブランチを出す"       "$out" "直前は $WORK/r1（ブランチ main）でした"
git -C "$WORK/r1" checkout -q main

# 18. コミットが1つも無いリポジトリを管理外と誤判定しない。
out=$(run_hook sess-fresh "" Bash "$WORK/fresh")
expect_contains "コミット無しでもトップレベルを出す" "$out" "$WORK/fresh"
expect_not_contains "コミット無しを管理外にしない"   "$out" "管理外"

# --- write レーン ---
W=sess-write

# 11. 絶対パスの file_path は cwd を無視して解決する。
out=$(run_hook "$W" "" Write "$WORK/r2" "$WORK/r1/a.txt")
expect_contains "書き込み先のパスを出す"     "$out" "書き込み先 $WORK/r1/a.txt"
expect_contains "書き込み先のリポジトリを出す" "$out" "$WORK/r1（ブランチ main）の中です"

# 10. 相対パスの file_path は cwd を前置して解決する。
out=$(run_hook "$W" "" Write "$WORK/r2" "b.txt")
expect_contains "相対パスを cwd で解決する" "$out" "書き込み先 $WORK/r2/b.txt"
expect_contains "解決先のリポジトリを出す"   "$out" "$WORK/r2（ブランチ main）の中です"

# 15. 親ディレクトリが存在しないときは存在する祖先まで遡る。
out=$(run_hook "$W" "" Write "$WORK/r1" "$WORK/r1/no/such/dir/c.txt")
expect_contains "存在しない親でも祖先で解決する" "$out" "$WORK/r1（ブランチ main）の中です"

# 12. shell レーンと write レーンが互いを上書きしない。
L=sess-lanes
out=$(run_hook "$L" "" Bash "$WORK/r1");                 expect_contains "レーン分離: shell 初回" "$out" "$WORK/r1"
out=$(run_hook "$L" "" Write "$WORK/r1" "$WORK/r2/d.txt"); expect_contains "レーン分離: write 初回" "$out" "$WORK/r2"
out=$(run_hook "$L" "" Bash "$WORK/r1");                 expect_silent   "レーン分離: shell 2回目は無音" "$out"
out=$(run_hook "$L" "" Write "$WORK/r1" "$WORK/r2/e.txt"); expect_silent   "レーン分離: write 2回目は無音" "$out"

# Edit も write レーンとして扱う。
out=$(run_hook "$L" "" Edit "$WORK/r1" "$WORK/r2/f.txt")
expect_silent "Edit は write レーンを共有する" "$out"

# --- git 管理外 ---
mkdir -p "$WORK/plain/x" "$WORK/plain/y"
N=sess-nogit

# 7. 管理外で通知が出て、管理外である旨と基準ディレクトリが文面に入る。
out=$(run_hook "$N" "" Bash "$WORK/r1")   # まずリポジトリを記録
out=$(run_hook "$N" "" Bash "$WORK/plain/x")
expect_contains "管理外である旨を出す"     "$out" "git 管理外のディレクトリ"
expect_contains "管理外では基準ディレクトリを出す" "$out" "作業ディレクトリ $WORK/plain/x は"
expect_contains "管理外でも直前を出す"     "$out" "直前は $WORK/r1（ブランチ main）でした"
expect_not_contains "管理外でブランチを書かない" "$out" "ブランチ main）です"

# 8. 管理外の別ディレクトリへ移っても2回目は無音（!nogit へ畳まれている）。
out=$(run_hook "$N" "" Bash "$WORK/plain/y")
expect_silent "管理外どうしの移動" "$out"

# 9 と 19. 管理外からリポジトリへ戻ると鳴り、直前はパスを含まない。
out=$(run_hook "$N" "" Bash "$WORK/r2")
expect_contains "管理外から戻ると鳴る"           "$out" "$WORK/r2（ブランチ main）"
expect_contains "直前が管理外ならパスを書かない" "$out" "直前は git 管理外のディレクトリでした"
expect_not_contains "直前に plain のパスを出さない" "$out" "$WORK/plain"

# write レーンの管理外の文面。
out=$(run_hook sess-nogit-w "" Write "$WORK/plain/x" "$WORK/plain/x/z.txt")
expect_contains "管理外への書き込み先を出す" "$out" "書き込み先 $WORK/plain/x/z.txt は git 管理外のディレクトリです"

# --- 集計 -------------------------------------------------------------------

printf '\n%s件成功 / %s件失敗\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
