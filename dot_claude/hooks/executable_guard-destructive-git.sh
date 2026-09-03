#!/usr/bin/env bash
# 破壊的な git 操作を止める PreToolUse フック。
#
# グローバル CLAUDE.md は `git reset --hard` / `git push --force` / `git clean -f` /
# `git branch -D` / `git checkout --` を「指示の有無にかかわらず提案も実行もしない」と
# 定めている。これを settings.json の permissions.deny で塞ごうとしていたが、
# それでは足りないことが 2026-09-03 の棚卸しで分かった。
#
#   - deny のパターンは短縮形しか列挙していなかった（`git clean -f*` など）。
#   - パターンは「最初の `*` より前のリテラル」で前方一致する。
#     つまり `git clean --force` は `git clean -f*` に一致しない。
#   - 評価順は deny → ask → allow で最初に一致したものが決まる。allow には
#     `Bash(git *)` があるので、deny をすり抜けた長形はそのまま無確認で通っていた。
#
# パターンで塞ぐのをやめ、引数を読んで判定する。route-deletes-to-trash.sh と同型。
# 前方一致と違い、複合コマンド（`cd x && git reset --hard`）も捕まえる。
#
# 判定の方針:
#   - コマンド境界（行頭、`;` `&` `|` `(` `)`）に立つ git だけを見る。
#     `echo "git reset --hard"` のような言及は通す。
#   - サブコマンドの前に挟まるグローバルオプション（`-C <dir>`、`-c k=v`、
#     `--git-dir=...` など）を読み飛ばしてからサブコマンドを取る。
#   - 短縮形と長形の両方、および `-fd` のように束ねられた短縮オプションを拾う。
#   - `--force-with-lease` は `--force` と別物として扱う（トークン完全一致で判定）。
#   - `git clean` は `-n` / `--dry-run` があれば消えないので通す。
#
# 検証は guard-destructive-git.test.sh で行う。判定対象の文字列を Bash ツールの
# コマンドに載せるとこのフック自身が弾くので、必ずテスト経由で確かめること。

set -uo pipefail

command=$(jq -r '.tool_input.command // ""')
[[ -z "$command" ]] && exit 0

# トークン列に長形オプションが完全一致で含まれるか。`--` 以降は見ない。
has_long() {
  local want="$1"; shift
  local tok
  for tok in "$@"; do
    [[ "$tok" == "--" ]] && break
    [[ "$tok" == "$want" ]] && return 0
  done
  return 1
}

# 束ねられた短縮オプション（`-fd` の f など）に指定の文字が含まれるか。大小を区別する。
has_short() {
  local letter="$1"; shift
  local tok
  for tok in "$@"; do
    [[ "$tok" == "--" ]] && break
    if [[ "$tok" == -[!-]* ]]; then
      [[ "${tok#-}" == *"$letter"* ]] && return 0
    fi
  done
  return 1
}

# 素の `--` トークンが含まれるか（git checkout -- <path> の判定用）。
has_bare_dashdash() {
  local tok
  for tok in "$@"; do
    [[ "$tok" == "--" ]] && return 0
  done
  return 1
}

# 1セグメント分のトークン列を見て、塞ぐ形なら理由を標準出力へ出して 0 を返す。
analyze() {
  local -a t=("$@")
  local n=${#t[@]} i=0

  # 先頭の環境変数代入・ラッパー・シェルキーワードを読み飛ばす。
  while (( i < n )); do
    case "${t[i]}" in
      [A-Za-z_]*=*) ((i++)) ;;
      sudo|command|env|time|nice|exec|nohup|then|do|else|'!'|'{'|'\git') ((i++)) ;;
      *) break ;;
    esac
  done

  (( i < n )) || return 1
  case "${t[i]}" in
    git|*/git) ((i++)) ;;
    *) return 1 ;;
  esac

  # サブコマンドの前に置けるグローバルオプションを読み飛ばす。
  while (( i < n )); do
    case "${t[i]}" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env|--attr-source)
        ((i += 2)) ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--super-prefix=*|--config-env=*|--attr-source=*)
        ((i++)) ;;
      -*)
        ((i++)) ;;
      *)
        break ;;
    esac
  done

  (( i < n )) || return 1
  local sub="${t[i]}"
  ((i++))
  local -a rest=()
  (( i < n )) && rest=("${t[@]:i}")

  case "$sub" in
    reset)
      if has_long "--hard" "${rest[@]}"; then
        echo "git reset --hard"; return 0
      fi
      ;;
    push)
      if has_long "--force" "${rest[@]}" || has_short f "${rest[@]}"; then
        echo "git push --force"; return 0
      fi
      ;;
    clean)
      # -n / --dry-run があれば実際には消えないので通す。
      if has_long "--dry-run" "${rest[@]}" || has_short n "${rest[@]}"; then
        return 1
      fi
      if has_long "--force" "${rest[@]}" || has_short f "${rest[@]}"; then
        echo "git clean --force"; return 0
      fi
      ;;
    branch)
      if has_short D "${rest[@]}"; then
        echo "git branch -D"; return 0
      fi
      if { has_long "--delete" "${rest[@]}" || has_short d "${rest[@]}"; } &&
         { has_long "--force"  "${rest[@]}" || has_short f "${rest[@]}"; }; then
        echo "git branch --delete --force"; return 0
      fi
      ;;
    checkout)
      if has_bare_dashdash "${rest[@]}"; then
        echo "git checkout --"; return 0
      fi
      ;;
  esac
  return 1
}

hit=""
while IFS= read -r seg; do
  [[ -z "${seg//[[:space:]]/}" ]] && continue
  read -r -a toks <<< "$seg"
  (( ${#toks[@]} )) || continue
  if reason=$(analyze "${toks[@]}"); then
    hit="$reason"
    break
  fi
# 末尾の改行は必須。無いと最後のセグメントを read が拾わず、単一コマンド
# （`git reset --hard` そのもの）が丸ごと素通りする。
done < <(printf '%s\n' "$command" | tr ';&|()\n' '\n\n\n\n\n\n')

[[ -z "$hit" ]] && exit 0

jq -nc --arg form "$hit" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("破壊的な git 操作(" + $form + ")はフックで止めています。作業結果を復元できない形で消すため、指示の有無にかかわらず実行しません。巻き戻すなら `git restore <path>`(必要なら `git reset --soft`)、ファイルを消すなら `trash-put`、ブランチを消すなら `git branch -d`(未マージなら残す判断をリーダーへ確認)、リモートを直すなら `git push --force-with-lease` ではなく追加コミットで直す方法を先に検討してください。どうしても必要ならリーダーへ理由を示して指示を仰いでください。迂回して同じ操作を別の書き方で実行しないこと。")
  }
}'
exit 0
