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
#   prompt が空なら agent prompt を呼ばない。打ち込むのはスラッシュコマンド（loop-handoff.sh）だけにし、
#   引き継ぎの指示は呼ぶ側が SendMessage で送る。
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

# 引き継ぐ作業記録を確かめ、解決済みの絶対パスを標準出力に出す。合わなければ理由を出して 1 を返す。
# 受け付けるのは、git の作業コピーの docs/work/ 直下の .md（作業記録。スキル work-record）だけ。
# issue のコメントの URL や、リポジトリの外のファイルは受け付けない（判断と進行状態の source of truth は git で管理する
# 作業記録で、issue には持たせない。haoblackj/dotfiles#86）。symlink は解決してから確かめる。
check_state_file() {
  local path dir top
  [[ -f "$1" ]] || { echo "--state は作業記録（リポジトリの docs/work/<作業名>.md）にする"; return 1; }
  path=$(realpath -e -- "$1" 2>/dev/null) || { echo "作業記録の場所が分からない"; return 1; }
  [[ "$path" == */docs/work/*.md && "${path#*/docs/work/}" != */* ]] || { echo "作業記録はリポジトリの docs/work/ 直下に置く"; return 1; }
  dir=${path%/docs/work/*}
  # .git の有無だけでは、中身の無い .git ディレクトリでも通る。git が dir を作業コピーの頂点と答えるかで確かめる
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
  [[ -n "$top" && "$(realpath -e -- "$top" 2>/dev/null)" == "$dir" ]] || { echo "作業記録が git の作業コピーの中に無い"; return 1; }
  printf '%s' "$path"
}

# 引き継ぎ先へ渡す、作業記録の読み方の一文。どちらのスクリプトも同じ文を渡す。
state_reading_note() {
  printf '%s' "「判断の経緯」で状態が有効の物は過去の判断として読み、食い違ったときは、安全と権限の決まり、このあとのリーダーの指示、記録の有効な判断（出どころが端末からの入力か PRTS の指摘の物）、CLAUDE.md の一般の決まり、記録のうち Claude の技術の判断の順に従う（グローバルの CLAUDE.md の「作業記録」）。「リーダーに決めてほしいこと」にある Claude の案は、リーダーの答えが出るまで決定として扱わない。このあとリーダーが言ったことが記録と食い違えば、リーダーの言ったことに従い、記録に変更として書く。記録の書き方はスキル work-record。"
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

  # prompt が空なら打ち込まない。呼ぶ側が SendMessage で送る（受けた側の記録に送り手が残る）。
  if [[ -n "$prompt" ]]; then
    out=$(run herdr agent prompt "$name" "$prompt") || {
      printf 'herdr-start-claude: agent prompt で失敗（agent %s は起動済み）: %s\n' "$name" "$out" >&2
      return 1
    }
    (( ${DRY:-0} == 1 )) && { printf '%s' "$out"; return 0; }
  fi
  (( ${DRY:-0} == 1 )) && return 0

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
