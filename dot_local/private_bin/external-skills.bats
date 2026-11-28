#!/usr/bin/env bats
# external-skills（外から取ってくるスキルを宣言ファイルどおりに入れ、最新へ上げる）のテスト。
# npx / npm / herdr / claude / chezmoi は偽物に置き換え、呼ばれた引数を $LOG に残す。
# 偽物の出力の形は本物に合わせてある（2026-11-28 に skills CLI 1.9.1、claude の
# plugin list --json、~/.claude.json の mcpServers、npm pack の tgz の中身で確かめた）。
set -u

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/executable_external-skills"
  T="$(mktemp -d)"
  export HOME="$T/home"
  export LOG="$T/calls.log"
  FAKE="$T/fake"
  SYS="$T/sys"
  mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills" "$FAKE" "$SYS"
  : >"$LOG"
  # 本物の道具のうち、スクリプトが使うものだけを通す（npx などは偽物か「無い」にする）
  for c in jq tar sort mktemp; do ln -s "$(command -v "$c")" "$SYS/$c"; done
  export PATH="$FAKE:$SYS:/usr/bin:/bin"
  export EXTERNAL_SKILLS_FILE="$HOME/.claude/external-skills.txt"
  echo '{"version":3,"skills":{}}' >"$HOME/.agents/.skill-lock.json"
  echo '{}' >"$HOME/.claude.json"
  # npm pack で渡すパッケージの中身（版ごと）
  export PKGS="$T/pkgs"
  mkdir -p "$PKGS"
}

teardown() { rm -rf -- "$T"; }

decl() { printf '%s\n' "$@" >"$EXTERNAL_SKILLS_FILE"; }

fake_npx() {
  cat >"$FAKE/npx" <<'EOF'
#!/bin/bash
echo "npx $*" >>"$LOG"
[ "${FAKE_NPX_FAIL:-}" = 1 ] && exit 1
args=("$@"); [ "${args[0]}" = -y ] && args=("${args[@]:1}")
[ "${args[0]}" = skills ] || exit 2
sub="${args[1]}"
if [ "$sub" = add ]; then
  src="${args[2]}"; name=""
  for ((i = 3; i < ${#args[@]}; i++)); do [ "${args[i]}" = --skill ] && name="${args[i+1]}"; done
  mkdir -p "$HOME/.agents/skills/$name"
  echo "from $src" >"$HOME/.agents/skills/$name/SKILL.md"
  ln -sfn "../../.agents/skills/$name" "$HOME/.claude/skills/$name"
  jq --arg n "$name" --arg s "$src" '.skills[$n] = {source: $s, skillFolderHash: "aaaa1111"}' \
    "$HOME/.agents/.skill-lock.json" >"$HOME/.agents/.skill-lock.json.tmp" &&
    mv "$HOME/.agents/.skill-lock.json.tmp" "$HOME/.agents/.skill-lock.json"
elif [ "$sub" = update ]; then
  name="${args[2]}"
  jq --arg n "$name" '.skills[$n].skillFolderHash = "bbbb2222"' \
    "$HOME/.agents/.skill-lock.json" >"$HOME/.agents/.skill-lock.json.tmp" &&
    mv "$HOME/.agents/.skill-lock.json.tmp" "$HOME/.agents/.skill-lock.json"
fi
EOF
  chmod +x "$FAKE/npx"
}

fake_npm() { # 引数: npm view が返す最新の版
  cat >"$FAKE/npm" <<EOF
#!/bin/bash
echo "npm \$*" >>"\$LOG"
[ "\${FAKE_NPM_FAIL:-}" = 1 ] && exit 1
if [ "\$1" = view ]; then echo "$1"; exit 0; fi
if [ "\$1" = pack ]; then
  for a in "\${@:2}"; do case "\$a" in -*) ;; *) spec="\$a" ;; esac; done; v="\${spec##*@}"
  d=\$(mktemp -d); mkdir -p "\$d/package/skills/reverse-engineer-anything"
  echo "rea skill \$v" >"\$d/package/skills/reverse-engineer-anything/SKILL.md"
  tar czf "rea-agents-\$v.tgz" -C "\$d" package
  echo "rea-agents-\$v.tgz"
fi
EOF
  chmod +x "$FAKE/npm"
}

fake_herdr() {
  cat >"$FAKE/herdr" <<'EOF'
#!/bin/bash
echo "herdr $*" >>"$LOG"
[ "$1" = --skill ] && printf -- '---\nname: herdr\n---\nbody %s\n' "${HERDR_BODY:-v1}"
EOF
  chmod +x "$FAKE/herdr"
}

fake_claude() {
  cat >"$FAKE/claude" <<'EOF'
#!/bin/bash
echo "claude $*" >>"$LOG"
case "$1 $2" in
  "mcp remove") jq 'del(.mcpServers.rea)' "$HOME/.claude.json" >"$HOME/.claude.json.tmp" && mv "$HOME/.claude.json.tmp" "$HOME/.claude.json" ;;
  "mcp add-json") jq --argjson v "$4" '.mcpServers.rea = $v' "$HOME/.claude.json" >"$HOME/.claude.json.tmp" && mv "$HOME/.claude.json.tmp" "$HOME/.claude.json" ;;
  "plugin list") echo '[{"id":"a@m1","enabled":true},{"id":"b@m2","enabled":false}]' ;;
esac
exit 0
EOF
  chmod +x "$FAKE/claude"
}

run_es() { run bash "$SCRIPT" "$@"; }
# bats の中の `! grep` はテストを落とさないので、見つかったら 1 を返す関数にする
nogrep() { if grep -q "$@"; then return 1; fi; }

# =========================================================================
# skills の取り方
# =========================================================================

@test "skills: 入っていなければ skills CLI で claude-code と codex へ入れる" {
  fake_npx
  decl "imozuru skills MaryCache/imozuru"
  run_es install
  [ "$status" -eq 0 ]
  grep -qx 'npx -y skills add MaryCache/imozuru --skill imozuru -g -y -a claude-code codex' "$LOG"
  [ "$(readlink "$HOME/.claude/skills/imozuru")" = "../../.agents/skills/imozuru" ]
}

@test "skills: 記録の取得元が宣言と同じでリンクが張ってあれば何もしない" {
  fake_npx
  decl "imozuru skills MaryCache/imozuru"
  bash "$SCRIPT" install >/dev/null 2>&1
  : >"$LOG"
  run_es install
  [ "$status" -eq 0 ]
  nogrep 'skills add' "$LOG"
}

@test "skills: 記録の取得元が宣言と違えば入れ直す" {
  fake_npx
  decl "imozuru skills MaryCache/imozuru"
  bash "$SCRIPT" install >/dev/null 2>&1
  decl "imozuru skills Other/imozuru"
  : >"$LOG"
  run_es install
  [ "$status" -eq 0 ]
  grep -q 'skills add Other/imozuru --skill imozuru' "$LOG"
}

@test "skills: claude-private などへの生きたリンクは触らず失敗にする" {
  fake_npx
  mkdir -p "$HOME/.local/share/claude-private/skills/imozuru"
  ln -s "$HOME/.local/share/claude-private/skills/imozuru" "$HOME/.claude/skills/imozuru"
  decl "imozuru skills MaryCache/imozuru" "yomiyasu skills nanaism/yomiyasu cloud"
  run_es install
  [ "$status" -eq 1 ]
  nogrep 'skills add MaryCache/imozuru' "$LOG"
  [ "$(readlink "$HOME/.claude/skills/imozuru")" = "$HOME/.local/share/claude-private/skills/imozuru" ]
  # ほかの行は続ける
  grep -q 'skills add nanaism/yomiyasu --skill yomiyasu' "$LOG"
  [[ "$output" == *"imozuru"*"失敗"* ]]
}

@test "skills: 実体のディレクトリは触らず失敗にする" {
  fake_npx
  mkdir -p "$HOME/.claude/skills/imozuru"
  echo mine >"$HOME/.claude/skills/imozuru/SKILL.md"
  decl "imozuru skills MaryCache/imozuru"
  run_es install
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.claude/skills/imozuru/SKILL.md")" = mine ]
}

@test "skills: 先の無いリンクは外して入れる" {
  fake_npx
  ln -s "$HOME/.local/share/claude-private/skills/imozuru" "$HOME/.claude/skills/imozuru"
  decl "imozuru skills MaryCache/imozuru"
  run_es install
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.claude/skills/imozuru")" = "../../.agents/skills/imozuru" ]
}

@test "skills: npx が無ければ警告して飛ばし、失敗に数えない" {
  decl "imozuru skills MaryCache/imozuru"
  run_es install
  [ "$status" -eq 0 ]
  [[ "$output" == *"imozuru"*"飛ばした"* ]]
}

@test "skills: skills CLI が失敗したら失敗にする" {
  fake_npx
  decl "imozuru skills MaryCache/imozuru"
  FAKE_NPX_FAIL=1 run_es install
  [ "$status" -eq 1 ]
}

@test "宣言のコメント行と空行は読まない" {
  fake_npx
  decl "# comment" "" "imozuru skills MaryCache/imozuru"
  run_es install
  [ "$status" -eq 0 ]
  [ "$(grep -c 'skills add' "$LOG")" = 1 ]
}

# =========================================================================
# herdr の取り方
# =========================================================================

@test "herdr: 本体の --skill の出力を書き、リンクを張り、skills CLI の記録から消す" {
  fake_herdr
  jq '.skills.herdr = {source: "ogulcancelik/herdr"}' "$HOME/.agents/.skill-lock.json" >"$T/l" && mv "$T/l" "$HOME/.agents/.skill-lock.json"
  decl "herdr herdr herdr"
  run_es install
  [ "$status" -eq 0 ]
  grep -q 'body v1' "$HOME/.agents/skills/herdr/SKILL.md"
  [ "$(readlink "$HOME/.claude/skills/herdr")" = "../../.agents/skills/herdr" ]
  [ "$(jq '.skills | has("herdr")' "$HOME/.agents/.skill-lock.json")" = false ]
}

# =========================================================================
# rea の取り方
# =========================================================================

@test "rea: 宣言の版のパッケージからスキルを写し、MCP の登録を同じ版にして環境変数を保つ" {
  fake_npm 6.9.0; fake_claude
  echo '{"mcpServers":{"rea":{"type":"stdio","command":"npx","args":["-y","rea-agents@6.7.0","mcp"],"env":{"JAVA_HOME":"/j"}}}}' >"$HOME/.claude.json"
  decl "reverse-engineer-anything rea rea-agents 6.9.0"
  run_es install
  [ "$status" -eq 0 ]
  grep -q 'rea skill 6.9.0' "$HOME/.agents/skills/reverse-engineer-anything/SKILL.md"
  [ "$(readlink "$HOME/.claude/skills/reverse-engineer-anything")" = "../../.agents/skills/reverse-engineer-anything" ]
  [ "$(jq -c '.mcpServers.rea.args' "$HOME/.claude.json")" = '["-y","rea-agents@6.9.0","mcp"]' ]
  [ "$(jq -r '.mcpServers.rea.env.JAVA_HOME' "$HOME/.claude.json")" = /j ]
  grep -q 'claude mcp remove rea -s user' "$LOG"
}

@test "rea: 版もリンクも MCP の登録も宣言どおりなら何もしない" {
  fake_npm 6.9.0; fake_claude
  decl "reverse-engineer-anything rea rea-agents 6.9.0"
  bash "$SCRIPT" install >/dev/null 2>&1
  grep -q 'rea skill 6.9.0' "$HOME/.agents/skills/reverse-engineer-anything/SKILL.md"
  : >"$LOG"
  run_es install
  [ "$status" -eq 0 ]
  nogrep 'npm pack' "$LOG"
  nogrep 'claude mcp' "$LOG"
}

@test "rea: 登録が無い機械では環境変数なしで登録し、Ghidra の場所を足すよう表示する" {
  fake_npm 6.9.0; fake_claude
  decl "reverse-engineer-anything rea rea-agents 6.9.0"
  run_es install
  [ "$status" -eq 0 ]
  [ "$(jq -c '.mcpServers.rea.args' "$HOME/.claude.json")" = '["-y","rea-agents@6.9.0","mcp"]' ]
  [[ "$output" == *"GHIDRA_INSTALL_DIR"* ]]
}

@test "rea: 古い写しの実体があっても ~/.agents の側は入れ替える" {
  fake_npm 6.9.0; fake_claude
  mkdir -p "$HOME/.agents/skills/reverse-engineer-anything"
  echo old >"$HOME/.agents/skills/reverse-engineer-anything/OLD.md"
  decl "reverse-engineer-anything rea rea-agents 6.9.0"
  run_es install
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.agents/skills/reverse-engineer-anything/OLD.md" ]
}

# =========================================================================
# update
# =========================================================================

@test "update: プラグインの目録と入っている全プラグインを更新し、skills の行を最新へ上げる" {
  fake_npx; fake_claude
  decl "imozuru skills MaryCache/imozuru"
  bash "$SCRIPT" install >/dev/null 2>&1
  : >"$LOG"
  run_es update
  [ "$status" -eq 0 ]
  grep -qx 'claude plugin marketplace update' "$LOG"
  grep -qx 'claude plugin update a@m1' "$LOG"
  grep -qx 'claude plugin update b@m2' "$LOG"
  grep -qx 'npx -y skills update imozuru -g -y' "$LOG"
  [[ "$output" == *"imozuru"*"aaaa111"*"bbbb222"* ]]
}

@test "update: rea の新しい版があれば chezmoi のソースの宣言を書き換え、入れ直し、コミットが要ると出す" {
  fake_npm 6.10.1; fake_claude
  SRCDECL="$T/source/dot_claude/external-skills.txt"
  mkdir -p "$(dirname "$SRCDECL")"
  cat >"$FAKE/chezmoi" <<EOF
#!/bin/bash
echo "chezmoi \$*" >>"\$LOG"
[ "\$1" = source-path ] && echo "$SRCDECL"
EOF
  chmod +x "$FAKE/chezmoi"
  decl "reverse-engineer-anything rea rea-agents 6.9.0"
  cp "$EXTERNAL_SKILLS_FILE" "$SRCDECL"
  bash "$SCRIPT" install >/dev/null 2>&1
  run_es update
  [ "$status" -eq 0 ]
  grep -qx 'reverse-engineer-anything rea rea-agents 6.10.1' "$SRCDECL"
  grep -qx 'reverse-engineer-anything rea rea-agents 6.10.1' "$EXTERNAL_SKILLS_FILE"
  [ "$(jq -c '.mcpServers.rea.args' "$HOME/.claude.json")" = '["-y","rea-agents@6.10.1","mcp"]' ]
  [[ "$output" == *"コミット"* ]]
}

@test "update: 一つの行が失敗しても続け、1 で終える" {
  fake_npx; fake_claude; fake_npm 6.9.0
  decl "reverse-engineer-anything rea rea-agents 6.9.0" "imozuru skills MaryCache/imozuru"
  bash "$SCRIPT" install >/dev/null 2>&1
  : >"$LOG"
  FAKE_NPM_FAIL=1 run_es update
  [ "$status" -eq 1 ]
  grep -q 'skills update imozuru' "$LOG"
}

@test "引数が無ければ使い方を出して 2 で終える" {
  run_es
  [ "$status" -eq 2 ]
}
