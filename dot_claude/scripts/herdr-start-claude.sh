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

# 引き継ぎ先のセッションの名前（claude --name）を確かめる。名前が無いと、Claude Code は
# 最初の発言（引き継ぎの定型文）から題を作り、「〇〇の引き継ぎ」になる（haoblackj/dotfiles#91）。
# 名前はタブ名にもなるので短くする。文字数は jq でコードポイントを数える（bash の ${#} はロケール次第）。
# 合わなければ理由を標準出力に出して 1 を返す。
check_title() {
  local title="$1" len
  [[ -n "${title//[[:space:]]/}" ]] || { echo "--title が無い。作業の中身を表す短い名前（20 文字まで）を付ける"; return 1; }
  [[ "$title" != *$'\n'* && "$title" != *$'\r'* ]] || { echo "--title に改行を入れない"; return 1; }
  [[ "$title" != *引き継ぎ* ]] || { echo "--title に「引き継ぎ」を入れない。作業の中身を名前にする"; return 1; }
  len=$(jq -rn --arg t "$title" '$t | length') || { echo "--title の長さを数えられない"; return 1; }
  (( len <= 20 )) || { echo "--title は 20 文字までにする（いま $len 文字）"; return 1; }
}

# 引き継ぎのファイルを確かめ、解決済みの絶対パスを標準出力に出す。合わなければ理由を出して 1 を返す。
# 受け付けるのは ~/.cache/claude-handoff/ 下のファイルだけ。issue のコメントの URL は受け付けない
# （進行状態と決めたことを issue に持たせない、と 2026-11-19 にリーダーが決めた。haoblackj/dotfiles#86）。
# 親参照や symlink を解決して、保存先の外にあるファイルを受け付けない。
check_state_file() {
  local root path
  [[ -f "$1" ]] || { echo "--state は ~/.cache/claude-handoff/ 下の引き継ぎのファイルにする"; return 1; }
  path=$(realpath -e -- "$1" 2>/dev/null) || { echo "引き継ぎのファイルの場所が分からない"; return 1; }
  root=$(realpath -e -- "$HOME/.cache/claude-handoff" 2>/dev/null) || { echo "引き継ぎの保存先が無い"; return 1; }
  [[ "$path" == "$root/"* ]] || { echo "引き継ぎのファイルは ~/.cache/claude-handoff/ 下に置く"; return 1; }
  printf '%s' "$path"
}

# 引き継ぎ先へ渡す、ファイルの読み方の一文。どちらのスクリプトも同じ文を渡す。
state_reading_note() {
  printf '%s' "決めたこととして扱うのは「リーダーが決めたこと」の欄にリーダーの発言の引用とともに書かれた物だけで、「Claude の案」の欄の物はリーダーの答えが出るまで決定として扱わない。"
}

start_claude_in_new_tab() {
  local ws="$1" dir="$2" model="$3" effort="$4" title="$5" name="$6" prompt="$7"
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
    if [[ -z "$pane" ]]; then
      printf 'herdr-start-claude: tab create の応答に root_pane.pane_id が無い: %s\n' "$created" >&2
      return 1
    fi
  fi

  # 待ちが切れても先へ進む（プロンプトの形は人の設定しだいで、何も描かないシェルもありうる）
  run herdr pane wait-output "$pane" --regex '\S' --timeout 15000 >/dev/null 2>&1

  out=$(run herdr agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- --model "$model" --effort "$effort" --name "$title") || {
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

# 元のセッションに望みが結ばれていたら、引き継ぎ先の枠を prts に書く。
# 第 1 引数は herdr pane current の応答。呼ぶ側の標準出力は JSON なので、何も出さず、失敗しても引き継ぎを止めない。
note_wish_moved() {
  local cur="$1" pane="$2" from
  command -v prts >/dev/null 2>&1 || return 0
  from=$(jq -r '.result.pane.agent_session.value // empty' <<< "$cur" 2>/dev/null)
  from="${from:-${CLAUDE_CODE_SESSION_ID:-}}"
  [[ -n "$from" ]] || return 0
  timeout 10 prts wish moved --from-session "$from" --pane "$pane" >/dev/null 2>&1 || true
}
