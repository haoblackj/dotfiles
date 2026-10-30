#!/bin/bash
# Herdr の新しいタブで claude を起動し、引き継ぎの文面を渡す共通部分。
# 呼ぶ側で source し、DRY=1 なら呼ぶはずのコマンドを出す。
# 手順は herdr の公式の文書（agent automation、cli reference）に従う:
#   tab create は .result.root_pane.pane_id を返す。
#   agent start はシェルがフォアグラウンドにいるペインを求めるので、作った直後のシェルが何かを
#   描くまで pane wait-output で待つ。agent start 自体は、起動の待ちを既定の 30 秒から延ばす
#   （SessionStart のフックで起動が遅れることがある）。再試行はしない。一度目が claude を打ち込んで
#   いれば、二度目は起動中の claude に打ち込むことになるため。
#   agent prompt は --wait を付けない（相手の応答が落ち着くまでブロックするため。グローバルの CLAUDE.md）。
# 失敗した手順を標準エラーに出して 1 を返す。作ったタブは閉じない。

run() {
  if (( ${DRY:-0} == 1 )); then printf '%q ' "$@"; printf '\n'; return 0; fi
  "$@"
}

start_claude_in_new_tab() {
  local ws="$1" dir="$2" model="$3" effort="$4" name="$5" prompt="$6"
  local created pane tab out
  created=$(run herdr tab create --workspace "$ws" --cwd "$dir" --no-focus) || {
    printf 'herdr-start-claude: tab create で失敗: %s\n' "$created" >&2
    return 1
  }
  if (( ${DRY:-0} == 1 )); then
    printf '%s' "$created"
    pane="<root_pane>"
  else
    pane=$(jq -r '.result.root_pane.pane_id // empty' <<< "$created" 2>/dev/null)
    tab=$(jq -r '.result.tab.tab_id // empty' <<< "$created" 2>/dev/null)
    if [[ -z "$pane" || -z "$tab" ]]; then
      printf 'herdr-start-claude: tab create の応答に root_pane.pane_id か tab.tab_id が無い: %s\n' "$created" >&2
      return 1
    fi
  fi

  # 待ちが切れても先へ進む（プロンプトの形は人の設定しだいで、何も描かないシェルもありうる）
  run herdr pane wait-output "$pane" --regex '\S' --timeout 15000 >/dev/null 2>&1

  out=$(run herdr agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- --model "$model" --effort "$effort") || {
    printf 'herdr-start-claude: agent start で失敗（ペイン %s は残してある）: %s\n' "$pane" "$out" >&2
    return 1
  }
  (( ${DRY:-0} == 1 )) && printf '%s' "$out"

  out=$(run herdr agent prompt "$name" "$prompt") || {
    printf 'herdr-start-claude: agent prompt で失敗（agent %s は起動済み）: %s\n' "$name" "$out" >&2
    return 1
  }
  (( ${DRY:-0} == 1 )) && { printf '%s' "$out"; return 0; }

  jq -nc --arg tab "$tab" --arg pane "$pane" '{tab: $tab, pane: $pane}'
}
