#!/usr/bin/env bash
# codex-delegate.sh の判定が実際に効いていることを確かめる。
#
# 判定 1 件につき「止まるもの」と「通るもの」を対で置く。片方だけだと、
# 判定が何も見ていなくても緑になる。
#
# 使い方: ~/.codex/codex-delegate-selfcheck.sh
set -uo pipefail

W="${CODEX_DELEGATE:-$HOME/.codex/codex-delegate.sh}"
[ -x "$W" ] || { echo "NG: ラッパーが無いか実行できない: $W" >&2; exit 1; }

FAILED=0
pass() { echo "  OK   $*"; }
fail() { echo "  NG   $*" >&2; FAILED=1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --print-command の出力をシェルの配列へ戻す。末尾の `< <brief>` はリダイレクトに
# なるので落としてから eval する。文字列を検索して値を切り出す方法は使わない
# （渡す本文に同じ語が現れると黙って壊れる）。
CMD=()
build() {
  local out argv
  out=$("$W" --print-command "$@" 2>/dev/null) || return 1
  argv=${out%%< *}
  eval "CMD=($argv)"
}

# developer_instructions の値だけを取り出す。
di_value() {
  local a
  for a in "${CMD[@]}"; do
    case "$a" in
      developer_instructions=*) printf '%s' "${a#developer_instructions=}"; return 0 ;;
    esac
  done
  return 1
}

# CMD に指定のトークンがそのまま含まれるか。
has_token() {
  local want=$1 a
  for a in "${CMD[@]}"; do [ "$a" = "$want" ] && return 0; done
  return 1
}

CONTRACT="$TMP/contract.md"
BRIEF="$TMP/brief.md"
REPO="$TMP/repo"
mkdir "$REPO"
printf '%s\n' 'CONTRACT-BASE' > "$CONTRACT"
printf '%s\n' 'brief' > "$BRIEF"
export CODEX_DELEGATE_CONTRACT="$CONTRACT"

echo "=== 1. 委譲契約が無ければ止まり、あれば通る ==="
CODEX_DELEGATE_CONTRACT="$TMP/missing-contract.md" build --repo "$REPO" "$BRIEF" && fail "存在しない契約を通した" || pass "存在しない契約で止まる"
build --repo "$REPO" "$BRIEF" && pass "存在する契約で通る" || fail "存在する契約で止まった"

echo "=== 2. 連結する入力が読めなければ止まり、読めれば内容が載る ==="
printf '%s\n' 'READABLE-AGENTS-MARK' > "$REPO/AGENTS.md"
chmod 000 "$REPO/AGENTS.md"
build --repo "$REPO" "$BRIEF" && fail "読めない AGENTS.md を通した" || pass "読めない AGENTS.md で止まる"
chmod 644 "$REPO/AGENTS.md"
if build --repo "$REPO" "$BRIEF" && [[ "$(di_value)" == *READABLE-AGENTS-MARK* ]]; then
  pass "読める AGENTS.md の内容が載る"
else
  fail "読める AGENTS.md の内容が載らない"
fi
rm "$REPO/AGENTS.md"

echo "=== 3. ブリーフが無ければ止まり、あれば通る ==="
build --repo "$REPO" "$TMP/missing-brief.md" && fail "存在しないブリーフを通した" || pass "存在しないブリーフで止まる"
build --repo "$REPO" "$BRIEF" && pass "存在するブリーフで通る" || fail "存在するブリーフで止まった"

echo "=== 4. ブリーフがディレクトリなら止まり、ファイルなら通る ==="
build --repo "$REPO" "$TMP" && fail "ディレクトリのブリーフを通した" || pass "ディレクトリのブリーフで止まる"
build --repo "$REPO" "$BRIEF" && pass "ファイルのブリーフで通る" || fail "ファイルのブリーフで止まった"

echo "=== 5. 知らないフラグなら止まり、既知のフラグなら通る ==="
build --repo "$REPO" --unknown "$BRIEF" && fail "知らないフラグを通した" || pass "知らないフラグで止まる"
build --repo "$REPO" -m known-model "$BRIEF" && pass "既知のフラグで通る" || fail "既知のフラグで止まった"

echo "=== 6. ブリーフが 2 つなら止まり、1 つなら通る ==="
build --repo "$REPO" "$BRIEF" "$BRIEF" && fail "2 つのブリーフを通した" || pass "2 つのブリーフで止まる"
build --repo "$REPO" "$BRIEF" && pass "1 つのブリーフで通る" || fail "1 つのブリーフで止まった"

echo "=== 7. -- の後ろなら - で始まるブリーフ名が通る ==="
printf '%s\n' 'brief' > "$TMP/-brief.md"
(
  cd "$TMP" || exit 1
  build --repo "$REPO" -brief.md
) && fail "-- 無しで - から始まる名前を通した" || pass "-- 無しではフラグとして止まる"
(
  cd "$TMP" || exit 1
  build --repo "$REPO" -- -brief.md
) && pass "-- の後ろではブリーフとして通る" || fail "-- の後ろでもブリーフとして止まった"

echo "=== 8. 連結順は契約、AGENTS.md、AGENTS.delegate.md ==="
printf '%s\n' 'ORDER-CONTRACT' > "$CONTRACT"
printf '%s\n' 'ORDER-AGENTS' > "$REPO/AGENTS.md"
printf '%s\n' 'ORDER-DELEGATE' > "$REPO/AGENTS.delegate.md"
if build --repo "$REPO" "$BRIEF"; then
  DI=$(di_value)
  PREFIX=${DI%%ORDER-CONTRACT*}
  P1=${#PREFIX}
  PREFIX=${DI%%ORDER-AGENTS*}
  P2=${#PREFIX}
  PREFIX=${DI%%ORDER-DELEGATE*}
  P3=${#PREFIX}
  if [ "$P1" -lt "$P2" ] && [ "$P2" -lt "$P3" ]; then
    pass "3 本が指定順で載る"
  else
    fail "3 本の連結順が違う"
  fi
else
  fail "3 本を連結できない"
fi
rm "$REPO/AGENTS.delegate.md"
build --repo "$REPO" "$BRIEF" && [[ "$(di_value)" != *ORDER-DELEGATE* ]] && pass "無い AGENTS.delegate.md は載らない" || fail "無い AGENTS.delegate.md の扱いが誤っている"

echo "=== 9. developer_instructions は区切り行 --- で終わる ==="
build --repo "$REPO" "$BRIEF"
DI=$(di_value)
[[ "$DI" == *$'\n---' ]] && pass "区切り行で終わる" || fail "区切り行で終わらない"
[[ "$DI" != *$'\n---\n'* ]] && pass "区切り行の後に内容が無い" || fail "区切り行の後に内容がある"

echo "=== 10. 固定の設定フラグが必ず付く ==="
build --repo "$REPO" "$BRIEF"
has_token --ignore-user-config && pass "--ignore-user-config が付く" || fail "--ignore-user-config が無い"
has_token project_doc_max_bytes=0 && pass "project_doc_max_bytes=0 が付く" || fail "project_doc_max_bytes=0 が無い"

echo "=== 11. AGENTS.md が無いリポジトリでは契約だけが載る ==="
rm "$REPO/AGENTS.md"
printf '%s\n' 'CONTRACT-ONLY' > "$CONTRACT"
if build --repo "$REPO" "$BRIEF"; then
  DI=$(di_value)
  [[ "$DI" == $'CONTRACT-ONLY\n\n---' ]] && pass "契約だけが載る" || fail "契約以外の内容が載った"
else
  fail "AGENTS.md が無いとエラーになった"
fi
printf '%s\n' 'repo knowledge' > "$REPO/AGENTS.md"
build --repo "$REPO" "$BRIEF" && [[ "$(di_value)" == *'repo knowledge'* ]] && pass "AGENTS.md があれば載る" || fail "AGENTS.md があっても載らない"

echo "=== 12. -m / -s / -o の値がそのまま CMD に現れる ==="
MODEL_VALUE='model value'
SANDBOX_VALUE='sandbox value'
OUTPUT_VALUE="$TMP/output value.json"
if build --repo "$REPO" -m "$MODEL_VALUE" -s "$SANDBOX_VALUE" -o "$OUTPUT_VALUE" "$BRIEF"; then
  has_token "$MODEL_VALUE" && has_token "$SANDBOX_VALUE" && has_token "$OUTPUT_VALUE" && pass "3 つの値がそのまま現れる" || fail "3 つの値のいずれかが変わった"
else
  fail "3 つのオプションを組み立てられない"
fi
build --repo "$REPO" "$BRIEF" && ! has_token "$MODEL_VALUE" && ! has_token "$SANDBOX_VALUE" && ! has_token "$OUTPUT_VALUE" && pass "指定しなければ指定値は現れない" || fail "指定していない値が残った"

echo "=== 13. --repo が無ければ cwd の git トップレベルを使う ==="
GIT_TOP="$TMP/git-top"
mkdir -p "$GIT_TOP/subdir"
git -C "$GIT_TOP" init -q
printf '%s\n' 'GIT-TOP-MARK' > "$GIT_TOP/AGENTS.md"
(
  cd "$GIT_TOP/subdir" || exit 1
  build "$BRIEF" && has_token "$GIT_TOP" && [[ "$(di_value)" == *GIT-TOP-MARK* ]]
) && pass "cwd から git トップレベルを解決する" || fail "cwd から git トップレベルを解決できない"
NONGIT="$TMP/non-git/subdir"
mkdir -p "$NONGIT"
(
  cd "$NONGIT" || exit 1
  build "$BRIEF" && has_token "$NONGIT"
) && pass "git 外では cwd を使う" || fail "git 外で cwd を使えない"

echo
[ "$FAILED" -eq 0 ] && echo "すべて通った。" || { echo "落ちた判定がある。" >&2; exit 1; }
