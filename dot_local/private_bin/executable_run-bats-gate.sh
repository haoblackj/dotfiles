#!/usr/bin/env bash
# リポジトリが追跡する .bats を全部、ソースツリーを起点に1回の bats で走らせる
# pre-push の門。penguinEx #38 層5 Task 2。
#
# 起点をソースツリーに固定する理由: 配置先（~/.local/bin/ や ~/.claude/hooks/）
# のコピーはコミットされたものではない。壊れたソースをコミットしても、門が
# 古い配置先のコピーを検査して通ってしまう。対象名が置き場所で変わる .bats は
# テスト側で両方の名前を試す（resolve_target）。
#
# 「黙って通る」を作らない:
#   - bats が PATH に無ければ非0（検査を飛ばしたのではなく、できなかった）
#   - 追跡された .bats が0本なら非0（対象が無いのに緑にしない）
#   - TAP のプラン行と ok / not ok の合計が食い違えば非0（途中で bats が
#     死んだ、あるいは出力を読めていない）
#   - skip は ok と分けて数えて出す（skip だけの本が緑に見えないように）
#
# 終了コード: 0 全部通った / 1 落ちた・道具無し・対象0本・集計不整合 /
# 2 使い方の誤り・リポジトリでない
set -uo pipefail

usage() {
    echo "使い方: run-bats-gate.sh <repo>" >&2
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi
repo=$1

if ! git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "run-bats-gate.sh: git リポジトリではない: $repo" >&2
    exit 2
fi

if ! command -v bats >/dev/null 2>&1; then
    echo "run-bats-gate.sh: bats が PATH にありません。道具が無いので門を通せません" >&2
    exit 1
fi

files=()
while IFS= read -r -d '' f; do
    files+=("$f")
done < <(git -C "$repo" ls-files -z -- '*.bats')

if [ "${#files[@]}" -eq 0 ]; then
    echo "run-bats-gate.sh: 追跡された .bats が0本。対象が無いので門を通せません: $repo" >&2
    exit 1
fi

# 端末に繋がっていると bats は pretty 形式を選ぶので、数えるために TAP を明示する。
tap=$(cd "$repo" && bats --formatter tap "${files[@]}" 2>&1)
bats_rc=$?
printf '%s\n' "$tap"

plan=$(printf '%s\n' "$tap" | grep -m1 -E '^1\.\.[0-9]+$' | sed -E 's/^1\.\.//')
ok_total=$(printf '%s\n' "$tap" | grep -cE '^ok [0-9]+')
skipped=$(printf '%s\n' "$tap" | grep -cE '^ok [0-9]+ .*# skip')
failed=$(printf '%s\n' "$tap" | grep -cE '^not ok [0-9]+')
passed=$((ok_total - skipped))

echo "run-bats-gate.sh: shell files=${#files[@]} tests=${plan:-?} ok=$passed skip=$skipped fail=$failed"

if [ -z "$plan" ]; then
    echo "run-bats-gate.sh: TAP のプラン行（1..N）が読めない。bats の出力を数えられません" >&2
    exit 1
fi
if [ "$((ok_total + failed))" -ne "$plan" ]; then
    echo "run-bats-gate.sh: 集計が合わない: プラン $plan 件に対し ok $ok_total + not ok $failed" >&2
    exit 1
fi
if [ "$bats_rc" -ne 0 ]; then
    exit 1
fi
if [ "$failed" -ne 0 ]; then
    exit 1
fi
exit 0
