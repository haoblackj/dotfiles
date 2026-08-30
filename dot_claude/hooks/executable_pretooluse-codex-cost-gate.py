#!/usr/bin/env python3
"""codex を実際に起動する Bash 呼び出しに、確認の関門を置く PreToolUse フック。

置いた理由。サブエージェントが「前景経路が素通しすることを確かめる」つもりで
`codex-task.sh adversarial-review` を実物へ投げ、有料のジョブが起動した
(Maylander、2026-08-30)。指示で「実物を叩くな」と書いても、検証のために叩くのは
自然な発想なので、規律ではなく仕組みで止める。

判定の方針。

  金を使うのは task / review / adversarial-review の三つだけ。status / result /
  cancel はジョブ記録を読む・止めるだけで codex を起動しないので通す。内省の口
  (--print-companion / --print-flags) も通す。

  金を使う三つは、コマンドに CODEX_DELEGATION_OK=1 が付いていれば通し、無ければ
  確認を出す (deny ではなく ask)。deny にするとリーダー自身の /codex:review が
  止まる。あれはプラグインが codex-companion.mjs を直に叩く経路で、フックからは
  サブエージェントの誤爆と区別が付かない。

  解釈できなかった場合は確認を出す (fail-closed)。黙って通すと、綴りが想定から
  外れた回に関門が無いのと同じになる。

入出力は PreToolUse の契約に従う。stdin に JSON、`.tool_input.command` に
コマンド文字列。確認を出すときは permissionDecision を stdout へ出して 0 で終わる。
"""
import json
import re
import shlex
import sys

# 実体と、リポジトリ側のラッパー。どちらの綴りでも捕まえる。
ENTRY = re.compile(r"(codex-companion\.mjs|codex-task\.sh)")
# codex を起動する = 金を使うサブコマンド。
COSTS_MONEY = {"task", "review", "adversarial-review"}
# ラッパーの内省の口。サブコマンドではないので、これが先頭なら見るまでもなく通す。
INTROSPECTION = {"--print-companion", "--print-flags"}
MARKER = "CODEX_DELEGATION_OK=1"


def allow():
    sys.exit(0)


def ask(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))
    sys.exit(0)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        # フックの入力が読めないのは、この関門が対象を判定できないということ。
        # ただしすべての Bash 呼び出しへ確認を出すと作業が止まるので、ここは通す。
        allow()

    if payload.get("tool_name") != "Bash":
        allow()
    command = (payload.get("tool_input") or {}).get("command") or ""
    if not ENTRY.search(command):
        allow()

    # 実体かラッパーを指すトークンの直後から、サブコマンドを探す。
    # shlex が壊れる (引用の対応が取れない等) 場合は素朴な分割へ落とす。
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()

    sub = None
    for i, tok in enumerate(tokens):
        if not ENTRY.search(tok):
            continue
        rest = tokens[i + 1:]
        if rest and rest[0] in INTROSPECTION:
            allow()
        for candidate in rest:
            if not candidate.startswith("-"):
                sub = candidate
                break
        break

    if sub is None:
        # 実体を指しているのにサブコマンドが読めない。想定外の綴りなので確認を出す。
        ask("codex の呼び出しに見えるが、サブコマンドを読み取れなかった。"
            "実行すると有料のジョブが起動する可能性がある。")
    if sub not in COSTS_MONEY:
        allow()
    if MARKER in command:
        allow()

    ask(f"`{sub}` は codex を実際に起動し、リーダーの枠を消費する。"
        f"委譲として意図した実行なら、コマンドの先頭へ {MARKER} を付けて叩き直すこと。"
        f"検証や動作確認が目的なら、実物ではなく偽の companion を "
        f"CODEX_COMPANION で差して行うこと。")


if __name__ == "__main__":
    main()
