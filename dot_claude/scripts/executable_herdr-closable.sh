#!/bin/bash
# Herdr の同じワークスペースから、掃除の候補を最後の応答つきで出す。
# 閉じてよいかの判断はここではせず、Claude が last_reply を読んで決める。
# list は候補を出すだけで、close に渡されたペインのタブだけを閉じる。
#
# 使い方:
#   herdr-closable.sh list [--exclude-pane <ペイン ID> ...]
#   herdr-closable.sh close <ペイン ID>=<session_id> ...
#
# 自分のペインとワークスペースは pane current --current から取る。
# list は自分、指定されたペイン、ループ、未応答、複数の transcript を除く。
# close はペインごとに一覧と現在のペインを取り直し、同じワークスペースの
# 自分以外の Claude でループの印が無く、idle、タブの唯一のペイン、
# ワークスペースに二つ以上のタブがあり、セッションが同じで新しい入力が無いことを確かめて閉じる。
#
# fail-open: 情報の取得に失敗したら閉じず、list は黙って exit 0。
# close の取得や終了の失敗は kept と reason:error を出す。
# tab close の失敗やタイムアウトでは、実際には既に閉じている場合もある。
# list の引数が誤っていれば、理由を標準エラーに出して exit 1。
# herdr が応答しないときも待ち続けないように、呼び出しは timeout 5 で括る。

set -uo pipefail

die() { printf 'herdr-closable: %s\n' "$1" >&2; exit 1; }

herdr_ready() {
    [[ "${HERDR_ENV:-}" == 1 ]] || return 1
    command -v herdr >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1
}

# ID をファイル名や herdr の引数として使うので、親参照やオプションを受け付けない。
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9:._-]*$ && "$1" != *..* ]]; }

read_panes() {
    local response
    response=$(timeout 5 herdr pane list 2>/dev/null) || return 1
    jq -ce '.result.panes | select(type == "array") |
        select(all(.[];
            (.pane_id | type == "string" and length > 0) and
            (.tab_id | type == "string" and length > 0) and
            (.workspace_id | type == "string" and length > 0)))' <<< "$response" 2>/dev/null
}

last_reply() {
    # transcript は応答の要素ごとに分かれるので、最後の入力以後の text を順に足す。
    # tool_result だけの user 行、メタの入力、サイドチェーンは入力に数えない。
    jq -nc '
        def user_input:
            .type == "user" and .isMeta != true and
            (.message.content | if type == "string" then true
                elif type == "array" then any(.[]; .type == "text")
                else false end);
        reduce inputs as $row ({have_user:false, reply:null};
            if $row.isSidechain == true then .
            elif ($row | user_input) then {have_user:true, reply:null}
            elif .have_user and $row.type == "assistant" then
                reduce ($row.message.content | arrays | .[] |
                    select(.type == "text" and (.text | type == "string")) | .text) as $text
                    (.; .reply = ((.reply // "") + $text))
            else . end)
        | select(.have_user and .reply != null) | .reply
        | if length > 2000 then "…" + .[-2000:] else . end
    ' "$1" 2>/dev/null
}

# transcript を一つだけ読み、未応答なら 2、取得や読み取りの失敗なら 1 を返す。
session_reply() {
    local session="$1" reply
    local -a transcripts=()
    valid_id "$session" || return 1
    shopt -s nullglob
    transcripts=("$HOME"/.claude/projects/*/"$session.jsonl")
    (( ${#transcripts[@]} == 1 )) || return 1
    [[ -f "${transcripts[0]}" && -r "${transcripts[0]}" ]] || return 1
    reply=$(last_reply "${transcripts[0]}") || return 1
    [[ -n "$reply" ]] || return 2
    printf '%s\n' "$reply"
}

list_candidates() {
    local current workspace self excluded panes candidates candidate session reply
    local -a exclude_panes=()
    while (( $# > 0 )); do
        case "$1" in
            --exclude-pane)
                [[ -n "${2:-}" && "$2" != --* ]] || die "--exclude-pane に値が無い"
                exclude_panes+=("$2")
                shift 2 ;;
            *) die "知らない引数: $1" ;;
        esac
    done

    herdr_ready || return 0
    current=$(timeout 5 herdr pane current --current 2>/dev/null) || return 0
    workspace=$(jq -er '.result.pane.workspace_id | strings | select(length > 0)' <<< "$current" 2>/dev/null) || return 0
    self=$(jq -er '.result.pane.pane_id | strings | select(length > 0)' <<< "$current" 2>/dev/null) || return 0
    exclude_panes+=("$self")
    excluded=$(jq -nc --args '$ARGS.positional' "${exclude_panes[@]}") || return 0
    panes=$(read_panes) || return 0
    candidates=$(jq -c --arg workspace "$workspace" --argjson excluded "$excluded" '
        . as $panes | .[] |
        select(.workspace_id == $workspace and .agent == "claude" and .agent_status == "idle") |
        select(.pane_id as $id | $excluded | index($id) == null) |
        select(.agent_session.value | type == "string" and length > 0) |
        . as $pane |
        select([$panes[] | select(.tab_id == $pane.tab_id)] | length == 1) |
        select([$panes[] | select(.workspace_id == $workspace) | .tab_id] | unique | length >= 2) |
        {pane:.pane_id, tab:.tab_id, session_id:.agent_session.value, title:(.terminal_title_stripped // "")}
    ' <<< "$panes" 2>/dev/null) || return 0

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        session=$(jq -r '.session_id' <<< "$candidate")
        valid_id "$session" || continue
        [[ ! -e "${TMPDIR:-/tmp}/claude-loop-guard/$session.prompts" ]] || continue
        reply=$(session_reply "$session") || continue
        jq -c --argjson reply "$reply" '. + {last_reply:$reply}' <<< "$candidate"
    done <<< "$candidates"
}

kept() {
    jq -nc --arg pane "$1" --arg reason "$2" '{pane:$pane, result:"kept", reason:$reason}'
}

close_pane() {
    local pane="$1" expected_session="$2" panes current workspace self check reason tab session result
    panes=$(read_panes) || return 1
    current=$(timeout 5 herdr pane current --current 2>/dev/null) || return 1
    workspace=$(jq -er '.result.pane.workspace_id | strings | select(length > 0)' <<< "$current" 2>/dev/null) || return 1
    self=$(jq -er '.result.pane.pane_id | strings | select(length > 0)' <<< "$current" 2>/dev/null) || return 1
    check=$(jq -ce --arg pane "$pane" --arg workspace "$workspace" --arg self "$self" '
            . as $panes | [.[] | select(.pane_id == $pane)] |
            if length != 1 then {reason:"not_found"}
            else .[0] as $target |
                if $target.workspace_id != $workspace then {reason:"other_workspace"}
                elif $target.agent != "claude" then {reason:"not_claude"}
                elif $target.pane_id == $self then {reason:"self"}
                elif $target.agent_status != "idle" then {reason:"not_idle"}
                elif ([$panes[] | select(.tab_id == $target.tab_id)] | length) != 1 then {reason:"shared_tab"}
                elif ([$panes[] | select(.workspace_id == $target.workspace_id) | .tab_id] | unique | length) < 2 then {reason:"last_tab"}
                else {tab:$target.tab_id, session:$target.agent_session.value} end
            end
        ' <<< "$panes" 2>/dev/null) || return 1
    reason=$(jq -r '.reason // empty' <<< "$check" 2>/dev/null) || return 1
    if [[ -n "$reason" ]]; then
        kept "$pane" "$reason"
        return
    fi
    tab=$(jq -er '.tab | strings | select(length > 0)' <<< "$check" 2>/dev/null) || return 1
    session=$(jq -er '.session | strings | select(length > 0)' <<< "$check" 2>/dev/null) || return 1
    valid_id "$tab" && valid_id "$session" || return 1
    if [[ "$session" != "$expected_session" ]]; then
        kept "$pane" session_changed
        return
    fi
    if [[ -e "${TMPDIR:-/tmp}/claude-loop-guard/$session.prompts" ]]; then
        kept "$pane" loop
        return
    fi
    session_reply "$session" >/dev/null
    result=$?
    if (( result == 2 )); then
        kept "$pane" new_input
        return
    fi
    (( result == 0 )) || return 1
    timeout 5 herdr tab close "$tab" >/dev/null 2>&1 || return 1
    jq -nc --arg pane "$pane" --arg tab "$tab" '{pane:$pane, tab:$tab, result:"closed"}'
}

close_panes() {
    local argument pane session
    for argument in "$@"; do
        pane="${argument%%=*}"
        valid_id "$pane" || die "ペインを読み取れない引数: $argument"
        session="${argument#*=}"
        if [[ "$argument" != *=* ]] || ! valid_id "$session"; then
            kept "$pane" error
            continue
        fi
        herdr_ready || continue
        close_pane "$pane" "$session" || kept "$pane" error
    done
}

case "${1:-}" in
    list) shift; list_candidates "$@" ;;
    close) shift; close_panes "$@" ;;
esac
exit 0
