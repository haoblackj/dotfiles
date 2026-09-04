#!/usr/bin/env bash
# 作業先が直前から変わったときだけ知らせる PreToolUse フック。
#
# グローバル CLAUDE.md は「ファイルを変更する前に pwd と git rev-parse --show-toplevel を
# 実行して作業先を確認する」と定めていたが、記録上4回守られなかった。Bash ツールの作業
# ディレクトリは呼び出しをまたいで持続するので cd した記憶が薄れ、しかも取り違えても大半の
# コマンドは成功するため、確認を省いたことに気づけない。
#
# そこで「確認したか」を人へ問うのをやめ、確認結果を毎回機械が計算して、変わったときだけ
# additionalContext で渡す。止めない（permissionDecision は返さない）。
#
# 設計: penguinEx docs/superpowers/specs/2026-09-04-workdir-notice-design.md
# テスト: chezmoi ソース側の executable_notify-workdir-change.test.sh
#
# 注意点。
#   - stdin はソケットで渡る。$(</dev/stdin) は ENXIO で落ちるので $(cat) を使う。
#   - git 管理外の判定に終了コードを使わない。コミットが1つも無いリポジトリは 128 を
#     返しながらトップレベルを出す。標準出力の1行目で判定する。
#   - どの分岐でも exit 0。ツール呼び出しを妨げない。

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-workdir-notice"
NOGIT='!nogit'

input=$(cat)
[ -n "$input" ] || exit 0

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
case "$tool_name" in
  Bash)       lane=1 ;;  # shell レーン
  Write|Edit) lane=2 ;;  # write レーン
  *)          exit 0 ;;
esac

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cwd" ] || exit 0

# 基準ディレクトリと、write レーンで文面に出す対象パスを決める。
target=""
if [ "$lane" -eq 1 ]; then
  base="$cwd"
else
  target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
  [ -n "$target" ] || exit 0
  # 相対パスの解決は防御的な余剰。実運用では常に絶対パスで渡る。
  case "$target" in
    /*) ;;
    *)  target="$cwd/$target" ;;
  esac
  base=$(dirname "$target")
fi
[ -n "$base" ] || exit 0

# Write は存在しないファイルを作れるので、親が無いことがある。存在する祖先まで遡る。
while [ ! -d "$base" ]; do
  parent=$(dirname "$base")
  [ "$parent" = "$base" ] && break
  base="$parent"
done
[ -d "$base" ] || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty')

# パスの構成に使う値は、取り出した直後に形式を検証する。値の由来が信頼できても省かない。
# 過去に3本のフックが session_id を無検証でパスへ使い、"../victim/target" で状態ディレクトリの
# 外を上書きできることが実証された。
[[ "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0
if [ -n "$agent_id" ]; then
  [[ "$agent_id" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0
fi

# 作業先を「トップレベル<TAB>ブランチ」で表す。管理外は "!nogit<TAB>" の1つに畳む。
# 判定は標準出力の1行目で行い、終了コードを見ない。コミットが1つも無いリポジトリは
# HEAD を解決できず 128 を返すが、標準出力にはトップレベルが出るため。
resolve_workdir() {
  local dir="$1" out top branch
  out=$(git -C "$dir" rev-parse --show-toplevel --abbrev-ref HEAD 2>/dev/null)
  top=$(printf '%s\n' "$out" | sed -n '1p')
  branch=$(printf '%s\n' "$out" | sed -n '2p')
  if [ -n "$top" ]; then
    printf '%s\t%s' "$top" "$branch"
  else
    printf '%s\t' "$NOGIT"
  fi
}

# 識別子を人が読む形へ。「/top（ブランチ x）」または「git 管理外のディレクトリ」。
describe() {
  local id="$1" top branch
  top="${id%%$'\t'*}"
  branch="${id#*$'\t'}"
  if [ "$top" = "$NOGIT" ]; then
    printf 'git 管理外のディレクトリ'
  else
    printf '%s（ブランチ %s）' "$top" "$branch"
  fi
}

current=$(resolve_workdir "$base")

state_name="$session_id"
[ -n "$agent_id" ] && state_name="$state_name-$agent_id"
state_file="$STATE_DIR/$state_name.state"

line1=""
line2=""
if [ -f "$state_file" ]; then
  line1=$(sed -n '1p' "$state_file")
  line2=$(sed -n '2p' "$state_file")
fi
if [ "$lane" -eq 1 ]; then previous="$line1"; else previous="$line2"; fi

[ "$current" = "$previous" ] && exit 0

# 状態を先に更新する。出力側で失敗しても同じ通知を繰り返さないため。
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# 状態ファイルを新規に作るときだけ、古いものを掃除する。対象は固定パスの直下の
# *.state に限る。ここで消すのはフック自身が作った数百バイトの記録で、復元する
# 意味が無い。Bash ツールから撃つ削除に掛かる「rm ではなく trash-put」の規律とは別。
if [ ! -f "$state_file" ]; then
  find "$STATE_DIR" -maxdepth 1 -type f -name '*.state' -mtime +7 -delete 2>/dev/null
fi

if [ "$lane" -eq 1 ]; then line1="$current"; else line2="$current"; fi
tmp="$state_file.tmp.$$"
printf '%s\n%s\n' "$line1" "$line2" > "$tmp" 2>/dev/null || exit 0
mv "$tmp" "$state_file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }

# 文面の空白は spec §6 の例に合わせる。パスの前には空白を置き、閉じ括弧の後には置かない。
# 「…は /path（ブランチ main）です。」であって「…（ブランチ main） です。」ではない。
cur_desc=$(describe "$current")
if [ "${current%%$'\t'*}" = "$NOGIT" ]; then
  if [ "$lane" -eq 1 ]; then
    subject="Bash の作業ディレクトリ ${base} は ${cur_desc}です"
  else
    subject="書き込み先 ${target} は ${cur_desc}です"
  fi
else
  if [ "$lane" -eq 1 ]; then
    subject="Bash の作業ディレクトリは ${cur_desc}です"
  else
    subject="書き込み先 ${target} は ${cur_desc}の中です"
  fi
fi

if [ -z "$previous" ]; then
  message="このセッションの${subject}。"
else
  message="作業先が変わりました。${subject}。直前は $(describe "$previous")でした。意図した作業先か確かめてから続けてください。"
fi

jq -nc --arg m "$message" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $m
  }
}'
exit 0
