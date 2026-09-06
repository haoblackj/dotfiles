#!/usr/bin/env bash
# 追跡 .sh のうちテストを持たないものを列挙する。penguinEx・chezmoi 両方の
# pre-commit フック（stage: pre-push、フック id: list-untested-shell）から
# 呼ぶ。引数でリポジトリを複数受け取り、1つの一覧にまとめる（issue #16、
# テスト基盤の層2 Task 9）。詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。
#
# 判定は「テストを持つか」を # mutation-target: 宣言から導く。宣言は
# *.test.sh / test_*.sh の2行目、および .bats の2行目に置く規約
# （実物は他の *.test.sh を参照）。`.bats` 自体には実装ファイルとの命名
# 対応の規約がまだ無い（層2時点で3本しか無い）ため、いまは宣言だけを
# 頼りにする。層4で .bats の命名規約（実装との対応づけ）が固まったら、
# read_mutation_target() をやめて命名規約ベースの対応づけへ切り替える。
# それまでは、.bats を足すたびに宣言を書き忘れると一覧を汚す
# （Task 9 自身がこの罠に落ちた。詳細は task-9-brief.md Step 4）。
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

# test ファイル（*.test.sh / test_*.sh / *.bats）から
# `# mutation-target: <path>` 宣言を読む。無ければ何も出力しない。
# 対象が "none" の宣言（対象を指さない）は除外に数えない。
read_mutation_target() {
    local file="$1"
    local line target
    line=$(grep -m1 '^# mutation-target: ' -- "$file" 2>/dev/null) || return 0
    target=${line#"# mutation-target: "}
    target=${target%% *}
    [ -z "$target" ] && return 0
    [ "$target" = "none" ] && return 0
    printf '%s\n' "$target"
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

    # ステップ2: mutation-target 宣言が指す対象を集める
    # （*.test.sh / test_*.sh と .bats の両方を走査する）。
    local -A excluded=()
    local t
    for p in "${all_sh[@]}"; do
        if is_test_file "$p"; then
            while IFS= read -r t; do
                [ -n "$t" ] && excluded["$t"]=1
            done < <(read_mutation_target "$repo_abs/$p")
        fi
    done
    for p in "${all_bats[@]}"; do
        while IFS= read -r t; do
            [ -n "$t" ] && excluded["$t"]=1
        done < <(read_mutation_target "$repo_abs/$p")
    done

    # ステップ1・3: 追跡 .sh からテストファイル自身を除き、さらに
    # mutation-target が指す対象を除いたものが「テストが無い実装」。
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
