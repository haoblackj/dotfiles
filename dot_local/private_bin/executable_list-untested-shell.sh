#!/usr/bin/env bash
# 追跡 .sh のうちテストを持たないものを列挙する。penguinEx・chezmoi 両方の
# pre-commit フック（stage: pre-push、フック id: list-untested-shell）から
# 呼ぶ。引数でリポジトリを複数受け取り、1つの一覧にまとめる（issue #16、
# テスト基盤の層2 Task 9）。詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。
#
# 判定は「テストを持つか」を .bats の命名規約から導く（層4b Task 9で
# # mutation-target: 宣言から切り替え済み）。`<dir>/<name>.bats` は、
# 同じディレクトリの次のいずれかを対象とみなす:
#   <name>.sh / <name>.py / executable_<name>.sh / executable_<name>.py
# （executable_ 接頭辞は chezmoi のソースツリーで、配置時に外れるため
# 候補に含める。.py も候補にする — commit-verification-judge.py や
# stop-fabricated-turn-guard.py のように対象が Python の .bats がある）。
# 候補のいずれかが追跡されていれば、その実装は「テストを持つ」として
# 一覧から除く。対応する候補が無い .bats（e2e-integration.bats、
# settings-wiring.bats など）は何も除外しない。
#
# 一覧は非0では終わらない（このスクリプトが数え上げるものはこの計画の
# スコープ外のバックログであり、pre-commit の失敗にすると毎回止まって
# フックが無効化される方向へ圧力がかかるため）。
set -uo pipefail

usage() {
    echo "使い方: list-untested-shell.sh <repo> [<repo> ...]" >&2
}

if [ "$#" -lt 1 ]; then
    usage
    exit 2
fi

is_test_file() {
    local relpath="$1"
    local base
    base=$(basename -- "$relpath")
    case "$base" in
        *.test.sh) return 0 ;;
        test_*.sh) return 0 ;;
    esac
    return 1
}

# .bats ファイル1本について、命名規約が導く対象候補を列挙する。
# 存在確認はしない（呼び出し側が追跡ファイル集合と突き合わせる）。
bats_target_candidates() {
    local batspath="$1"
    local dir name
    dir=$(dirname -- "$batspath")
    name=$(basename -- "$batspath" .bats)
    printf '%s\n' \
        "$dir/$name.sh" \
        "$dir/$name.py" \
        "$dir/executable_$name.sh" \
        "$dir/executable_$name.py"
}

process_repo() {
    local repo_abs="$1"

    local -a all_sh=()
    local p
    while IFS= read -r p; do
        [ -n "$p" ] && all_sh+=("$p")
    done < <(git -C "$repo_abs" ls-files '*.sh')

    local -a all_bats=()
    while IFS= read -r p; do
        [ -n "$p" ] && all_bats+=("$p")
    done < <(git -C "$repo_abs" ls-files '*.bats')

    # 追跡ファイル集合（.sh と .py）。.bats の対象候補がここに
    # あるかどうかで「テストを持つか」を判定する。
    local -A tracked=()
    while IFS= read -r p; do
        [ -n "$p" ] && tracked["$p"]=1
    done < <(git -C "$repo_abs" ls-files '*.sh' '*.py')

    # ステップ2: .bats の命名規約から対象候補を導き、追跡されている
    # ものだけを除外対象に数える。
    local -A excluded=()
    local t
    for p in "${all_bats[@]}"; do
        while IFS= read -r t; do
            [ -n "$t" ] && [ -n "${tracked[$t]+x}" ] && excluded["$t"]=1
        done < <(bats_target_candidates "$p")
    done

    # ステップ1・3: 追跡 .sh からテストファイル自身を除き、さらに
    # .bats の命名規約が指す対象を除いたものが「テストが無い実装」。
    for p in "${all_sh[@]}"; do
        is_test_file "$p" && continue
        [ -n "${excluded[$p]+x}" ] && continue
        printf '%s\n' "$repo_abs/$p"
    done
}

declare -A seen_repo=()
declare -a results=()

for repo_arg in "$@"; do
    if [ ! -d "$repo_arg" ]; then
        echo "list-untested-shell.sh: リポジトリが見つかりません: $repo_arg" >&2
        exit 2
    fi
    repo_abs=$(cd "$repo_arg" && pwd -P) || exit 2
    if [ -n "${seen_repo[$repo_abs]+x}" ]; then
        continue
    fi
    seen_repo["$repo_abs"]=1

    while IFS= read -r line; do
        [ -n "$line" ] && results+=("$line")
    done < <(process_repo "$repo_abs")
done

if [ "${#results[@]}" -gt 0 ]; then
    printf '%s\n' "${results[@]}" | sort
fi

exit 0
