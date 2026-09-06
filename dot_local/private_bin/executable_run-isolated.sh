#!/usr/bin/env bash
# 既存の verify-tests が持つ bwrap 隔離だけを切り出したラッパー。
# 任意のコマンドを隔離の中で走らせ、その終了コードをそのまま返す。
# 詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。
#
# 骨格（層1 Task 1）。build_bwrap / RO_BINDS / make_sandbox_home は
# ~/.local/share/chezmoi/dot_local/private_bin/executable_verify-tests の
# 実物を読んで同じ構成を再現している。あちらは変更しない。
#
# 出力の取り出し口（層1 Task 2）。隔離の中の $COVERAGE_OUT_DIR
# （= $HOME/out）へ書かれたものを、--out 指定時にホスト側へコピーする。
# COVERAGE_OUT_DIR という名前は後続タスクのカバレッジ設定が字面で使うため、
# 変更しない。
set -uo pipefail

usage() {
    echo "使い方: run-isolated.sh <repo> [--out <dir>] -- <コマンド...>" >&2
}

if [ "$#" -lt 1 ]; then
    usage
    exit 2
fi

repo=$1
shift

out_dir=""
if [ "${1-}" = "--out" ]; then
    shift
    if [ "$#" -eq 0 ]; then
        usage
        exit 2
    fi
    out_dir=$1
    shift
fi

if [ "${1-}" != "--" ]; then
    usage
    exit 2
fi
shift

if [ "$#" -eq 0 ]; then
    usage
    exit 2
fi

# 実物の verify-tests の RO_BINDS を書き写した。読み取り専用で渡す場所。
RO_BINDS=(
    "$HOME/.claude/hooks"
    "$HOME/.local/share/chezmoi/dot_claude/private_settings.json"
)

# 実物の verify-tests の FIXTURE_PROJECT を書き写した。
# test_memory_recall.py がこの名前を字面で持っているため、変えると
# 実在チェックが通らない（実物のコメントより）。
FIXTURE_PROJECT="-home-yagu001-repo-github-com-haoblackj-penguinEx"

# 実物の make_sandbox_home() を書き写した。使い捨ての HOME を作り、
# memory のフィクスチャを1つ置く。
sandbox=$(mktemp -d -t run-isolated-sandbox.XXXXXX) || exit 1
cleanup() {
    rm -rf -- "$sandbox"
}
trap cleanup EXIT

mkdir -p "$sandbox/.claude/projects/$FIXTURE_PROJECT/memory"

# コマンドが COVERAGE_OUT_DIR へ書いたものを走行後に取り出す置き場。
# --out の有無に関わらず用意する（中のコマンドは --out を意識しなくてよい）。
mkdir -p "$sandbox/out"

# 実物の build_bwrap() を書き写した。ホスト全体を読み取り専用にし、
# HOME だけをサンドボックスへ差し替える。--ro-bind で HOME を被せると
# Read-only file system で HOME 配下への書き込みがすべて失敗するので、
# --bind で書き込み可能に戻す。
bwrap_argv=(
    bwrap
    --ro-bind / /
    --dev /dev --proc /proc --tmpfs /tmp
    --bind "$sandbox" "$HOME"
)

for p in "${RO_BINDS[@]}"; do
    if [ -e "$p" ]; then
        bwrap_argv+=(--ro-bind "$p" "$p")
    fi
done

bwrap_argv+=(--setenv COVERAGE_OUT_DIR "$HOME/out")

bwrap_argv+=(--ro-bind "$repo" "$repo")

# 実物の git_common_dir() 相当。ワークツリーで git が動くために要る。
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
git_rc=$?
if [ "$git_rc" -ne 0 ]; then
    common=""
fi
case "$common" in
    "$repo"/*) common="" ;;
esac
if [ -n "$common" ] && [ -e "$common" ]; then
    bwrap_argv+=(--ro-bind "$common" "$common")
fi

# `--` の後ろをそのまま渡す。引数を解釈しない。pytest 専用の口にしない。
bwrap_argv+=(--chdir "$repo" -- "$@")

"${bwrap_argv[@]}"
rc=$?

# サンドボックスを消す前（trap cleanup が走る前）にコピーする。
# 中のコマンドが失敗していても（rc が非0でも）、それまでに書かれた
# 出力はここでコピーする。
#
# mkdir/cp の失敗を握りつぶさない。--out の指す先が書き込み不可等で
# コピーできなかった場合は必ず stderr へ警告を出す。
# 終了コードの扱い（層1 Task 2 レビュー指摘対応）:
#   - 中のコマンドが失敗していた場合（rc != 0）は、その rc をそのまま
#     優先して返す。中のコマンドの終了コードは Task 1 からの土台の
#     要件であり、取り出し失敗の警告は別途 stderr で分かるため、
#     ここで rc を上書きしない。
#   - 中のコマンドが成功していた場合（rc == 0）は、取り出しが失敗した
#     まま 0 を返すと「正常終了」と区別が付かず、カバレッジのデータが
#     静かに欠損する。そのため専用の終了コード 3（予約）を返す。
extract_failed=0
if [ -n "$out_dir" ]; then
    if ! mkdir -p "$out_dir"; then
        echo "run-isolated.sh: 警告: --out の指す先 '$out_dir' を作成できません" >&2
        extract_failed=1
    elif ! cp -a "$sandbox/out/." "$out_dir/"; then
        echo "run-isolated.sh: 警告: '$sandbox/out' から '$out_dir' への出力のコピーに失敗しました" >&2
        extract_failed=1
    fi
fi

if [ "$extract_failed" -eq 1 ] && [ "$rc" -eq 0 ]; then
    exit 3
fi

exit "$rc"
