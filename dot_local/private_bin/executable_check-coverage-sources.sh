#!/usr/bin/env bash
# 追跡 .py が pyproject.toml の [tool.coverage.run] の source/omit から
# 漏れていないかを検査する。penguinEx・chezmoi 両方の pre-commit フック
# （stage: pre-push、フック id: check-coverage-sources）から呼ぶ。
#
# 「git ls-files '*.py' の集合」と「source が拾う集合に omit を足したもの」を
# 比べ、どちらにも属さない追跡 .py があれば列挙して非0で終わる（issue #16、
# テスト基盤の層2 Task 7）。詳細は penguinEx の
# .superpowers/sdd/2026-09-06-test-foundation-layer1-2/ を参照。
set -uo pipefail

usage() {
    echo "使い方: check-coverage-sources.sh <repo>" >&2
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi

repo=$1

if [ ! -d "$repo" ]; then
    echo "リポジトリが見つかりません: $repo" >&2
    exit 2
fi

pyproject="$repo/pyproject.toml"
if [ ! -f "$pyproject" ]; then
    echo "pyproject.toml が見つかりません: $pyproject" >&2
    exit 2
fi

# [tool.coverage.run] セクションだけを取り出す（次の [ で始まる行の手前まで）。
run_section=$(awk '
    /^\[tool\.coverage\.run\]/ { flag = 1; next }
    /^\[/ { flag = 0 }
    flag { print }
' "$pyproject")

# source/omit の配列（`key = [` から `]` まで）に現れる引用符付き文字列を拾う。
# コメント行は引用符を含まないので、この抽出方法で自然に読み飛ばされる。
extract_array() {
    local key="$1"
    printf '%s\n' "$run_section" \
        | sed -n "/^${key} = \\[/,/^\\]/p" \
        | grep -oP '"\K[^"]+(?=")'
}

source_dirs=()
while IFS= read -r line; do
    [ -n "$line" ] && source_dirs+=("$line")
done < <(extract_array "source")

omit_files=()
while IFS= read -r line; do
    [ -n "$line" ] && omit_files+=("$line")
done < <(extract_array "omit")

missing=()
while IFS= read -r f; do
    [ -n "$f" ] || continue

    is_omit=0
    for o in "${omit_files[@]}"; do
        if [ "$f" = "$o" ]; then
            is_omit=1
            break
        fi
    done
    if [ "$is_omit" -eq 1 ]; then
        continue
    fi

    in_source=0
    for d in "${source_dirs[@]}"; do
        case "$f" in
            "$d"/*|"$d")
                in_source=1
                break
                ;;
        esac
    done
    if [ "$in_source" -eq 1 ]; then
        continue
    fi

    missing+=("$f")
done < <(git -C "$repo" ls-files '*.py')

if [ "${#missing[@]}" -gt 0 ]; then
    echo "coverage の source/omit から漏れている追跡 .py があります:" >&2
    for f in "${missing[@]}"; do
        echo "  $f" >&2
    done
    exit 1
fi

exit 0
