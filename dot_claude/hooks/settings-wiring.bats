#!/usr/bin/env bats
# mutation-target: none (対象が private_settings.json という設定ファイルでスクリプトではない)
# compact-plus 両取り統合の settings.json 配線検証(source private_settings.json 対象)。
#
# 元は10件のassertを1つのpython3プロセス内で直列実行しており、最初の失敗で
# AssertionErrorを投げて後続が一切実行されなかった(Pythonのassertの仕様)。
# ここでは10件それぞれを独立した@testに分け、1件落ちても残り9件の結果が
# 分かるようにする。分けるのは実行の単位であり、判定内容(各assertの条件・
# メッセージ)は変えない。
set -u

setup() {
    S=~/.local/share/chezmoi/dot_claude/private_settings.json
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

# bats test_tags=production-asset
@test "producer(userpromptsubmit-compact-prep-reminder.sh)が配線されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{})
def cmds(ev): return " ".join(x.get("command","") for g in h.get(ev,[]) for x in g.get("hooks",[]))
ups=cmds("UserPromptSubmit")
# producer は残存
assert "userpromptsubmit-compact-prep-reminder.sh" in ups, "producer が無い"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "env.COMPACT_PLUS_TRANSCRIPT_MODEがtail" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get("env",{})
assert e.get("COMPACT_PLUS_TRANSCRIPT_MODE")=="tail", "MODE!=tail"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "env.COMPACT_PLUS_TRANSCRIPT_TAIL_TURNSが60" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get("env",{})
assert e.get("COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS")=="60", "TAIL_TURNS!=60"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "env.COMPACT_PLUS_TRANSCRIPT_TAIL_KBが120" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get("env",{})
assert e.get("COMPACT_PLUS_TRANSCRIPT_TAIL_KB")=="120", "TAIL_KB!=120"
print("PASS")
PY
}

# COMPACT_PLUS_PRIMARY_BACKEND は chezmoi コミット 32dde68 (2026-07-21) で意図的に削除された。
# claude -p の全面禁止を ask 制へ緩めたのに伴い primary の codex-mini 固定を外し、plugin 既定の
# claude -p へ戻したためである。PRIMARY と FALLBACK が同一 backend を指していてフォールバックが
# 実質機能していなかった状態の是正でもある。よって現在守るべき配線は次の2点。
# bats test_tags=production-asset
@test "env.COMPACT_PLUS_PRIMARY_BACKENDが再設定されていない(plugin既定への委譲を壊さない)" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get("env",{})
assert "COMPACT_PLUS_PRIMARY_BACKEND" not in e, "PRIMARY_BACKEND が再設定されている(plugin既定への委譲が壊れる)"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "env.COMPACT_PLUS_FALLBACK_BACKENDがbackend-codex-mini.shを指す" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get("env",{})
assert "backend-codex-mini.sh" in e.get("COMPACT_PLUS_FALLBACK_BACKEND",""), "fallback backend env 未設定"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "compact-plus@compact-plus-local pluginが有効" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
# plugin 宣言
assert d.get("enabledPlugins",{}).get("compact-plus@compact-plus-local") is True, "plugin未有効"
print("PASS")
PY
}

# bats test_tags=production-asset
@test "compact-plus-local marketplaceが宣言されている" {
    python3 - "$S" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert "compact-plus-local" in d.get("extraKnownMarketplaces",{}), "marketplace未宣言"
print("PASS")
PY
}
