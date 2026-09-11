#!/usr/bin/env bats
# guard-agent-model-unspecified.sh のユニットテスト。
#
# Agent ツールの起動で model が指定されていない場合だけ deny することを確かめる。
# 判定は「出力に permissionDecision:deny が含まれるか」で見る。フックの終了コードは
# 常に 0 (fail-open) なので、終了コードで判定すると全部通ってしまう。
set -u

decide() { # <JSON payload>
  local payload="$1" out
  out=$(printf '%s' "$payload" | bash "$SCRIPT" 2>/dev/null)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    printf 'deny'
  else
    printf 'allow'
  fi
}

# 名前付き subagent の定義は HOME と cwd の .claude/agents/ から探すので、本番の
# $HOME に定義があるかどうかで結果が変わらないよう、偽の HOME と cwd を毎回作る。
setup() {
    SCRIPT="$BATS_TEST_DIRNAME/guard-agent-model-unspecified.sh"
    WORK="$(mktemp -d)"
    export HOME="$WORK/home"
    CWD="$WORK/project"
    mkdir -p "$HOME/.claude/agents" "$CWD/.claude/agents"
}

teardown() {
    rm -rf -- "$WORK"
}

# 名前付き subagent の起動 payload。cwd は偽のプロジェクトを指す。
named() { # <subagent_type> [<extra JSON fields for tool_input>]
  printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"subagent_type":"%s"%s}}' "$CWD" "$1" "${2:-}"
}

# frontmatter に model を持つ定義を書く。
define_with_model() { # <dir> <name>
  printf -- '---\nname: %s\ndescription: x\nmodel: opus\n---\n\n本文\n' "$2" > "$1/$2.md"
}

# frontmatter に model を持たない定義を書く。
define_without_model() { # <dir> <name>
  printf -- '---\nname: %s\ndescription: x\ntools: Bash\n---\n\n本文\n' "$2" > "$1/$2.md"
}

@test "対象・未指定: general-purpose に model が無ければ deny" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}'
    [ "$output" = "deny" ]
}

@test "対象・未指定: subagent_type そのものが無くても deny" {
    run decide '{"tool_name":"Agent","tool_input":{}}'
    [ "$output" = "deny" ]
}

@test "対象・未指定: subagent_type が null でも deny" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":null}}'
    [ "$output" = "deny" ]
}

@test "対象・未指定: model が null でも deny" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","model":null}}'
    [ "$output" = "deny" ]
}

@test "対象・指定あり: general-purpose に model があれば素通り" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","model":"sonnet"}}'
    [ "$output" = "allow" ]
}

@test "名前付き・定義なし: ローカルに定義が無い型は model が無くても素通り" {
    run decide "$(named claude-code-guide)"
    [ "$output" = "allow" ]
}

@test "名前付き・定義なし: cwd が payload に無くても素通り" {
    run decide '{"tool_name":"Agent","tool_input":{"subagent_type":"claude-code-guide"}}'
    [ "$output" = "allow" ]
}

@test "名前付き・model あり: cwd の .claude/agents/ の定義が model を持てば素通り" {
    define_with_model "$CWD/.claude/agents" reviewer
    run decide "$(named reviewer)"
    [ "$output" = "allow" ]
}

@test "名前付き・model あり: HOME の .claude/agents/ の定義が model を持てば素通り" {
    define_with_model "$HOME/.claude/agents" reviewer
    run decide "$(named reviewer)"
    [ "$output" = "allow" ]
}

@test "名前付き・model なし: cwd の定義が model を持たなければ deny" {
    define_without_model "$CWD/.claude/agents" reviewer
    run decide "$(named reviewer)"
    [ "$output" = "deny" ]
}

@test "名前付き・model なし: HOME の定義が model を持たなければ deny" {
    define_without_model "$HOME/.claude/agents" reviewer
    run decide "$(named reviewer)"
    [ "$output" = "deny" ]
}

@test "名前付き・model なし: 起動側が model を渡していれば定義に無くても素通り" {
    define_without_model "$CWD/.claude/agents" reviewer
    run decide "$(named reviewer ',"model":"sonnet"')"
    [ "$output" = "allow" ]
}

@test "名前付き・model なし: model の値が空なら定義に無い扱いで deny" {
    printf -- '---\nname: reviewer\nmodel:\n---\n' > "$CWD/.claude/agents/reviewer.md"
    run decide "$(named reviewer)"
    [ "$output" = "deny" ]
}

@test "名前付き・壊れた定義: frontmatter で始まらない定義は model ありとみなさず deny" {
    printf -- 'name: reviewer\nmodel: opus\n---\n本文\n' > "$CWD/.claude/agents/reviewer.md"
    run decide "$(named reviewer)"
    [ "$output" = "deny" ]
}

@test "名前付き・壊れた定義: frontmatter が閉じていない定義は model ありとみなさず deny" {
    printf -- '---\nname: reviewer\nmodel: opus\n\n本文\n' > "$CWD/.claude/agents/reviewer.md"
    run decide "$(named reviewer)"
    [ "$output" = "deny" ]
}

@test "名前付き・壊れた定義: 本文側にしか model: が無い定義は deny" {
    printf -- '---\nname: reviewer\n---\nmodel: opus\n' > "$CWD/.claude/agents/reviewer.md"
    run decide "$(named reviewer)"
    [ "$output" = "deny" ]
}

@test "名前付き・壊れた定義: 読めない定義は model ありとみなさず deny" {
    define_with_model "$CWD/.claude/agents" reviewer
    chmod 000 "$CWD/.claude/agents/reviewer.md"
    run decide "$(named reviewer)"
    chmod 644 "$CWD/.claude/agents/reviewer.md"
    [ "$output" = "deny" ]
}

# subagent_type は外から来る値なので、パスの区切りを含む名前で agents/ の外の
# ファイルを定義として読まない。外のファイルは「定義なし」として素通りさせる。
@test "名前付き・区切り入り: agents/ の外を指す名前は定義なしとして素通り" {
    printf -- 'no frontmatter\n' > "$WORK/evil.md"
    run decide "$(named '../../../evil')"
    [ "$output" = "allow" ]
}

@test "名前付き・model なし: deny の理由文に集計用の目印と定義ファイルの場所が入っている" {
    define_without_model "$CWD/.claude/agents" reviewer
    run bash -c "printf '%s' '$(named reviewer)' | bash '$SCRIPT'"
    [[ "$output" == *"[guard-agent-model-unspecified]"* ]]
    [[ "$output" == *"$CWD/.claude/agents/reviewer.md"* ]]
}

@test "別のツール: Bash は素通り" {
    run decide '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
    [ "$output" = "allow" ]
}

@test "壊れた入力: 不正な JSON は素通り(fail-open)" {
    run decide 'not json'
    [ "$output" = "allow" ]
}

# 目印は transcript の集計が拒否を数えるときの照合に使う。文字列を変えると
# 過去の記録と突き合わせられなくなるので、このテストで固定する(issue #44 の条件7)。
@test "deny の理由文に集計用の目印が入っている" {
    run bash -c "printf '%s' '{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\"}}' | bash '$BATS_TEST_DIRNAME/guard-agent-model-unspecified.sh'"
    [[ "$output" == *"[guard-agent-model-unspecified]"* ]]
}
