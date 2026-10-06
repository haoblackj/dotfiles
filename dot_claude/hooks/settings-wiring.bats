#!/usr/bin/env bats
# settings.json の配線検証(source linked/claude/settings.json 対象)。
#
# 1つの python3 プロセスで assert を直列に並べると、最初の失敗で後続が実行されない
# (Python の assert の仕様)。配線ごとに独立した @test に分け、1件落ちても残りの結果が分かるようにする。
set -u

setup() {
    # テストを走らせたチェックアウトの settings.json を読む。main のチェックアウトを決め打ちすると、
    # settings.json を変えるブランチ（ワークツリー）からの push で pre-push の bats が落ちる（#31）
    S="${S_OVERRIDE:-$BATS_TEST_DIRNAME/../../linked/claude/settings.json}"
}

# bats test_tags=production-asset
@test "UserPromptSubmitにUPS recovery(重複)が残存していない" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
def cmds(ev): return " ".join(x.get("command","") for g in h.get(ev,[]) for x in g.get("hooks",[]))
ups=cmds("UserPromptSubmit")
# 我々の重複②③は配線から除去済み
assert "userpromptsubmit-compaction-recovery.sh" not in ups, "UPS recovery(重複)が残存"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "PostCompact(重複recovery)が残存していない" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
assert not h.get("PostCompact"), "PostCompact(重複recovery)が残存"
print("PASS")
PY
}

# compact-plus は 2026-10-06 に撤去した（haoblackj/dotfiles#37）。フォールバックのモデルが
# 退役し、上流の保守も止まったため。使用率の印を書くだけの自作フック
# userpromptsubmit-compact-prep-reminder.sh も、印を読む側（compact-plus）が無くなるので外した。
# bats test_tags=production-asset
@test "compact-plus の配線が残っていない" {
    python3 - "$S" <<'PY2'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
cmds=" ".join(x.get("command","") for gs in h.values() for g in gs for x in g.get("hooks",[]))
assert "compact-plus@compact-plus-local" not in d.get("enabledPlugins",{}), "plugin が残っている"
assert "compact-plus-local" not in d.get("extraKnownMarketplaces",{}), "marketplace が残っている"
left=[k for k in d.get("env",{}) if k.startswith("COMPACT_PLUS_")]
assert not left, f"env が残っている: {left}"
assert "userpromptsubmit-compact-prep-reminder.sh" not in cmds, "reminder の配線が残っている"
print("PASS")
PY2
}

# bats test_tags=production-asset
@test "languageがjapanese(自動タイトルを日本語に固定する。haoblackj/dotfiles#11)" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("language")=="japanese", "language!=japanese"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "session-title-promote.shがSessionStartとUserPromptSubmitの両方に配線されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
def cmds(ev): return " ".join(x.get("command","") for g in h.get(ev,[]) for x in g.get("hooks",[]))
assert "session-title-promote.sh" in cmds("SessionStart"), "SessionStart に無い"
assert "session-title-promote.sh" in cmds("UserPromptSubmit"), "UserPromptSubmit に無い"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "gh-bot-token.sh session がSessionStartに配線されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
cmds=[x.get("command","") for g in h.get("SessionStart",[]) for x in g.get("hooks",[])]
assert any("gh-bot-token.sh" in c and c.rstrip().endswith("session") for c in cmds), "SessionStart に無い"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "statusLineは従来どおりstatusline-context-window.shを指す" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert "statusline-context-window.sh" in d.get("statusLine",{}).get("command",""), "statusLine が変わっている"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "PostToolUse と PostToolUseFailure に usage-route.sh が全ツールで配線されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
# 失敗したツール呼び出しは PostToolUseFailure だけが届くので、両方に要る（haoblackj/dotfiles#29）
for ev in ("PostToolUse","PostToolUseFailure"):
    groups=[g for g in h.get(ev,[]) if any("usage-route.sh" in x.get("command","") for x in g.get("hooks",[]))]
    assert len(groups)==1, f"{ev}: usage-route.sh の配線が {len(groups)} 件"
    assert groups[0].get("matcher")=="*", f"{ev}: matcher={groups[0].get('matcher')!r}"
print("PASS")
PY
}
