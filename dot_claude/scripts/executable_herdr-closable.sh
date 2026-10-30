#!/bin/bash
# Herdr の同じワークスペースから、掃除の候補を最後の応答つきで出す。
# 閉じてよいかの判断はここではせず、Claude が last_reply を読んで決める。
# list は候補を出すだけで、close に渡されたペインのタブだけを閉じる。
#
# 使い方:
#   herdr-closable.sh list [--exclude-pane <ペイン ID> ...]
#   herdr-closable.sh close <ペイン ID> ...
#
# 自分のペインとワークスペースは pane current --current から取る。
# list は自分、指定されたペイン、ループ、未応答、複数の transcript を除く。
# close はペインごとに一覧を取り直し、idle、タブの唯一のペイン、
# ワークスペースに二つ以上のタブがあることを確かめてから閉じる。
#
# fail-open: 取得できない情報があれば何も閉じず、黙って exit 0。
# herdr が応答しないときも待ち続けないように、呼び出しは timeout 5 で括る。

set -uo pipefail

[[ "${HERDR_ENV:-}" == 1 ]] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v timeout >/dev/null 2>&1 || exit 0

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
    ' "$1" 2>/dev/null
}

list_candidates() {
    local current workspace self excluded panes candidates candidate session reply
    local -a exclude_panes=() transcripts=()
    while (( $# > 0 )); do
        [[ "$1" == --exclude-pane && -n "${2:-}" ]] || return 0
        exclude_panes+=("$2")
        shift 2
    done

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

    shopt -s nullglob
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        session=$(jq -r '.session_id' <<< "$candidate")
        valid_id "$session" || continue
        [[ ! -e "${TMPDIR:-/tmp}/claude-loop-guard/$session.prompts" ]] || continue
        transcripts=("$HOME"/.claude/projects/*/"$session.jsonl")
        (( ${#transcripts[@]} == 1 )) || continue
        [[ -f "${transcripts[0]}" && -r "${transcripts[0]}" ]] || continue
        reply=$(last_reply "${transcripts[0]}") || continue
        [[ -n "$reply" ]] || continue
        jq -c --argjson reply "$reply" '. + {last_reply:$reply}' <<< "$candidate"
    done <<< "$candidates"
}

kept() {
    jq -nc --arg pane "$1" --arg reason "$2" '{pane:$pane, result:"kept", reason:$reason}'
}

close_panes() {
    local pane panes check reason tab
    for pane in "$@"; do
        panes=$(read_panes) || continue
        check=$(jq -c --arg pane "$pane" '
            . as $panes | [.[] | select(.pane_id == $pane)] |
            if length != 1 then {reason:"not_found"}
            else .[0] as $target |
                if $target.agent_status != "idle" then {reason:"not_idle"}
                elif ([$panes[] | select(.tab_id == $target.tab_id)] | length) != 1 then {reason:"shared_tab"}
                elif ([$panes[] | select(.workspace_id == $target.workspace_id) | .tab_id] | unique | length) < 2 then {reason:"last_tab"}
                else {tab:$target.tab_id} end
            end
        ' <<< "$panes" 2>/dev/null) || continue
        reason=$(jq -r '.reason // empty' <<< "$check")
        if [[ -n "$reason" ]]; then
            kept "$pane" "$reason"
            continue
        fi
        tab=$(jq -r '.tab' <<< "$check")
        valid_id "$tab" || continue
        timeout 5 herdr tab close "$tab" >/dev/null 2>&1 || continue
        jq -nc --arg pane "$pane" --arg tab "$tab" '{pane:$pane, tab:$tab, result:"closed"}'
    done
}

case "${1:-}" in
    list) shift; list_candidates "$@" ;;
    close) shift; close_panes "$@" ;;
esac
exit 0
