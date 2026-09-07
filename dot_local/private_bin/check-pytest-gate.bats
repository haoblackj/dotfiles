#!/usr/bin/env bats
# mutation-target: dot_local/private_bin/executable_check-pytest-gate.sh
# check-pytest-gate.sh が sp-repo-review の PP3xx だけを見て、
# 1件でも fail があれば非0で落ちることを確かめる。
# 詳細は penguinEx の docs/superpowers/plans/2026-09-07-test-foundation-layer3.md。

setup() {
    GATE="$BATS_TEST_DIRNAME/check-pytest-gate.sh"
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
    run "$GATE" "$TMP/bad"
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
    run "$GATE" "$TMP/good"
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
    run "$GATE" "$TMP/nogh"
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
    run "$GATE" "$TMP/pp"
    [ "$status" -eq 0 ]
    # 出力に PP002 の名前が出ていないこと（見ていない証拠）。
    # **この最小構成で PP002・PP003・PP006 が実際に fail のまま残ることを
    # 実測で確認済み**なので、接頭辞を "PP" にすればこの検査は落ちる。
    [[ "$output" != *"PP002"* ]]
}

@test "リポジトリの指定が無ければ使い方を出して落ちる" {
    run "$GATE"
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

    run env PATH="$TMP/fakebin:$PATH" "$GATE" "$TMP/broken"
    [ "$status" -ne 0 ]
    # 「指摘なし」で通っていないことの証拠。
    [[ "$output" != *"指摘なし"* ]]
    # 失敗が「解析できなかった」経路によるものであることの証拠
    # （exit 127 などスクリプト不在の失敗と区別する）。
    [[ "$output" == *"解析できませんでした"* ]]
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

    run env PATH="$TMP/bin" "$GATE" "$TMP/nouvx"
    [ "$status" -ne 0 ]
    # 「起動できなかった」ではなく「uvx が無い」で落ちたことの証拠。
    [[ "$output" == *"uvx"* ]]
}
