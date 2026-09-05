#!/usr/bin/env bash
# guard-unsandboxed-pytest.sh の単体テスト。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK=""
for cand in "$HERE/guard-unsandboxed-pytest.sh" "$HERE/executable_guard-unsandboxed-pytest.sh"; do
  [ -f "$cand" ] && HOOK="$cand" && break
done
# フック本体がまだ無い段階（Step 2 の赤の確認）でも set -u で即死せず、
# deny を期待する側が FAIL して pass=/fail= 行まで出るようにする。
[ -n "$HOOK" ] || echo "フック本体が見つからない: $HERE" >&2
pass=0; fail=0

# 対象かどうかはフックが origin の URL だけで決める。実在するリポジトリのパスを
# 書くと、このファイルが chezmoi で配られた先の機械にそのパスが無く、
# git -C が失敗してフックが exit 0 で素通りする。deny を期待する側が全部 FAIL し、
# allow を期待する側は「止めなかった」ではなく「判定に到達しなかった」で通る。
TMPROOT=$(mktemp -d /tmp/guard-pytest-test.XXXXXX)
cleanup() { trash-put "$TMPROOT" >/dev/null 2>&1; }
trap cleanup EXIT
mkrepo() { # <ディレクトリ名> [origin の URL]
  local d="$TMPROOT/$1"
  mkdir -p "$d" && git -C "$d" init -q
  [ -n "${2:-}" ] && git -C "$d" remote add origin "$2"
  printf '%s' "$d"
}
REPO=$(mkrepo penguinEx git@github.com:haoblackj/penguinEx.git)
CHEZMOI=$(mkrepo dotfiles https://github.com/haoblackj/dotfiles.git)
OUT1=$(mkrepo kikimimi https://github.com/haoblackj/kikimimi.git)
OUT2=$(mkrepo comfy-batch-runner https://github.com/haoblackj/comfy-batch-runner.git)
OUT3=$(mkrepo oratorio https://github.com/haoblackj/oratorio.git)
OUT4=$(mkrepo wikiwalk https://github.com/haoblackj/wikiwalk.git)
NOGIT="$TMPROOT/nogit"; mkdir -p "$NOGIT"   # git 管理下ですらない場所

expect() { # 期待(deny|allow) cwd コマンド
  local want=$1 cwd=$2 cmd=$3 out
  out=$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
        "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        "$(printf '%s' "$cwd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        | bash "$HOOK")
  if [ "$want" = deny ] && grep -q '"permissionDecision":"deny"' <<<"$out"; then
    pass=$((pass+1)); printf 'ok   - deny: %s\n' "$cmd"
  elif [ "$want" = allow ] && ! grep -q '"permissionDecision":"deny"' <<<"$out"; then
    pass=$((pass+1)); printf 'ok   - allow: %s\n' "$cmd"
  else
    fail=$((fail+1)); printf 'FAIL - %s を期待: %s\n' "$want" "$cmd"
  fi
}

echo "== 対象リポジトリの中で止める =="
expect deny "$REPO" 'python3 -m pytest tests/ -q'
expect deny "$REPO" 'pytest tests/foo.py'
expect deny "$REPO" 'python tests/test_foo.py'
expect deny "$REPO" 'python3 tests/test_fetch_profile.py'
expect deny "$REPO" 'env FOO=1 pytest tests/'
expect deny "$REPO" 'timeout 60 python3 -m pytest tests/'
expect deny "$REPO" 'nohup pytest tests/'
expect deny "$REPO" 'uv run pytest tests/'
expect deny "$REPO" 'poetry run pytest tests/'
expect deny "$REPO" 'PYTHONPATH=x python3 -m pytest tests/'
expect deny "$REPO" 'bwrap --ro-bind / / -- pytest tests/'
expect deny "$REPO" 'cd /repo && python3 -m pytest -q'

echo "== 対象リポジトリの中でも通す =="
expect allow "$REPO" 'verify-tests /repo --strict'
expect allow "$REPO" 'verify-tests /repo -- tests/test_foo.py -k some_case'
expect allow "$REPO" 'python3 scripts/setup_env.py'
expect allow "$REPO" 'grep -n "pytest" docs/plan.md'

echo "== 対象外では止めない =="
expect allow "$OUT1" 'pytest tests/'
expect allow "$OUT2" 'pytest tests/'
expect allow "$OUT3" 'python3 tests/test_foo.py'
expect allow "$OUT4" 'uv run pytest tests/'
expect allow "$NOGIT" 'python3 -m pytest tests/'

echo "== chezmoi のソースでも対象として止める =="
expect deny "$CHEZMOI" 'python3 -m pytest dot_claude/hooks/tests/'

echo "== 名前の規約から外れるファイルは止めない =="
expect allow "$REPO" 'python3 manifest_test_helper.py'
expect allow "$REPO" 'python3 mytest_foo.py'

# このファイルは *.test.sh なので shell レーンの対象に入り、サンドボックスの中でも走る。
# サンドボックスの HOME は使い捨てなので ~/.local/bin は存在せず、verify-tests を
# 呼べない。呼べないまま比較すると3件とも FAIL してこのファイルが非0になり、
# base に無い新規の赤として regression に拾われる。呼べないときは skip する。
if command -v verify-tests >/dev/null 2>&1; then
  echo "== 正規化が verify-tests と一致する =="
  for u in https://github.com/haoblackj/penguinEx \
           https://github.com/haoblackj/dotfiles.git \
           git@github.com:haoblackj/penguinEx.git; do
    a=$(verify-tests --selftest-normalize "$u" 2>/dev/null)
    b=$(printf '%s' "$u" | sed -E 's#^[a-z]+://##; s#^[^@]*@##; s#^[^/:]+[:/]##; s#\.git$##; s#/$##')
    if [ "$a" = "$b" ]; then
      pass=$((pass+1)); printf 'ok   - 正規化が一致: %s -> %s\n' "$u" "$a"
    else
      fail=$((fail+1)); printf 'FAIL - 正規化が不一致: %s (tool=%s hook=%s)\n' "$u" "$a" "$b"
    fi
  done
else
  echo "== 正規化の比較は skip（verify-tests が PATH にない） =="
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
