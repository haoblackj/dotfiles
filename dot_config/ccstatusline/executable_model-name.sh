#!/usr/bin/env bash
# ccstatusline の Model ウィジェットは表示名の末尾の括弧を丸ごと削る
# (modelDisplayName.replace(/\s*\(.*\)$/, ""))。Claude Code が渡す表示名は
# "Opus 5 (1M context)" なので、1M 版かどうかがステータスラインから読み取れない。
# stdin の statusline JSON から表示名を自前で組み立て、1M 版だけ末尾に印を残す。
set -euo pipefail

exec python3 -c '
import json, re, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

model = data.get("model")
if isinstance(model, str):
    model_id = name = model
elif isinstance(model, dict):
    model_id = model.get("id") or ""
    name = model.get("display_name") or model_id
else:
    sys.exit(0)

if not name:
    sys.exit(0)

# 本家と同じく末尾の括弧を落としたうえで、1M 版にだけ印を戻す。
short = re.sub(r"\s*\(.*\)$", "", name).strip()
# 表示名が無く id へフォールバックしたときの "claude-opus-5[1m]" から重複する印を落とす。
short = re.sub(r"\[[^\]]*\]$", "", short).strip()
is_1m = bool(re.search(r"\(\s*1M\b", name, re.I) or re.search(r"\[1m\]", model_id, re.I))
sys.stdout.write(short + (" 1M" if is_1m else ""))
'
