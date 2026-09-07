#!/usr/bin/env bash
# sp-repo-review の PP3xx（pytest の設定）だけを見る門。
#
# **範囲を PP3xx に絞る理由。**実測で penguinEx へ当てると27件 fail するが、
# 射程にあるのは PP302〜PP309 の8件だけ。残りは GH100（GitHub Actions が無い）・
# PY0xx・PP002/PP003/PP006・MY100・RF001・PC1xx〜PC9xx で、どれもこの設計の
# 対象外。とくに GH100 は非目標「CI を作ることは目標にしない」と正面から
# 衝突する。範囲を絞らずに「指摘が残っていない」を条件にすると、19件分の
# 理由書きか、全件へ一行理由を付けた素通りのどちらかにしかならない。
#
# **接頭辞は "PP3" で照合する。**"PP" だと PP002・PP003・PP006 を巻き込む。
#
# **依存に入れず uvx で実行時にだけ呼ぶ。**cli extras が要る
# （素の `uvx sp-repo-review` は rich が無くて落ちる。実測）。
#
# **`set -e` を使わない。**repo-review は fail が1件でもあると終了コード3を
# 返し、GH100 などは常に fail なので、PP3xx がすべて通っていても3が返る
# （実測）。`set -e` があるとその時点で死に、JSON を読む前に落ちる。
# 各コマンドの終了コードは下で個別に見ている。
set -uo pipefail

usage() {
    echo "使い方: check-pytest-gate.sh <リポジトリのパス>" >&2
}

repo="${1-}"
if [ -z "$repo" ]; then
    usage
    exit 2
fi
if [ ! -d "$repo" ]; then
    echo "リポジトリが見つかりません: $repo" >&2
    exit 2
fi

if ! command -v uvx >/dev/null 2>&1; then
    # **飛ばさずに落ちる。**道具が無いときに exit 0 で通すと、門が黙って
    # 無効になる（古い verify-tests のエントリがその形だった）。
    echo "uvx が PATH にありません。PP3xx の検査を実行できません。" >&2
    exit 1
fi

# **stderr を捨てる。**uvx がこの起動形で「repo-review は sp-repo-review が
# 提供する実行ファイルではない」という警告を1行出し、`2>&1` にすると JSON の
# 解析が壊れる（実測）。**その警告が勧める `--from repo-review` へ乗り換えない**
# — PP3xx を提供しているのは sp-repo-review のプラグインで、素の repo-review
# には入っていない。
report="$(uvx --from 'sp-repo-review[cli]' repo-review --format json "$repo" 2>/dev/null)"
if [ -z "$report" ]; then
    echo "sp-repo-review が出力を返しませんでした: $repo" >&2
    exit 1
fi

# checks は辞書（キーが検査名）。result は true / false / null(skip)。
#
# **解析の終了コードを必ず見る。**見ないと、JSON が壊れていたり `checks` を
# 持たない形だったりしたときに python3 が死んで `$failed` が空になり、
# 門が「指摘なし」と言って exit 0 で通る。**それはこの設計が消そうと
# している「黙って通る」型そのもの**（受け入れ条件26が pre-push の
# エントリに対して禁じているのと同じ形）。`set -e` が無いので、
# 代入の成否は自分で分岐する。
#
# **両方の形を実測で確かめてある。**壊れた JSON を返す偽の uvx を PATH の
# 先頭へ置くと、終了コードを見ない実装は「PP3xx: 指摘なし」と出して 0 で
# 通り、この形は 1 で落ちる。
#
# python3 の traceback は stderr へそのまま出る。**抑制しない** — 門が
# 落ちた原因を読む側に見せるため。
if ! failed="$(printf '%s' "$report" | python3 -c '
import json, sys
checks = json.load(sys.stdin)["checks"]
for name in sorted(checks):
    if name.startswith("PP3") and checks[name].get("result") is False:
        print(name, checks[name].get("description", ""))
')"; then
    echo "sp-repo-review の出力を解析できませんでした: $repo" >&2
    echo "（JSON として読めないか、checks を持たない形でした）" >&2
    exit 1
fi

if [ -n "$failed" ]; then
    echo "PP3xx（pytest の設定）に指摘が残っています: $repo" >&2
    printf '%s\n' "$failed" >&2
    exit 1
fi

echo "PP3xx: 指摘なし ($repo)"
