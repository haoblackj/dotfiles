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

# bats test_tags=production-asset
@test "loop-guard.sh が PreToolUse（ScheduleWakeup と CronCreate）と UserPromptSubmit に配線されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
def groups(ev): return [g for g in h.get(ev,[]) if any("loop-guard.sh" in x.get("command","") for x in g.get("hooks",[]))]
pre=groups("PreToolUse")
assert len(pre)==1, f"PreToolUse: loop-guard.sh の配線が {len(pre)} 件"
assert set(pre[0].get("matcher","").split("|"))=={"ScheduleWakeup","CronCreate"}, f"matcher={pre[0].get('matcher')!r}"
# 固定間隔のループの発火を見るため、UserPromptSubmit にも要る（haoblackj/dotfiles#69）
assert len(groups("UserPromptSubmit"))==1, "UserPromptSubmit に無い"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "chat-context-guard.sh が UserPromptSubmit に配線されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
for ev, hs in h.items():
    n=sum(1 for g in hs for x in g.get("hooks",[]) if "chat-context-guard.sh" in x.get("command",""))
    assert n==(1 if ev=="UserPromptSubmit" else 0), f"{ev}: chat-context-guard.sh の配線が {n} 件"
print("PASS")
PY
}

# GitHub の本文に推測の時刻を書かせないため、gh の本文に手書きの時刻があれば止める（haoblackj/dotfiles#75）。
# command はファイルが無いとき何もしない形にしてある。python3 は無いファイルを渡されると
# 終了コード 2 で終わり、PreToolUse ではそれが deny になって Bash の呼び出しが全部止まる
# （settings.json が symlink で先に効き、chezmoi apply がまだのときに起きる）。
# bats test_tags=production-asset
@test "guard-gh-body-time.py が PreToolUse の Bash に配線されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
for ev, hs in h.items():
    gs=[g for g in hs if any("guard-gh-body-time.py" in x.get("command","") for x in g.get("hooks",[]))]
    if ev=="PreToolUse":
        assert len(gs)==1 and gs[0].get("matcher")=="Bash", f"PreToolUse: {gs!r}"
    else:
        assert not gs, f"{ev} に配線がある"
print("PASS")
PY
}
