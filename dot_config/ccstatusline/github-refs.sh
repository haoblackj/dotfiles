# shellcheck shell=bash
# ブランチ名から issue 番号を取り出す関数。source して使う。
# 使う側: ~/.config/ccstatusline/issue-pr-links.sh（ステータスラインの表示）と
#         ~/.config/herdr/open-github.sh（prefix+i でブラウザを開く）
#
# 元: https://qiita.com/kuma_3838/items/00cb0b8d61ca76769c88 の `#123` の形に、
# ここのブランチ名の `issue-62` / `issue/10` の形を足したもの。最初に当たった番号を返す。
issue_number_from_branch() {
  printf '%s' "$1" | sed -n -e 's/.*#\([0-9][0-9]*\).*/\1/p' -e 's,.*issue[-/_]\([0-9][0-9]*\).*,\1,p' | head -n1
}
