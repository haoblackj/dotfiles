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
#
# 本番資産の mtime 差分（層1 Task 3）。走行の前後で監視対象（DEFAULT_WATCHED）の
# 更新時刻を比べ、変わっていれば報告する。bwrap の読み取り専用が予防、これは
# それをすり抜けた書き込みに気づくための網。監視対象・除外の既定値は
# ~/.local/share/chezmoi/dot_local/private_bin/executable_verify-tests の
# DEFAULT_WATCHED / DEFAULT_WATCHED_EXCLUDE を書き写している。あちらは
# 変更しない。環境変数 VERIFY_TESTS_WATCHED / VERIFY_TESTS_WATCHED_EXCLUDE
# （実物と同じ名前）で差し替えられる。
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

# カバレッジを取れる python 一式（層1 Task 5）。venv 本体は git 管理外
# （置き場所と要求パッケージは ~/.local/bin/test-requirements.txt を参照）。
# venv は $HOME 配下にあるため、下の --bind による HOME 差し替えで隠れる。
# RO_BINDS へ加えることで読み取り専用のまま見せ直す（HOME 差し替えより後に
# 適用されるので、RO_BINDS の他エントリと同じ理屈で上書きされない）。
# venv のパスはここ1箇所にしか書かない。
VENV_DIR="$HOME/.local/share/penguinex-test-venv"

# 実物の verify-tests の RO_BINDS を書き写した。読み取り専用で渡す場所。
RO_BINDS=(
    "$HOME/.claude/hooks"
    "$HOME/.local/share/chezmoi/dot_claude/private_settings.json"
    "$VENV_DIR"
)

# 実物の verify-tests の FIXTURE_PROJECT を書き写した。
# test_memory_recall.py がこの名前を字面で持っているため、変えると
# 実在チェックが通らない（実物のコメントより）。
FIXTURE_PROJECT="-home-yagu001-repo-github-com-haoblackj-penguinEx"

# --- 本番資産の mtime 差分（層1 Task 3） ---------------------------------

# 実物の verify-tests の DEFAULT_WATCHED を書き写した。監視対象。
DEFAULT_WATCHED=(
    "$HOME/.claude/logs/memory-recall.log*"
    "$HOME/.claude/projects/*/memory/.embeddings.json*"
    "$HOME/.claude/projects/*/memory/*.md"
    "$HOME/.local/share/chezmoi"
)

# 実物の verify-tests の DEFAULT_WATCHED_EXCLUDE を書き写した。
# 判定に算入しないもの。memory_recall.py が UserPromptSubmit フックとして
# 書くため、他のセッションのプロンプトで日常的に変わる。除外しないと
# 「何も書き換えなければ報告が空」が他のセッションの動きで揺れる。
DEFAULT_WATCHED_EXCLUDE=(
    "$HOME/.claude/logs/memory-recall.log*"
    "$HOME/.claude/projects/*/memory/.embeddings.json*"
    "$HOME/.claude/projects/*/memory/*.md"
)

# 監視対象の変化を判定に算入した場合の終了コード。0（成功）/1（サンドボックス
# 作成失敗）/2（使い方の誤り）/3（取り出しの失敗）と衝突させない。
MUTATION_DETECTED_EXIT=4

# 環境変数（改行区切り）が設定されていれば（空文字列でも）それを使い、
# 未設定なら既定値を使う。実物の _env_list と同じ働き。空文字列を明示的に
# 渡すと「何も監視しない」を表せる。
watched_env_or_default() {
    local var_name="$1"
    shift
    if [ -n "${!var_name+x}" ]; then
        local content="${!var_name}"
        local line
        while IFS= read -r line; do
            [ -n "$line" ] && printf '%s\n' "$line"
        done <<<"$content"
    else
        printf '%s\n' "$@"
    fi
}

# 標準入力からパターン（1行1つ）を読み、実在するファイルへ展開する。
# ディレクトリは中の全ファイルへ再帰的に展開する（.git は除く）。
# 実物の _expand と同じ働き。
expand_watched_patterns() {
    local pat hit
    shopt -s nullglob
    while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        for hit in $pat; do
            if [ -d "$hit" ]; then
                find "$hit" -name .git -prune -o -type f -print
            elif [ -e "$hit" ]; then
                printf '%s\n' "$hit"
            fi
        done
    done
    shopt -u nullglob
}

# 監視のパターン一覧（展開前）が空かどうか。空のまま黙って「変化なし」の
# 顔で0を返すと、「監視していない」と「監視した上で変化が無かった」が
# 区別できない。
watched_pattern_list_empty() {
    local n
    n=$(watched_env_or_default VERIFY_TESTS_WATCHED "${DEFAULT_WATCHED[@]}" | grep -c .)
    [ "$n" -eq 0 ]
}

watched_files() {
    watched_env_or_default VERIFY_TESTS_WATCHED "${DEFAULT_WATCHED[@]}" \
        | expand_watched_patterns | sort -u
}

excluded_watched_files() {
    watched_env_or_default VERIFY_TESTS_WATCHED_EXCLUDE "${DEFAULT_WATCHED_EXCLUDE[@]}" \
        | expand_watched_patterns | sort -u
}

# 監視対象の現在の状態を「更新時刻(ナノ秒) サイズ」を値に、パスをキーに
# 呼び出し側の連想配列（第1引数の変数名）へ書き込む。実在しないパスは
# 記録しない（実物の try/except OSError: continue と同じ）。
snapshot_watched() {
    local -n out_ref="$1"
    out_ref=()
    local files=() f
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(watched_files)
    [ "${#files[@]}" -eq 0 ] && return 0
    local mtime size path
    while read -r mtime size path; do
        [ -z "$path" ] && continue
        # out_ref は呼び出し元の連想配列を指す nameref の出力引数。呼び出し元でしか読まれないため、この関数の中では未使用に見える(既知の誤検出)。
        # shellcheck disable=SC2034
        out_ref["$path"]="$mtime $size"
    done < <(stat -c '%.9Y %s %n' "${files[@]}" 2>/dev/null)
}

# 前後のスナップショット（第1・第2引数の連想配列名）を比べ、監視対象の変化を
# 「判定に算入するもの」（第3引数）と「但し書き」（第4引数、除外に当たる変化。
# 黙って捨てない）に分ける。実物の diff_watched と同じ働き。
diff_watched() {
    local -n before_ref="$1"
    local -n after_ref="$2"
    local -n counted_ref="$3"
    local -n noted_ref="$4"
    counted_ref=()
    noted_ref=()
    local -A excluded=()
    local p
    while IFS= read -r p; do
        [ -n "$p" ] && excluded["$p"]=1
    done < <(excluded_watched_files)
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        local b="${before_ref[$p]-__run_isolated_missing__}"
        local a="${after_ref[$p]-__run_isolated_missing__}"
        [ "$b" = "$a" ] && continue
        if [ -n "${excluded[$p]+x}" ]; then
            noted_ref+=("$p")
        else
            counted_ref+=("$p")
        fi
    done < <(
        {
            for p in "${!before_ref[@]}"; do printf '%s\n' "$p"; done
            for p in "${!after_ref[@]}"; do printf '%s\n' "$p"; done
        } | sort -u
    )
}

if watched_pattern_list_empty; then
    echo "run-isolated.sh: 監視対象なし（何も監視していません）" >&2
fi

# watched_before は snapshot_watched/diff_watched へ変数名として渡し、nameref経由で間接的に読み書きする。直接の "$watched_before" 展開が無いため未使用に見える(既知の誤検出)。
# shellcheck disable=SC2034
declare -A watched_before=()
snapshot_watched watched_before

# --------------------------------------------------------------------------

# 実物の make_sandbox_home() を書き写した。使い捨ての HOME を作り、
# memory のフィクスチャを1つ置く。
sandbox=$(mktemp -d -t run-isolated-sandbox.XXXXXX) || exit 1
# 直後の trap cleanup EXIT から間接的に呼ばれる。直接の呼び出しが無いため未使用に見える(既知の誤検出)。
# shellcheck disable=SC2329
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

# venv の bin を PATH の先頭へ差し込む。「見える」（RO_BINDS）だけでは
# 中で走るコマンドが venv の python を選ばない。python も pytest もこれで
# venv のものになる。
bwrap_argv+=(--setenv PATH "$VENV_DIR/bin:$PATH")

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

# 層1 Task 3: 走行の前後で監視対象の更新時刻を比べる。
# --out の取り出し（上のブロック）が終わった後で「後」のスナップショットを
# 取る。取り出し自体が監視対象へ書く経路になりうるため、その分も見る。
# watched_after も watched_before と同じ理由(nameref越しの間接参照のみ)。
# shellcheck disable=SC2034
declare -A watched_after=()
snapshot_watched watched_after

declare -a mutation_counted=()
declare -a mutation_noted=()
diff_watched watched_before watched_after mutation_counted mutation_noted

for p in "${mutation_counted[@]}"; do
    echo "run-isolated.sh: 本番へ書いた: $p" >&2
done
for p in "${mutation_noted[@]}"; do
    echo "run-isolated.sh: 変化（判定に算入しない）: $p" >&2
done

# 優先順位: 中のコマンドの終了コード（rc != 0）を最優先でそのまま返す
# （Task 2 と同じ理由）。rc == 0 のときだけ、この道具自身が検出した異常
# （監視対象への書き込み／取り出しの失敗）を専用コードへ差し替える。
# 両方同時に起きた場合は、監視対象への書き込みの方を優先して報告する
# （本番資産の保護がカバレッジの取り出しより重い）。
if [ "$rc" -eq 0 ] && [ "${#mutation_counted[@]}" -gt 0 ]; then
    exit "$MUTATION_DETECTED_EXIT"
fi

if [ "$extract_failed" -eq 1 ] && [ "$rc" -eq 0 ]; then
    exit 3
fi

exit "$rc"
