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
#   - bats が非0で終われば、ok / not ok に現れていなくても非0
#
# 要約行の契約（この行だけを読む機械のために決めてある）:
#
#   run-bats-gate.sh: shell files=N tests=N ok=N skip=N fail=N status=ok|fail jobs=N excluded=N
#
#   - excluded= は --exclude で外した本数。files= は外した後の本数。
#   - jobs= は並行で走らせた本数（1 なら直列）。判定には関わらない情報で、
#     所要が説明できるように出している。**必ず status= の後ろに置く**
#     （前へ入れると status= までを部分一致で読む消費側が壊れる）。
#   - bats を走らせた経路では必ずこの1行を出す。**status= が判定そのもので、
#     status=ok は終了コード0と、status=fail は非0と必ず一致する。**件数だけを
#     見ると、bats が非0で終わった経路やプラン行を読めなかった経路が
#     「files=1 tests=1 ok=1 skip=0 fail=0」の全緑に見えてしまう。
#   - bats を走らせる前に落ちる経路（道具が無い・対象0本・使い方の誤り・
#     リポジトリでない）は、要約行を出さずに非0で終わる。**消費側は
#     「要約行が無い」を失敗として扱うこと。**件数が取れないことと
#     「0件で通った」を混同しない。
#
# 終了コード: 0 全部通った / 1 落ちた・道具無し・対象0本・集計不整合・
# bats が非0 / 2 使い方の誤り・リポジトリでない
set -uo pipefail

# git がフックへ渡す GIT_* を落とす。**この門は pre-push フックとして走る。**
# ワークツリーから push すると git は GIT_DIR をフックへ渡し（実測。通常の
# チェックアウトからの push では渡らない）、それがテストの中の使い捨て
# リポジトリへの git 操作まで届いて、別のリポジトリを触りに行く。実際に
# 11件が「そんな設定ファイルは無い」で落ちた。
# 残す名前は pre-commit の no_git_env（pre_commit/git.py）に合わせた。
# これらは git の場所や認証の設定で、リポジトリの場所を指さない。
for _var in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
    case "$_var" in
        GIT_EXEC_PATH|GIT_SSH|GIT_SSH_COMMAND|GIT_SSL_CAINFO|GIT_SSL_NO_VERIFY) ;;
        GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) ;;
        GIT_HTTP_PROXY_AUTHMETHOD|GIT_ALLOW_PROTOCOL|GIT_ASKPASS) ;;
        *) unset "$_var" ;;
    esac
done
unset _var

usage() {
    echo "使い方: run-bats-gate.sh <repo> [--exclude <pathspec>]..." >&2
}

# --exclude は git の pathspec（リポジトリのルートからの相対）で、複数回渡せる。
# pre-push から外して CI へ寄せる .bats を指定する用途（penguinEx #27、2026-09-12）。
# 除外した本数は要約行の excluded= に出す。全部除外して0本になれば、対象0本と
# 同じく非0で落ちる（除外で門が空になったことを黙って緑にしない）。
if [ "$#" -lt 1 ]; then
    usage
    exit 2
fi
repo=$1
shift
excludes=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --exclude)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                usage
                exit 2
            fi
            excludes+=(":(exclude)$2")
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if ! git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "run-bats-gate.sh: git リポジトリではない: $repo" >&2
    exit 2
fi

if ! command -v bats >/dev/null 2>&1; then
    echo "run-bats-gate.sh: bats が PATH にありません。道具が無いので門を通せません" >&2
    exit 1
fi

tracked_total=$(git -C "$repo" ls-files -z -- '*.bats' | tr -cd '\0' | wc -c)
files=()
while IFS= read -r -d '' f; do
    files+=("$f")
done < <(git -C "$repo" ls-files -z -- '*.bats' "${excludes[@]}")
excluded=$((tracked_total - ${#files[@]}))

if [ "${#files[@]}" -eq 0 ]; then
    echo "run-bats-gate.sh: 追跡された .bats が0本。対象が無いので門を通せません: $repo" >&2
    exit 1
fi

# 並行実行の本数を決める。bats --jobs は GNU parallel と flock を要求し、
# どちらも欠けると bats 自身がエラーで止まる（この門はそれを status=fail で
# 拾うが、走らないよりは直列で走るほうがよい）。**道具が無いときに直列へ
# 落ちるのは「検査を飛ばす」ことではない。**走る .bats も判定も同じで、
# 変わるのは所要だけ。どちらで走ったかは要約行の jobs= に出す。
#
# ファイルの中も並行にする（bats --jobs の既定）。ファイル内の並行に耐えない
# ファイルは、そのファイル自身が bats 公式の BATS_NO_PARALLELIZE_WITHIN_FILE=true を
# 置いて直列を宣言する（chezmoi の dot_claude/hooks/stop-fabricated-turn-guard.bats が
# 固定パスの guard.log を共有するため、これを置いている）。以前は
# --no-parallelize-within-files で全体を直列にしていたが、penguinEx の門は
# collect-reviews.bats 1本（61件、合計 214 秒）が所要を決めており、ファイル単位の
# 並行では縮まらなかった。
#
# 実測（2026-09-12、16コアの WSL）:
#   penguinEx 14本 413件  ファイル単位のみ 218秒 / ファイル内も並行 74秒（2回とも緑）
#   chezmoi   17本 238件  直列 22秒 / ファイル単位のみ 10秒（緑）
# 上限を8にしているのはこの実測値の設定。
jobs=1
if command -v parallel >/dev/null 2>&1 && command -v flock >/dev/null 2>&1; then
    cpus=$(nproc 2>/dev/null || echo 1)
    case "$cpus" in
        ''|*[!0-9]*) cpus=1 ;;
    esac
    if [ "$cpus" -gt 8 ]; then
        cpus=8
    fi
    jobs=$cpus
fi

# 端末に繋がっていると bats は pretty 形式を選ぶので、数えるために TAP を明示する。
if [ "$jobs" -gt 1 ]; then
    tap=$(cd "$repo" && bats --formatter tap --jobs "$jobs" "${files[@]}" 2>&1)
else
    tap=$(cd "$repo" && bats --formatter tap "${files[@]}" 2>&1)
fi
bats_rc=$?
printf '%s\n' "$tap"

plan=$(printf '%s\n' "$tap" | grep -m1 -E '^1\.\.[0-9]+$' | sed -E 's/^1\.\.//')
ok_total=$(printf '%s\n' "$tap" | grep -cE '^ok [0-9]+')
skipped=$(printf '%s\n' "$tap" | grep -cE '^ok [0-9]+ .*# skip')
failed=$(printf '%s\n' "$tap" | grep -cE '^not ok [0-9]+')
passed=$((ok_total - skipped))

# 判定を先に出し切ってから要約行を出す。先に要約行を出すと、落ちる経路でも
# 「fail=0」の全緑に見える行が残る（要約行だけを読む消費側がそれを成功と読む）。
gate_status=ok
reason=""
if [ -z "$plan" ]; then
    gate_status=fail
    reason="TAP のプラン行（1..N）が読めない。bats の出力を数えられません"
elif [ "$((ok_total + failed))" -ne "$plan" ]; then
    gate_status=fail
    reason="集計が合わない: プラン $plan 件に対し ok $ok_total + not ok $failed"
elif [ "$failed" -ne 0 ]; then
    # not ok がある経路。bats が非0を返さなくてもここで落とす。
    reason="not ok が $failed 件ある"
    gate_status=fail
elif [ "$bats_rc" -ne 0 ]; then
    # ok / not ok には現れないのに bats が非0を返した経路（起動できなかった、
    # 途中で死んだ、など）。件数の整合だけを見ていると全緑に見える。
    gate_status=fail
    reason="bats が非0（rc=$bats_rc）で終わった。ok / not ok に現れない失敗がある"
fi

echo "run-bats-gate.sh: shell files=${#files[@]} tests=${plan:-?} ok=$passed skip=$skipped fail=$failed status=$gate_status jobs=$jobs excluded=$excluded"

if [ "$gate_status" != ok ]; then
    echo "run-bats-gate.sh: $reason" >&2
    exit 1
fi
exit 0
