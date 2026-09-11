#!/usr/bin/env bash
# サブエージェント起動(Agent ツール)で model が指定されていなければ deny する
# PreToolUse フック。
#
# 対象は次の2つ。
#   (1) subagent_type が 空・null・"general-purpose" の起動で、tool_input に model が無い。
#   (2) 名前付きの subagent_type で、ローカルに定義ファイル
#       (~/.claude/agents/<name>.md か <cwd>/.claude/agents/<name>.md)があり、
#       その frontmatter に model が無く、tool_input にも model が無い。
# Explore や code-review のように定義がローカルに見つからない型は、こちらが書いて
# いない経路を推測で止めると壊れるため対象外にする(penguinEx issue #54)。
# ローカルに定義があるものはこちらが書いた経路なので、この理由に反しない。
#
# (2) で定義ファイルが読めない・frontmatter が壊れている場合は「model がある」とは
# みなさず deny する。定義が在るのは分かっているので、黙って通す経路を作らない。
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

# 名前付き: ローカルの定義を探す。~/.claude/agents/ を先に、次に cwd 側。
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
definition=""
for dir in "$HOME/.claude/agents" ${cwd:+"$cwd/.claude/agents"}; do
  if [ -f "$dir/$subagent_type.md" ]; then
    definition="$dir/$subagent_type.md"
    break
  fi
done
[ -n "$definition" ] || exit 0

# frontmatter(先頭の --- から次の --- まで)に値つきの model: 行があれば 0。
# 先頭が --- でない・閉じていない・読めない、はすべて非 0(model なし扱い)。
frontmatter_has_model() { # <file>
  awk '
    NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { closed = 1; exit }
    /^model:[[:space:]]*["'"'"']?[A-Za-z0-9]/ { found = 1 }
    END { exit (closed && found) ? 0 : 1 }
  ' "$1" 2>/dev/null
}

frontmatter_has_model "$definition" && exit 0

deny "[guard-agent-model-unspecified] 名前付きサブエージェント \`$subagent_type\` の定義 $definition の frontmatter に model がありません(または定義が読めません)。このままではセッション既定(この環境では Opus 5 [1M] / effort high)をそのまま継承します。定義の frontmatter に \`model:\` を書くか、起動側で \`model\` を明示してください。参照: superpowers の subagent-driven-development/SKILL.md の \`## Model Selection\` 節。"
