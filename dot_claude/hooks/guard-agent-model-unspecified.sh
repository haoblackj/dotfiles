#!/usr/bin/env bash
# サブエージェント起動(Agent ツール)で model が指定されていなければ deny する
# PreToolUse フック。
#
# 対象は次の2つ。
#   (1) subagent_type が 空・null・"general-purpose" の起動で、tool_input に model が無い。
#   (2) 名前付きの subagent_type で、ローカルの .claude/agents/ に定義があり、
#       その frontmatter に model が無く、tool_input にも model が無い。
# Explore や code-review のように定義がローカルに見つからない型は、こちらが書いて
# いない経路を推測で止めると壊れるため対象外にする(penguinEx issue #54)。
# ローカルに定義があるものはこちらが書いた経路なので、この理由に反しない。
#
# (2) の定義の探し方は Claude Code の解決順に合わせる(公式 docs/en/sub-agents)。
#   - 探す先は <cwd>/.claude/agents/ から git のリポジトリのルートまで親方向に歩いた
#     各 .claude/agents/、その次に ~/.claude/agents/。同名の定義が複数あるときは
#     cwd に近い側(project が user より優先)が実際に使われるので、先に見つかった
#     ものだけを見る。--add-dir で足したディレクトリの .claude/agents/ は payload
#     から分からないので見ない(限界)。
#   - 定義の識別子は frontmatter の name 欄で、ファイル名は一致しなくてよく、
#     サブフォルダも再帰的に読まれる。そのため各ディレクトリの *.md を再帰的に
#     読み、name が subagent_type に一致するものを定義とする。
#   - name で見つからず、<dir>/<subagent_type>.md が在るのに frontmatter が読めない
#     (先頭が --- でない・閉じていない・読めない)ときは、壊れた定義とみなして deny
#     する。定義が在るのは分かっているので、黙って通す経路を作らない。
#   - frontmatter の `model: inherit` は素通りさせる。結果はセッション既定の継承と
#     同じだが、書き忘れではなく明示した選択であり、この門は値の良し悪しを判定しない。
#
# ティアの妥当性(haiku か opus か)は判定しない。「安いほうが正しい」という
# 誤った規範を機構へ埋め込むことになるうえ、superpowers の
# subagent-driven-development/SKILL.md 自身が「最安のモデルは多段の作業で
# 2〜3倍のターンを使い、かえって高くつく」と警告している。見るのは
# 「model が指定されているか」だけで、どのモデルを選ぶべきかは判定しない。
# 既定値の注入もしない(選ぶのは呼び出し側の責任)。
#
# 入力の解析に失敗したら素通りする(fail-open)。これはコストの門であって
# 正しさの門ではない。壊れた入力でセッションを止めるほうが害が大きい。
#
# 理由文の先頭の [guard-agent-model-unspecified] は、あとから transcript を数える
# ときの目印である。deny された呼び出しは tool_use として記録が残り、対応する
# tool_result に is_error:true と理由文がそのまま入る。ただし is_error を持たない
# tool_result も混ざる(実測で 79件中16件)ため、is_error だけでは拒否と判定できない。
# 集計はこの目印と is_error の両方で照合する。**この文字列を変えないこと。**
# 変えると過去の記録と突き合わせられなくなる(penguinEx issue #44 の受け入れ条件7)。
set -uo pipefail

payload=$(cat)

tool_name=$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Agent" ] || exit 0

# tool_input の model は定義側の frontmatter より優先される(Agent ツールの仕様)ので、
# ここで指定があればどの型でも見るものが無い。
model=$(printf '%s' "$payload" | jq -r '.tool_input.model // ""' 2>/dev/null)
[ -n "$model" ] && exit 0

deny() { # <reason>
  jq -cn --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

subagent_type=$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)
case "$subagent_type" in
  ""|general-purpose)
    deny "[guard-agent-model-unspecified] model を指定しないサブエージェント起動は、セッション既定(この環境では Opus 5 [1M] / effort high)をそのまま継承します。役と複雑さからティアを選び、\`model\` を明示して起動し直してください。参照: superpowers の subagent-driven-development/SKILL.md の \`## Model Selection\` 節。"
    ;;
  */*|.*)
    # 名前は外から来る値なので、パスの区切りや先頭のドットを含むものは agents/ の
    # 外を指しうる。定義として探さず「定義なし」と同じ扱いで素通りさせる。
    exit 0
    ;;
esac

# 名前付き: 探索先を Claude Code の優先順に並べる。cwd からリポジトリのルートまでの
# 各 .claude/agents/(cwd に近い順)、最後に ~/.claude/agents/。
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
dirs=()
if [ -n "$cwd" ] && cwd=$(cd -- "$cwd" 2>/dev/null && pwd -P); then
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || top="$cwd"
  dir="$cwd"
  while :; do
    dirs+=("$dir/.claude/agents")
    if [ "$dir" = "$top" ] || [ "$dir" = "/" ]; then break; fi
    dir=$(dirname -- "$dir")
  done
fi
dirs+=("$HOME/.claude/agents")

# frontmatter(先頭の --- から次の --- まで)が閉じていれば "<name>\t<model の有無 0|1>"
# を1行出す。先頭が --- でない・閉じていない・読めない、は何も出さない。
# model は値つきの model: 行があれば 1(空値やコメントだけの行は 0)。
frontmatter_fields() { # <file>
  awk '
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { closed = 1; exit }
    /^name:[[:space:]]*/ {
      name = $0
      sub(/^name:[[:space:]]*/, "", name)
      sub(/[[:space:]]+$/, "", name)
      gsub(/^["'"'"']|["'"'"']$/, "", name)
    }
    /^model:[[:space:]]*["'"'"']?[A-Za-z0-9]/ { model = 1 }
    END { if (closed) print name "\t" model + 0 }
  ' "$1" 2>/dev/null
}

# name 欄が subagent_type に一致する定義を、優先順に探す。同じディレクトリ内の
# 走査順は Claude Code 側も未定義なので、こちらはパス順で先のものを採る。
definition=""
fields=""
for dir in "${dirs[@]}"; do
  [ -d "$dir" ] || continue
  while IFS= read -r -d '' file; do
    fields=$(frontmatter_fields "$file")
    if [ "${fields%%$'\t'*}" = "$subagent_type" ]; then
      definition="$file"
      break 2
    fi
  done < <(find "$dir" -type f -name '*.md' -print0 2>/dev/null | LC_ALL=C sort -z)
done

# name で見つからないとき、<dir>/<subagent_type>.md が在って frontmatter が読めない
# なら壊れた定義として deny する。読めて name が別なら別の agent なので定義なし。
if [ -z "$definition" ]; then
  for dir in "${dirs[@]}"; do
    if [ -f "$dir/$subagent_type.md" ]; then
      fields=$(frontmatter_fields "$dir/$subagent_type.md")
      [ -z "$fields" ] && definition="$dir/$subagent_type.md"
      break
    fi
  done
fi
[ -n "$definition" ] || exit 0

case "$fields" in *$'\t'1) exit 0 ;; esac

deny "[guard-agent-model-unspecified] 名前付きサブエージェント \`$subagent_type\` の定義 $definition の frontmatter に model がありません(または定義が読めません)。このままではセッション既定(この環境では Opus 5 [1M] / effort high)をそのまま継承します。定義の frontmatter に \`model:\` を書くか、起動側で \`model\` を明示してください。参照: superpowers の subagent-driven-development/SKILL.md の \`## Model Selection\` 節。"
