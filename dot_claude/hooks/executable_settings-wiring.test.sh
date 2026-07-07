#!/bin/bash
# compact-plus 両取り統合の settings.json 配線検証(source private_settings.json 対象)。
set -uo pipefail
S=~/.local/share/chezmoi/dot_claude/private_settings.json
python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
def cmds(ev): return " ".join(x.get("command","") for g in h.get(ev,[]) for x in g.get("hooks",[]))
ups=cmds("UserPromptSubmit")
# 我々の重複②③は配線から除去済み
assert "userpromptsubmit-compaction-recovery.sh" not in ups, "UPS recovery(重複)が残存"
assert not h.get("PostCompact"), "PostCompact(重複recovery)が残存"
# producer は残存
assert "userpromptsubmit-compact-prep-reminder.sh" in ups, "producer が無い"
# env
e=d.get("env",{})
assert e.get("COMPACT_PLUS_TRANSCRIPT_MODE")=="tail", "MODE!=tail"
assert e.get("COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS")=="60", "TAIL_TURNS!=60"
assert e.get("COMPACT_PLUS_TRANSCRIPT_TAIL_KB")=="120", "TAIL_KB!=120"
assert "backend-codex-mini.sh" in e.get("COMPACT_PLUS_PRIMARY_BACKEND",""), "backend env 未設定"
# plugin 宣言
assert d.get("enabledPlugins",{}).get("compact-plus@compact-plus-local") is True, "plugin未有効"
assert "compact-plus-local" in d.get("extraKnownMarketplaces",{}), "marketplace未宣言"
print("PASS: settings wiring ok")
PY
