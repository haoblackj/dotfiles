#!/usr/bin/env bats
# guard-unsandboxed-pytest.sh の単体テスト。
#
# 対象 guard-unsandboxed-pytest.sh に `executable_` が付かないのは、
# `bash` 経由で呼ばれるので実行ビットが要らず、ソース側の名前に
# 接頭辞を持たないため。
set -u

mkrepo() { # <ディレクトリ名> [origin の URL]
  local d="$TMPROOT/$1"
  mkdir -p "$d" && git -C "$d" init -q
  [ -n "${2:-}" ] && git -C "$d" remote add origin "$2"
  printf '%s' "$d"
}

# 期待(deny|allow) cwd コマンド。判定は permissionDecision:deny の部分一致。
expect() {
  local want=$1 cwd=$2 cmd=$3 out
  out=$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
        "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        "$(printf '%s' "$cwd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        | bash "$SCRIPT")
  if [ "$want" = deny ]; then
    grep -q '"permissionDecision":"deny"' <<<"$out" \
      || { echo "deny を期待したが違った / want=$want cwd=$cwd 入力: $cmd / out=[$out]" >&2; return 1; }
  else
    ! grep -q '"permissionDecision":"deny"' <<<"$out" \
      || { echo "allow を期待したが違った / want=$want cwd=$cwd 入力: $cmd / out=[$out]" >&2; return 1; }
  fi
}

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/guard-unsandboxed-pytest.sh"
    # 対象かどうかはフックが origin の URL だけで決める。実在するリポジトリのパスを
    # 書くと、このファイルが chezmoi で配られた先の機械にそのパスが無く、
    # git -C が失敗してフックが exit 0 で素通りする。deny を期待する側が全部 FAIL し、
    # allow を期待する側は「止めなかった」ではなく「判定に到達しなかった」で通る。
    TMPROOT=$(mktemp -d /tmp/guard-pytest-test.XXXXXX)
    REPO=$(mkrepo penguinEx git@github.com:haoblackj/penguinEx.git)
    CHEZMOI=$(mkrepo dotfiles https://github.com/haoblackj/dotfiles.git)
    OUT1=$(mkrepo kikimimi https://github.com/haoblackj/kikimimi.git)
    OUT2=$(mkrepo comfy-batch-runner https://github.com/haoblackj/comfy-batch-runner.git)
    OUT3=$(mkrepo oratorio https://github.com/haoblackj/oratorio.git)
    OUT4=$(mkrepo wikiwalk https://github.com/haoblackj/wikiwalk.git)
    NOGIT="$TMPROOT/nogit"; mkdir -p "$NOGIT"   # git 管理下ですらない場所
}

teardown() {
    rm -rf -- "$TMPROOT"
}

@test "対象リポジトリの中で止める" {
    local cmd
    for cmd in \
        'python3 -m pytest tests/ -q' \
        'pytest tests/foo.py' \
        'python tests/test_foo.py' \
        'python3 tests/test_fetch_profile.py' \
        'env FOO=1 pytest tests/' \
        'timeout 60 python3 -m pytest tests/' \
        'nohup pytest tests/' \
        'uv run pytest tests/' \
        'poetry run pytest tests/' \
        'PYTHONPATH=x python3 -m pytest tests/' \
        'bwrap --ro-bind / / -- pytest tests/' \
        'cd /repo && python3 -m pytest -q'; do
        expect deny "$REPO" "$cmd"
    done
}

@test "対象リポジトリの中でも通す" {
    local cmd
    for cmd in \
        'verify-tests /repo --strict' \
        'verify-tests /repo -- tests/test_foo.py -k some_case' \
        'python3 scripts/setup_env.py' \
        'grep -n "pytest" docs/plan.md'; do
        expect allow "$REPO" "$cmd"
    done
}

@test "対象外では止めない" {
    expect allow "$OUT1" 'pytest tests/'
    expect allow "$OUT2" 'pytest tests/'
    expect allow "$OUT3" 'python3 tests/test_foo.py'
    expect allow "$OUT4" 'uv run pytest tests/'
    expect allow "$NOGIT" 'python3 -m pytest tests/'
}

@test "chezmoi のソースでも対象として止める" {
    expect deny "$CHEZMOI" 'python3 -m pytest dot_claude/hooks/tests/'
}

@test "名前の規約から外れるファイルは止めない" {
    expect allow "$REPO" 'python3 manifest_test_helper.py'
    expect allow "$REPO" 'python3 mytest_foo.py'
}

# 元ファイルは *.test.sh なので shell レーンの対象に入り、サンドボックスの中でも
# 走っていた。サンドボックスの HOME は使い捨てなので ~/.local/bin は存在せず、
# verify-tests を呼べない。呼べないまま比較すると3件とも FAIL して非0になり、
# base に無い新規の赤として regression に拾われる。呼べないときは skip する。
@test "正規化が verify-tests と一致する" {
    if ! command -v verify-tests >/dev/null 2>&1; then
        skip "verify-tests が PATH にない"
    fi
    local u a b
    for u in https://github.com/haoblackj/penguinEx \
             https://github.com/haoblackj/dotfiles.git \
             git@github.com:haoblackj/penguinEx.git; do
        a=$(verify-tests --selftest-normalize "$u" 2>/dev/null)
        b=$(printf '%s' "$u" | sed -E 's#^[a-z]+://##; s#^[^@]*@##; s#^[^/:]+[:/]##; s#\.git$##; s#/$##')
        [ "$a" = "$b" ] || { echo "正規化が不一致: u=$u tool=[$a] hook=[$b]" >&2; return 1; }
    done
}
