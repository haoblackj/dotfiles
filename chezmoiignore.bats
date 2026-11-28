#!/usr/bin/env bats
# .chezmoiignore の試験。リポジトリ直下のテスト（*.bats）がホームへ配られないこと。
# 直下の .bats を名指しで外していた頃、pre-commit-config.bats（#121）が名指しから漏れて
# ~/pre-commit-config.bats として配られる対象になった（2026-11-28）。
#
# 一時の設定ファイルと置き場を渡し、この作業ツリーをソースにして配る対象を並べる。
# 本番の ~/.config/chezmoi/chezmoi.toml とホームは読まない。
set -u

setup() {
    command -v chezmoi >/dev/null || skip "chezmoi が無い"
    SRC="$BATS_TEST_DIRNAME"
    CFG="$BATS_TEST_TMPDIR/chezmoi.toml"
    STATE="$BATS_TEST_TMPDIR/state.boltdb"
    DEST="$BATS_TEST_TMPDIR/home"
    mkdir -p "$DEST"
    cat >"$CFG" <<'EOT'
[data]
    location = "wsl"
    isWSL = true
    isDevcontainer = false
    windowsUsername = "someone"
    isHome = false
EOT
}

managed() {
    chezmoi --config "$CFG" --persistent-state "$STATE" --source "$SRC" --destination "$DEST" \
        managed --include files --exclude externals
}

@test "リポジトリ直下の .bats はどれもホームへ配らない" {
    run managed
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    run grep -E '^[^/]+\.bats$' <<<"$output"
    [ "$status" -ne 0 ]
}

@test "直下に足した新しい .bats も配らない（名指しに頼らない）" {
    run managed
    for f in $(git -C "$SRC" ls-files '*.bats' | grep -v /); do
        [[ "$output" != *"$f"* ]]
    done
}
