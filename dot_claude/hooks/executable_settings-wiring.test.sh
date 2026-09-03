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
# COMPACT_PLUS_PRIMARY_BACKEND は chezmoi コミット 32dde68 (2026-07-21) で意図的に削除された。
# claude -p の全面禁止を ask 制へ緩めたのに伴い primary の codex-mini 固定を外し、plugin 既定の
# claude -p へ戻したためである。PRIMARY と FALLBACK が同一 backend を指していてフォールバックが
# 実質機能していなかった状態の是正でもある。よって現在守るべき配線は次の2点。
assert "COMPACT_PLUS_PRIMARY_BACKEND" not in e, "PRIMARY_BACKEND が再設定されている(plugin既定への委譲が壊れる)"
assert "backend-codex-mini.sh" in e.get("COMPACT_PLUS_FALLBACK_BACKEND",""), "fallback backend env 未設定"
# plugin 宣言
assert d.get("enabledPlugins",{}).get("compact-plus@compact-plus-local") is True, "plugin未有効"
assert "compact-plus-local" in d.get("extraKnownMarketplaces",{}), "marketplace未宣言"
print("PASS: settings wiring ok")
PY
