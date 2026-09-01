#!/usr/bin/env bash
# Claude Code から Codex へ委譲するときの唯一の入口。
#
# 設計は penguinEx の docs/superpowers/specs/2026-08-31-codex-role-separation-design.md。
#
# これが在る理由は二つ。
#   1. 委譲契約とリポジトリ側の知識を連結する作業をスクリプトの責任にする。
#      呼び出し側の規律に頼ると、契約や知識の含め忘れが静かに起きる。
#   2. --ignore-user-config と -c project_doc_max_bytes=0 の 2 つを必ず付ける。
#      片方でも落ちると、対話役の規則やリポジトリの AGENTS.md が二重に混ざる。
set -uo pipefail

die() { echo "NG: $*" >&2; exit 1; }

CONTRACT="${CODEX_DELEGATE_CONTRACT:-$HOME/.codex/delegation-contract.md}"
MODEL="${CODEX_DELEGATE_MODEL:-gpt-5.6-sol}"
SANDBOX="workspace-write"
REPO=""
OUTFILE=""
PRINT_ONLY=0
BRIEF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --print-command) PRINT_ONLY=1; shift ;;
    --repo)    REPO="${2:-}";    [ -n "$REPO" ]    || die "--repo に値がない"; shift 2 ;;
    -m|--model)   MODEL="${2:-}";   [ -n "$MODEL" ]   || die "-m に値がない";   shift 2 ;;
    -s|--sandbox) SANDBOX="${2:-}"; [ -n "$SANDBOX" ] || die "-s に値がない"; shift 2 ;;
    -o|--output-last-message) OUTFILE="${2:-}"; [ -n "$OUTFILE" ] || die "-o に値がない"; shift 2 ;;
    --) shift
        # 以降はフラグに見えても位置引数として扱う（POSIX の慣習）。
        while [ $# -gt 0 ]; do
          [ -z "$BRIEF" ] || die "ブリーフのファイルを 2 つ渡している: $BRIEF と $1"
          BRIEF="$1"; shift
        done
        ;;
    -*) die "知らないフラグ: $1" ;;
    *)  [ -z "$BRIEF" ] || die "ブリーフのファイルを 2 つ渡している: $BRIEF と $1"
        BRIEF="$1"; shift ;;
  esac
done

[ -n "$BRIEF" ] || die "ブリーフのファイルを渡すこと。使い方: $(basename "$0") [--repo DIR] [-m MODEL] [-s SANDBOX] [-o FILE] [--print-command] <brief-file>"
[ -f "$BRIEF" ] || die "ブリーフがファイルとして読めない: $BRIEF"

# 契約が無いまま委譲を走らせない。chezmoi apply が済んでいない状態が主な原因である。
[ -f "$CONTRACT" ] || die "委譲契約が無い: $CONTRACT (chezmoi apply ~/.codex/delegation-contract.md を実行する)"

# --repo が無ければ cwd から git のトップレベルを解決する。git の外なら cwd をそのまま使う。
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
[ -d "$REPO" ] || die "リポジトリのディレクトリが無い: $REPO"

# 連結。契約、リポジトリの AGENTS.md、AGENTS.delegate.md の順で、後ろが勝つ。
# 後ろの 2 本はどちらも無くてよい。無いことをエラーにしない。
parts=("$CONTRACT")
[ -f "$REPO/AGENTS.md" ]          && parts+=("$REPO/AGENTS.md")
[ -f "$REPO/AGENTS.delegate.md" ] && parts+=("$REPO/AGENTS.delegate.md")

# [ -f ] は読めることを意味しない。読めないまま cat すると、その 1 本が抜けた
# 起動コマンドが黙って出る。連結はスクリプトの責任なので、ここで止める。
for f in "${parts[@]}"; do
  [ -r "$f" ] || die "読めない: $f"
done

# 末尾に区切り行を置く。-c の値は末尾の 1 文字が黙って落ちる場合があるので、
# 落ちても内容に影響しない行で吸収する。
INSTRUCTIONS="$(cat "${parts[@]}")"$'\n\n---\n'

# 先頭が引用符だと TOML のパースで剥がれる。契約は見出しで始まるはずだが、機械で押さえる。
case "$INSTRUCTIONS" in
  \"*|\'*) die "連結結果が引用符で始まっている。-c の値として渡すと剥がれる" ;;
esac

cmd=(codex exec
  --ignore-user-config
  -c "developer_instructions=$INSTRUCTIONS"
  -c project_doc_max_bytes=0
  -m "$MODEL"
  -s "$SANDBOX"
  -C "$REPO"
  --json)
[ -n "$OUTFILE" ] && cmd+=(-o "$OUTFILE")
cmd+=(-)

if [ "$PRINT_ONLY" = "1" ]; then
  # 実行せず、組み立てた起動コマンドをシェルへ貼れる形で出す。
  # codex exec は --ignore-user-config を受け付けるが debug prompt-input は受け付けないため、
  # 配線の検証はこの出力を読むことでしか行えない。
  printf '%q ' "${cmd[@]}"
  printf '< %q\n' "$BRIEF"
  exit 0
fi

"${cmd[@]}" < "$BRIEF"
