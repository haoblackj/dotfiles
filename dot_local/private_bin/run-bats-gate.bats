#!/usr/bin/env bats
# run-bats-gate.sh が、追跡された .bats を全部走らせ、道具無し・対象0本・
# 集計不整合で黙って通らないことを確かめる。penguinEx #38 層5 Task 2。

# 対象の名前は置き場所で変わる。chezmoi のソース側では executable_run-bats-gate.sh、
# 配置先（~/.local/bin/）では run-bats-gate.sh。pre-push の門はコミットされた
# ものを検査するためソースツリーで走らせるので、両方を試す。どちらも無ければ
# 落とす（黙って素通りさせない）。ソース側には実行ビットが無いので bash 経由で呼ぶ。
resolve_target() {
    local cand
    for cand in "$BATS_TEST_DIRNAME/$1" "$BATS_TEST_DIRNAME/executable_$1"; do
        if [ -f "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    echo "対象が見つからない: $BATS_TEST_DIRNAME/$1 も executable_$1 も無い" >&2
    return 1
}

setup() {
    GATE="$(resolve_target run-bats-gate.sh)"
    TMP="$(mktemp -d -t run-bats-gate-test.XXXXXX)"
}

teardown() {
    rm -rf -- "$TMP"
}

# 使い捨てのリポジトリを作る。.bats はコミットせず index に載せるだけで
# git ls-files に出る。
make_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
}

# 1件通る .bats を書く。
write_passing_bats() {
    cat > "$1" <<'EOF'
@test "通る" {
    true
}
EOF
}

# 1件落ちる .bats を書く。
write_failing_bats() {
    cat > "$1" <<'EOF'
@test "落ちる" {
    false
}
EOF
}

# 直前の run が出した要約行だけを取り出す。件数だけを読む消費側（Task 3 の
# /morning の収集はこの1行から件数を取る）と同じ読み方をテスト側で再現する。
summary_line() {
    printf '%s\n' "$output" | grep -m1 -E '^run-bats-gate\.sh: shell files='
}

# 1件 skip する .bats を書く。
write_skipping_bats() {
    cat > "$1" <<'EOF'
@test "飛ばす" {
    skip "検証用の skip"
}
EOF
}

@test "引数が無ければ使い方を出して 2 で落ちる" {
    run bash "$GATE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"使い方"* ]]
}

@test "git リポジトリでなければ 2 で落ちる" {
    mkdir -p "$TMP/notrepo"
    run bash "$GATE" "$TMP/notrepo"
    [ "$status" -eq 2 ]
    [[ "$output" == *"git リポジトリではない"* ]]
}

@test "bats が PATH に無ければ飛ばさずに 1 で落ちる" {
    # 受け入れ条件26の型。PATH を丸ごと潰すと #!/usr/bin/env bash の解決から
    # 失敗して「起動できなかった」を見てしまうので、bats だけを隠した PATH を作る。
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    mkdir -p "$TMP/bin"
    for tool in bash git grep sed; do
        ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
    done
    [ ! -e "$TMP/bin/bats" ]

    run env PATH="$TMP/bin" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bats が PATH にありません"* ]]
    # 「一覧が空だった」「全部通った」と読める文面ではないこと。
    [[ "$output" != *"tests="* ]]
}

@test "追跡された .bats が0本なら 1 で落ちる（対象が無いのに緑にしない）" {
    make_repo "$TMP/repo"
    # 追跡されていない .bats は対象に数えない。
    write_passing_bats "$TMP/repo/untracked.bats"
    run bash "$GATE" "$TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"0本"* ]]
}

@test "全部通れば 0 で、件数の要約に files と tests と ok が出る" {
    make_repo "$TMP/repo"
    mkdir -p "$TMP/repo/sub"
    write_passing_bats "$TMP/repo/a.bats"
    write_passing_bats "$TMP/repo/sub/b.bats"
    git -C "$TMP/repo" add a.bats sub/b.bats
    run bash "$GATE" "$TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"shell files=2 tests=2 ok=2 skip=0 fail=0 status=ok"* ]]
}

@test "1件でも落ちれば 1 で、要約の fail が非0になる" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    write_failing_bats "$TMP/repo/b.bats"
    git -C "$TMP/repo" add a.bats b.bats
    run bash "$GATE" "$TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"shell files=2 tests=2 ok=1 skip=0 fail=1 status=fail"* ]]
    # どのテストが落ちたかが TAP に残る（黙って落ちない）。
    [[ "$output" == *"not ok"*"落ちる"* ]]
}

@test "skip は ok と分けて数える" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    write_skipping_bats "$TMP/repo/b.bats"
    git -C "$TMP/repo" add a.bats b.bats
    run bash "$GATE" "$TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"shell files=2 tests=2 ok=1 skip=1 fail=0 status=ok"* ]]
}

@test "追跡されていない .bats は数えず、追跡された分だけ走る" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/tracked.bats"
    write_failing_bats "$TMP/repo/untracked.bats"
    git -C "$TMP/repo" add tracked.bats
    run bash "$GATE" "$TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"shell files=1 tests=1 ok=1 skip=0 fail=0 status=ok"* ]]
}

@test "GIT_DIR が渡ってきてもテストの中の git 操作へ漏らさない" {
    # ワークツリーから push すると git は pre-push フックへ GIT_DIR を渡す
    # （実測）。落とさないと、テストが作る使い捨てリポジトリへの git 操作が
    # 別のリポジトリを触りに行く。実際に penguinEx の 11件がこれで落ちた。
    make_repo "$TMP/repo"
    cat > "$TMP/repo/nested.bats" <<'EOF'
@test "使い捨てリポジトリで commit できる" {
    d="$(mktemp -d)"
    git init -q "$d"
    git -C "$d" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
    rc=$?
    rm -rf -- "$d"
    [ "$rc" -eq 0 ]
    # GIT_DIR が残っていないこと自体も見る（rc だけだと、たまたま
    # 通ってしまう経路と区別できない）。
    [ -z "${GIT_DIR:-}" ]
}
EOF
    git -C "$TMP/repo" add nested.bats

    # 別のリポジトリの gitdir を指す GIT_DIR を渡す。
    make_repo "$TMP/other"
    run env GIT_DIR="$TMP/other/.git" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"shell files=1 tests=1 ok=1 skip=0 fail=0 status=ok"* ]]
}

@test "GIT_DIR が渡ってきても対象のリポジトリはコマンドライン引数で決まる" {
    # GIT_DIR を落とさないと rev-parse も ls-files も GIT_DIR の側を見るので、
    # 引数のリポジトリではなく別のリポジトリの .bats を走らせてしまう。
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    make_repo "$TMP/other"
    write_failing_bats "$TMP/other/b.bats"
    git -C "$TMP/other" add b.bats

    run env GIT_DIR="$TMP/other/.git" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"shell files=1 tests=1 ok=1 skip=0 fail=0 status=ok"* ]]
    [[ "$output" != *"落ちる"* ]]
}

@test "bats の出力にプラン行が無ければ 1 で落ちる（数えられないのに緑にしない）" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    # プラン行を出さず 0 で終わる偽の bats を PATH の先頭に置く。
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\necho "ok 1 偽"\nexit 0\n' > "$TMP/bin/bats"
    chmod +x "$TMP/bin/bats"
    run env PATH="$TMP/bin:$PATH" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"プラン行"* ]]
}

@test "プラン行と ok/not ok の合計が食い違えば 1 で落ちる（途中で死んだ bats を緑にしない）" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    # 3件と宣言して1件しか報告せず 0 で終わる偽の bats。
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\necho "1..3"\necho "ok 1 偽"\nexit 0\n' > "$TMP/bin/bats"
    chmod +x "$TMP/bin/bats"
    run env PATH="$TMP/bin:$PATH" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"集計が合わない"* ]]
}

@test "プラン行と ok/not ok が整合していても bats が非0で終われば 1 で落ちる" {
    # bats が起動に失敗した・途中で死んだ経路。TAP には not ok が1つも出ない
    # ので、件数の整合だけを見ていると全緑に見える。終了コードを見る判定は
    # 件数を見る判定と冗長ではない。
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\necho "1..1"\necho "ok 1 偽"\nexit 1\n' > "$TMP/bin/bats"
    chmod +x "$TMP/bin/bats"
    run env PATH="$TMP/bin:$PATH" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bats が非0"* ]]
}

@test "bats が 0 で終わっても not ok があれば 1 で落ちる" {
    # 上の逆。bats の終了コードだけを見ていると通ってしまう経路で、
    # not ok を数える判定が単独で効いていることを見る。
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\necho "1..2"\necho "ok 1 偽"\necho "not ok 2 偽"\nexit 0\n' > "$TMP/bin/bats"
    chmod +x "$TMP/bin/bats"
    run env PATH="$TMP/bin:$PATH" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 1 ]
    [[ "$(summary_line)" == *"fail=1 status=fail"* ]]
}

# bats の代わりに置く偽物。受け取った引数をそのまま TAP へ書き出すので、
# 門が --jobs を渡したかどうかを外から見られる。
write_argv_echoing_bats() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
echo "1..1"
echo "ok 1 argv=[$*]"
exit 0
EOF
    chmod +x "$1"
}

# 門が使う道具だけを並べた PATH を作る（本物の parallel を隠すため）。
# nproc は結果を固定するために4を返す偽物を置く。
make_minimal_bin() {
    mkdir -p "$TMP/bin"
    local tool
    for tool in bash git grep sed env; do
        ln -sf "$(command -v "$tool")" "$TMP/bin/$tool"
    done
    printf '#!/usr/bin/env bash\necho 4\n' > "$TMP/bin/nproc"
    chmod +x "$TMP/bin/nproc"
    write_argv_echoing_bats "$TMP/bin/bats"
}

@test "GNU parallel が無ければ直列で走らせる（--jobs を渡さない）" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    make_minimal_bin
    [ ! -e "$TMP/bin/parallel" ]

    run env PATH="$TMP/bin" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=ok jobs=1"* ]]
    [[ "$output" != *"--jobs"* ]]
}

@test "GNU parallel と flock があれば --jobs を渡して並行で走らせる" {
    # 所要の短縮（penguinEx 25本で 300秒 → 207秒、実測）はここが渡す --jobs
    # による。直列へ落ちるのは道具が無いときだけで、走る .bats も判定も
    # 変わらない。**ファイル内は直列に保つ**（この suite には固定パスを
    # ファイル内で共有する .bats があり、外すと落ちる。実装のコメント参照）。
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    make_minimal_bin
    # bats へ渡すだけの偽物。この偽 bats は --jobs を解釈しないので、
    # 中身は呼ばれない。
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/parallel"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/flock"
    chmod +x "$TMP/bin/parallel" "$TMP/bin/flock"

    run env PATH="$TMP/bin" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"status=ok jobs=4"* ]]
    [[ "$output" == *"argv=[--formatter tap --jobs 4 --no-parallelize-within-files "* ]]
}

@test "要約行だけを読んでも成否が分かる" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    mkdir -p "$TMP/bin"

    # 1) 全部通った経路。
    run bash "$GATE" "$TMP/repo"
    [ "$status" -eq 0 ]
    line="$(summary_line)"
    [[ "$line" == *"files=1 tests=1 ok=1 skip=0 fail=0"* ]]
    [[ "$line" == *"status=ok"* ]]

    # 2) bats が非0で終わった経路。**件数の部分は 1) と一字一句同じ**なので、
    #    status= が無ければ要約行だけを読む側は成功と読む。
    printf '#!/usr/bin/env bash\necho "1..1"\necho "ok 1 偽"\nexit 1\n' > "$TMP/bin/bats"
    chmod +x "$TMP/bin/bats"
    run env PATH="$TMP/bin:$PATH" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 1 ]
    line="$(summary_line)"
    [[ "$line" == *"files=1 tests=1 ok=1 skip=0 fail=0"* ]]
    [[ "$line" == *"status=fail"* ]]

    # 3) プラン行が読めない経路。件数は tests=? になるが、それだけでは
    #    「数えられなかった」のか「落ちた」のかが読めない。
    printf '#!/usr/bin/env bash\necho "ok 1 偽"\nexit 0\n' > "$TMP/bin/bats"
    chmod +x "$TMP/bin/bats"
    run env PATH="$TMP/bin:$PATH" bash "$GATE" "$TMP/repo"
    [ "$status" -eq 1 ]
    line="$(summary_line)"
    [[ "$line" == *"tests=?"* ]]
    [[ "$line" == *"status=fail"* ]]
}

@test "--exclude で外した .bats は走らず、要約の excluded= に本数が出る" {
    make_repo "$TMP/repo"
    mkdir -p "$TMP/repo/ci-only" "$TMP/repo/gate"
    write_passing_bats "$TMP/repo/gate/a.bats"
    write_failing_bats "$TMP/repo/ci-only/b.bats"
    write_failing_bats "$TMP/repo/ci-only/c.bats"
    git -C "$TMP/repo" add gate/a.bats ci-only/b.bats ci-only/c.bats
    run bash "$GATE" "$TMP/repo" --exclude ci-only
    [ "$status" -eq 0 ]
    [[ "$output" == *"shell files=1 tests=1 ok=1 skip=0 fail=0 status=ok"* ]]
    [[ "$output" == *"excluded=2"* ]]
}

@test "--exclude は複数回渡せて、ファイル単位でも指定できる" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    write_failing_bats "$TMP/repo/b.bats"
    write_failing_bats "$TMP/repo/c.bats"
    git -C "$TMP/repo" add a.bats b.bats c.bats
    run bash "$GATE" "$TMP/repo" --exclude b.bats --exclude c.bats
    [ "$status" -eq 0 ]
    [[ "$output" == *"files=1 "* ]]
    [[ "$output" == *"excluded=2"* ]]
}

@test "--exclude で全部外れて0本になれば 1 で落ちる（除外で門が空になったことを緑にしない）" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    run bash "$GATE" "$TMP/repo" --exclude a.bats
    [ "$status" -eq 1 ]
    [[ "$output" == *"0本"* ]]
}

@test "--exclude に値が無い、または知らない引数なら使い方を出して 2 で落ちる" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    run bash "$GATE" "$TMP/repo" --exclude
    [ "$status" -eq 2 ]
    [[ "$output" == *"使い方"* ]]
    run bash "$GATE" "$TMP/repo" --bogus
    [ "$status" -eq 2 ]
}

@test "--exclude を渡さなければ excluded=0 で従来どおり全部走る" {
    make_repo "$TMP/repo"
    write_passing_bats "$TMP/repo/a.bats"
    git -C "$TMP/repo" add a.bats
    run bash "$GATE" "$TMP/repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"excluded=0"* ]]
}
