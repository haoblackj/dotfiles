#!/usr/bin/env bats
# mutation-target: none (対象が配置先の成果物と本番のトランスクリプト。隔離下では動かない。issue #20 / #21)
# compact-plus 両取り E2E: producer→plugin③→backend guard→plugin PostCompact→plugin② を
# live実体(deployed producer/backend + plugin cache hooks)で通す。codex は呼ばない(guard経路のみ)。
set -u

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    export TMPDIR="$TMPDIR_TEST"
}

teardown() {
    rm -rf -- "$TMPDIR_TEST"
}

# bats test_tags=production-asset
@test "producer→plugin③→backend guard→plugin PostCompact→plugin②の全体パイプライン" {
    # plugin バージョンをハードコードせず動的解決(更新耐性)
    CACHE=$(find "$HOME/.claude/plugins/cache" -path '*compact-plus/*/hooks' -type d 2>/dev/null | sort -V | tail -1)
    if [[ -z "$CACHE" || ! -d "$CACHE" ]]; then
        skip "compact-plus plugin hooksが未検出($HOME/.claude/plugins/cache 配下を '*compact-plus/*/hooks' で検索したが見つからなかった。installされているか)"
    fi
    PROD=~/.claude/hooks/userpromptsubmit-compact-prep-reminder.sh
    BACKEND=~/.claude/compact-plus-backend/backend-codex-mini.sh
    TP="$HOME/.claude/projects/-home-yagu001-repo-github-com-haoblackj-penguinEx/9bbdb771-6e0a-427a-88e1-c79f8f1d071d.jsonl"
    if [[ ! -f "$TP" ]]; then
        skip "本番トランスクリプトが見つからない: $TP (ローテーションで消失しうる。issue #20 / #21 対象)"
    fi
    SID="e2e$$"
    J="{\"session_id\":\"$SID\",\"transcript_path\":\"$TP\",\"trigger\":\"manual\",\"custom_instructions\":\"\"}"

    # 1) producer: 閾値強制 → claude-compact-warn/$SID (PCT入り)
    CLAUDE_CONTEXT_WINDOW_TOKENS=1 CLAUDE_COMPACT_WARN_THRESHOLD=1 bash -c "echo '$J' | bash '$PROD'" >/dev/null 2>&1
    [ -f "$TMPDIR_TEST/claude-compact-warn/$SID" ] || { echo "producer warn未生成" >&2; return 1; }

    # 2) plugin③: warn消費 → COMPACT REMINDER注入 + warned生成 + warn削除
    OUT=$(echo "$J" | bash "$CACHE/userpromptsubmit-compact-plus-reminder.sh" 2>/dev/null)
    echo "$OUT" | grep -q 'COMPACT REMINDER' || { echo "plugin③ reminder未注入" >&2; return 1; }
    [[ -f "$TMPDIR_TEST/claude-compact-warned/$SID" && ! -f "$TMPDIR_TEST/claude-compact-warn/$SID" ]] || { echo "warn→warned遷移せず" >&2; return 1; }

    # 3) backend guard: fresh .manual → 既存state echo(codex未呼び出し)
    mkdir -p "$TMPDIR_TEST/claude-compact-state"
    printf '# Compact Prep State\nKEEP-MANUAL\n' > "$TMPDIR_TEST/claude-compact-state/$SID.md"
    touch "$TMPDIR_TEST/claude-compact-state/$SID.manual"
    GOUT=$(SESSION_ID="$SID" SYSTEM_PROMPT=x bash "$BACKEND" <<< "prompt")
    echo "$GOUT" | grep -q KEEP-MANUAL || { echo "backend guardが手動state温存せず" >&2; return 1; }

    # 4) plugin PostCompact: claude-compacted/$SID 生成 + warned リセット
    echo "$J" | bash "$CACHE/compaction-recovery.sh" >/dev/null 2>&1
    [ -f "$TMPDIR_TEST/claude-compacted/$SID" ] || { echo "compacted marker未生成" >&2; return 1; }

    # 5) plugin② UPS recovery: compacted消費 → COMPACTION RECOVERY注入
    ROUT=$(echo "$J" | bash "$CACHE/userpromptsubmit-compaction-recovery.sh" 2>/dev/null)
    echo "$ROUT" | grep -q 'COMPACTION RECOVERY' || { echo "plugin② recovery未注入" >&2; return 1; }
}
