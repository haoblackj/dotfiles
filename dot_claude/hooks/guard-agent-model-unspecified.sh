#!/usr/bin/env bash
# サブエージェント起動(Agent ツール)で model が指定されていなければ deny する
# PreToolUse フック。
#
# 対象は subagent_type が 空・null・"general-purpose" のいずれかの起動だけに絞る。
# Explore や code-review のような名前付きの型は、こちらが書いていない経路を
# 推測で止めると壊れるため対象外にする。名前で外れる形にすれば未知の経路も
# 自動的に素通りする。
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

subagent_type=$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)
case "$subagent_type" in
  ""|general-purpose) ;;
  *) exit 0 ;;
esac

model=$(printf '%s' "$payload" | jq -r '.tool_input.model // ""' 2>/dev/null)
[ -n "$model" ] && exit 0

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[guard-agent-model-unspecified] model を指定しないサブエージェント起動は、セッション既定(この環境では Opus 5 [1M] / effort high)をそのまま継承します。役と複雑さからティアを選び、`model` を明示して起動し直してください。参照: superpowers の subagent-driven-development/SKILL.md の `## Model Selection` 節。"}}
JSON
exit 0
