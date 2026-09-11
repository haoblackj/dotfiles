#!/usr/bin/env bats
# check-pytest-gate.sh が sp-repo-review の PP3xx だけを見て、
# 1件でも fail があれば非0で落ちることを確かめる。
# 詳細は penguinEx の docs/superpowers/plans/2026-09-07-test-foundation-layer3.md。

# 対象の名前は置き場所で変わる。chezmoi のソース側では executable_check-pytest-gate.sh、
# 配置先（~/.local/bin/）では check-pytest-gate.sh。pre-push の門はコミットされた
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
    GATE="$(resolve_target check-pytest-gate.sh)"
    TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP"
}

# 最小のリポジトリを作る。PP301（pytest 設定が pyproject にある）だけを
# 満たし、PP302 以降を満たさない状態から始める。
make_repo() {
    local dir="$1"
    mkdir -p "$dir"
    printf '[tool.pytest.ini_options]\ntestpaths = ["tests"]\n' > "$dir/pyproject.toml"
}

@test "PP3xx に fail があれば非0で落ちる" {
    make_repo "$TMP/bad"
    run bash "$GATE" "$TMP/bad"
    [ "$status" -ne 0 ]
    # どの検査が落ちたかを出すこと（黙って落ちない）。
    [[ "$output" == *"PP30"* ]]
}

@test "PP3xx がすべて通れば0で通る" {
    # **この5行で PP3xx が9件すべて OK になることを実測で確認済み。**
    # strict = true の1行だけで PP305・PP306・PP307 が同時に通る。
    make_repo "$TMP/good"
    cat >> "$TMP/good/pyproject.toml" <<'TOML'
minversion = "9"
strict = true
log_level = "INFO"
addopts = ["-ra"]
filterwarnings = ["error"]
TOML
    run bash "$GATE" "$TMP/good"
    [ "$status" -eq 0 ]
}

@test "PP3xx 以外の fail では落ちない" {
    # GH100（GitHub Actions が無い）は spec の非目標「CI を作らない」と
    # 正面から衝突する。PP3xx がすべて通っていれば、GH100 が fail でも
    # この門は通らなければならない。
    make_repo "$TMP/nogh"
    cat >> "$TMP/nogh/pyproject.toml" <<'TOML'
minversion = "9"
strict = true
log_level = "INFO"
addopts = ["-ra"]
filterwarnings = ["error"]
TOML
    # .github が無いので GH100 は必ず fail する。
    [ ! -d "$TMP/nogh/.github" ]
    run bash "$GATE" "$TMP/nogh"
    [ "$status" -eq 0 ]
}

@test "PP で始まるが PP3xx でない検査を巻き込まない" {
    # PP002（build-system）・PP003（wheel を入れない）・PP006 は
    # PP で始まるが射程外。接頭辞の照合が "PP" だと巻き込む。
    make_repo "$TMP/pp"
    cat >> "$TMP/pp/pyproject.toml" <<'TOML'
minversion = "9"
strict = true
log_level = "INFO"
addopts = ["-ra"]
filterwarnings = ["error"]
TOML
    run bash "$GATE" "$TMP/pp"
    [ "$status" -eq 0 ]
    # 出力に PP002 の名前が出ていないこと（見ていない証拠）。
    # **この最小構成で PP002・PP003・PP006 が実際に fail のまま残ることを
    # 実測で確認済み**なので、接頭辞を "PP" にすればこの検査は落ちる。
    [[ "$output" != *"PP002"* ]]
}

@test "リポジトリの指定が無ければ使い方を出して落ちる" {
    run bash "$GATE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"使い方"* || "$output" == *"usage"* ]]
}

@test "sp-repo-review の出力が壊れていたら飛ばさずに落ちる" {
    # **「黙って通る」型を潰す。**解析の終了コードを見ない実装だと、
    # python3 が死んで結果が空になり、門が「指摘なし」と言って通る。
    # 空出力の経路とは別で、そちらは既に別の分岐が扱っている。
    #
    # 壊れた JSON を返す偽の uvx を PATH の先頭へ置いて再現する。
    make_repo "$TMP/broken"
    mkdir -p "$TMP/fakebin"
    cat > "$TMP/fakebin/uvx" <<'FAKE'
#!/usr/bin/env bash
echo "これは JSON ではない"
FAKE
    chmod +x "$TMP/fakebin/uvx"

    run env PATH="$TMP/fakebin:$PATH" bash "$GATE" "$TMP/broken"
    [ "$status" -ne 0 ]
    # 「指摘なし」で通っていないことの証拠。
    [[ "$output" != *"指摘なし"* ]]
    # 失敗が「解析できなかった」経路によるものであることの証拠
    # （exit 127 などスクリプト不在の失敗と区別する）。
    [[ "$output" == *"解析できませんでした"* ]]
}

@test "sp-repo-review が空出力なら落ちる" {
    # uvx 自体は実行できるが、標準出力が空のまま終わる形を再現する
    # （ネットワーク不調・タイムアウトなどで起こりうる）。既存の
    # 5つの失敗経路（解析失敗・0件評価・全件skip・uvx不在）はすべて
    # bats で押さえていたが、`[ -z "$report" ]` の分岐だけテストが
    # 無かった。
    make_repo "$TMP/empty"
    mkdir -p "$TMP/fakebin"
    cat > "$TMP/fakebin/uvx" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    chmod +x "$TMP/fakebin/uvx"

    run env PATH="$TMP/fakebin:$PATH" bash "$GATE" "$TMP/empty"
    [ "$status" -ne 0 ]
    # 「指摘なし」で通っていないことの証拠。
    [[ "$output" != *"指摘なし"* ]]
    # 空出力の経路で落ちたことの証拠（他の経路のメッセージと重複しない）。
    [[ "$output" == *"出力を返しませんでした"* ]]
}

@test "PP3xx が1件も評価されていなければ落ちる（0件を合格と区別する）" {
    # JSON としては正しいが、checks の中に PP3 で始まるキーが1件も
    # 無い形を再現する。sp-repo-review の将来のバージョンで PP3xx の
    # コード体系が変わる・extras の欠落でファミリーが登録されない
    # などで起こりうる。0件は「全部通った」とは別の故障であり、
    # 「解析できなかった」（テスト6）とも別のメッセージで区別すること。
    make_repo "$TMP/nopp3"
    mkdir -p "$TMP/fakebin"
    cat > "$TMP/fakebin/uvx" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
{"status": "mixed", "families": {}, "checks": {
    "GH100": {"description": "GitHub Actions を使っている", "result": false, "err_msg": ""},
    "PY001": {"description": "pyproject.toml がある", "result": true, "err_msg": ""}
}}
JSON
FAKE
    chmod +x "$TMP/fakebin/uvx"

    run env PATH="$TMP/fakebin:$PATH" bash "$GATE" "$TMP/nopp3"
    [ "$status" -ne 0 ]
    # 「指摘なし」で通っていないことの証拠。
    [[ "$output" != *"指摘なし"* ]]
    # 失敗が「PP3xx が1件も評価されていなかった」経路によるものであることの
    # 証拠（解析失敗の経路＝テスト6とは別のメッセージ）。
    [[ "$output" == *"評価されていません"* ]]
}

@test "PP3xx のキーはあるが全部 skip（result: null）なら落ちる" {
    # キーが存在する ≠ 評価された。repo-review は result: null を
    # skip として扱い、依存する検査（例: PP301）が通らないと下流の
    # PP30x は自動で null になる。skip されたキーも checks には残る
    # ので、キーの数だけを見る実装だと「一家まるごと skip」を
    # 「評価済み」と誤認して素通りしてしまう
    # （実際に repo-review のソースと sp_repo_review の requires 宣言で
    # 確認された経路。前のテスト「キーが1件も無い」とは別の穴）。
    make_repo "$TMP/allskip"
    mkdir -p "$TMP/fakebin"
    cat > "$TMP/fakebin/uvx" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
{"status": "mixed", "families": {}, "checks": {
    "PP301": {"description": "pytest 設定が pyproject にある", "result": null, "err_msg": ""},
    "PP302": {"description": "minversion がある", "result": null, "err_msg": ""},
    "PP303": {"description": "testpaths がある", "result": null, "err_msg": ""}
}}
JSON
FAKE
    chmod +x "$TMP/fakebin/uvx"

    run env PATH="$TMP/fakebin:$PATH" bash "$GATE" "$TMP/allskip"
    [ "$status" -ne 0 ]
    # 「指摘なし」で通っていないことの証拠。
    [[ "$output" != *"指摘なし"* ]]
    # 「1件も評価されていない」経路で落ちたことの証拠
    # （前のテストの「キーが無い」ケースと同じメッセージを共有するが、
    # どちらの実際の状況でも真である文言のため許容する）。
    [[ "$output" == *"評価されていません"* ]]
}

@test "解析器が件数を出さずに黙って終われば落ちる（fail-open を防ぐ）" {
    # shell と python の間の契約は「1行目が件数」という位置だけの約束で、
    # 型は保証されない。python3 が PATH にあって exit 0 で終わっても、
    # 何も出力しない壊れ方だと1行目が空になる。ここを確かめずに
    # `[ "$pp3_count" -eq 0 ]` へ渡すと、bash が「整数の式が予期されます」
    # とエラーを出してその比較自体が偽になり、$failed も空のまま
    # 「PP3xx: 指摘なし」で exit 0 に落ちる（fail-open）。
    # PP302 が実際に fail している report を返す偽 uvx と、
    # 何も出力せず exit 0 する偽 python3 の組み合わせで再現する。
    make_repo "$TMP/pp3fail"
    mkdir -p "$TMP/fakebin"
    cat > "$TMP/fakebin/uvx" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
{"status": "mixed", "families": {}, "checks": {
    "PP302": {"description": "minversion がある", "result": false, "err_msg": ""}
}}
JSON
FAKE
    chmod +x "$TMP/fakebin/uvx"
    cat > "$TMP/fakebin/python3" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    chmod +x "$TMP/fakebin/python3"

    run env PATH="$TMP/fakebin:$PATH" bash "$GATE" "$TMP/pp3fail"
    [ "$status" -ne 0 ]
    # 「指摘なし」で通っていないことの証拠（PP302 は実際に fail している）。
    [[ "$output" != *"指摘なし"* ]]
    # 件数行を読めなかった経路で落ちたことの証拠
    # （解析失敗・0件評価・全件skip のどのメッセージとも別）。
    [[ "$output" == *"件数行を読めませんでした"* ]]
}

@test "uvx が無ければ飛ばさずに落ちる" {
    # 受け入れ条件26の型。道具が見つからないときに exit 0 で通す形を
    # 後継で繰り返さない。
    #
    # **PATH を丸ごと潰さない。**`PATH=/nonexistent` にすると
    # `#!/usr/bin/env bash` の bash 解決から先に失敗し、スクリプトが起動
    # すらしない。それでも非0にはなるので、この検査は「uvx が無いこと」
    # ではなく「起動できなかったこと」を見てしまう。
    # **uvx だけを隠した PATH を作る。**
    make_repo "$TMP/nouvx"
    mkdir -p "$TMP/bin"
    ln -s "$(command -v bash)" "$TMP/bin/bash"
    ln -s "$(command -v python3)" "$TMP/bin/python3"
    [ ! -e "$TMP/bin/uvx" ]

    run env PATH="$TMP/bin" bash "$GATE" "$TMP/nouvx"
    [ "$status" -ne 0 ]
    # 「起動できなかった」ではなく「uvx が無い」で落ちたことの証拠。
    [[ "$output" == *"uvx"* ]]
}
