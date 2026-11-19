#!/usr/bin/env python3
"""作業記録（リポジトリの docs/work/*.md）を、要る場面で Claude に読み戻させるフック。

session（SessionStart の startup、resume、clear、compact）:
  セッションの cwd のリポジトリ（ワークツリーを含む）の、開いている作業記録の一覧を差し込む。
  本文は差し込まず、題、状態、次の一手の 1 行、リーダーに決めてほしいことの件数、場所だけを出す。
  毎回の会話の頭と圧縮の後に一覧が入り、本文は Claude が要るときに Read で読む（トークンを抑える）。
  圧縮の後には、一つ前の圧縮の境目（無ければ会話の始め）より後の、端末からの入力を原文で添える。
  要約に溶けた新しい指示を、古い記録が覆さないようにするため（優先の順はグローバルの CLAUDE.md の「作業記録」）。
  基準を記録の mtime にしないのは、mtime が判断を書いた時刻でなく（別のワークツリーの記録、git switch、
  「済んだこと」だけの直しでも進む）、指示が一件も添えられなくなることがあるため。
  端末からの入力はリーダーの入力として扱う（Claude の連絡は SendMessage と引き継ぎの定型文で届くため。
  設計書 docs/superpowers/specs/2026-11-20-practical-trust-design.md の 3 節）。「リーダーが打った」とは書かない。
  作業の途中で打った入力が queued_command の添付と promptSource が queued の user の行の両方に残ることがあり、一つにする。
prompt（UserPromptSubmit）:
  今の作業コピーの開いている記録の最後のコミットが HEAD のコミットより古く、記録に未コミットの変更が
  無いときだけ、一度だけ一行で知らせる。記録を直さずに作業が進んだ合図で、同じ（コミット、記録）の組では二度出さない。
  mtime で比べないのは、記録を直してから時間をおいてコードと一緒にコミットした場合や amend、rebase でも出るため。

どの場合も、作業中のセッションを止めない。失敗したら何も出さずに 0 で終わる。
"""

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

MAX_LIST = 8
OPEN_STATES = {"active", "waiting", ""}


def git(cwd: str, *args: str) -> str | None:
    try:
        done = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=3, check=True)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip()


def front(text: str) -> dict:
    text = text.replace("\r\n", "\n")
    m = re.match(r"\A---\n(.*?)\n---\n", text, re.S)
    out = {}
    if m:
        for line in m.group(1).splitlines():
            k, sep, v = line.partition(":")
            if sep and not line.startswith((" ", "#")):
                out[k.strip()] = v.split(" #", 1)[0].strip()
    return out


def section(text: str, name: str) -> str:
    m = re.search(rf"^## {re.escape(name)}\s*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return m.group(1).strip() if m else ""


def pending(text: str) -> int:
    body = section(text, "リーダーに決めてほしいこと")
    plain = re.sub(r"^\s*[-*]\s*", "", body, flags=re.M).strip()
    if not plain or plain in {"なし", "無し", "ない", "無い"}:
        return 0
    return len(re.findall(r"^[-*]\s+\S", body, re.M)) or 1


def first_line(body: str) -> str:
    for line in body.splitlines():
        line = re.sub(r"^\s*[-*]\s*", "", line).strip()
        if line:
            return line[:120]
    return ""


def records(root: str) -> list[dict]:
    out = []
    for p in sorted(Path(root, "docs", "work").glob("*.md")):
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        fm = front(text)
        # docs/work/ には作業記録でない文書（README など）も置かれうる。前書きの無い物は記録として扱わない。
        if "title" not in fm and "status" not in fm:
            continue
        if fm.get("status", "") not in OPEN_STATES:
            continue
        out.append(
            {
                "path": str(p),
                "title": fm.get("title") or p.stem,
                "status": fm.get("status") or "active",
                "next": first_line(section(text, "次に Claude がすること")),
                "pending": pending(text),
                "mtime": p.stat().st_mtime,
            }
        )
    return out


def checkouts(cwd: str) -> list[str]:
    """cwd のリポジトリの作業コピー。今のものを先に、ほかのワークツリーを後に。"""
    top = git(cwd, "rev-parse", "--show-toplevel")
    if not top:
        return []
    out = [top]
    listing = git(cwd, "worktree", "list", "--porcelain") or ""
    for line in listing.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree ") :]
            if path != top and Path(path).is_dir():
                out.append(path)
    return out


def emit(event: str, text: str) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}, ensure_ascii=False))


def session(payload: dict) -> None:
    cwd = payload.get("cwd") or os.getcwd()
    found = []
    for i, root in enumerate(checkouts(cwd)):
        for r in records(root):
            r["here"] = i == 0
            found.append(r)
    if not found:
        return
    found.sort(key=lambda r: (not r["here"], -r["mtime"]))
    lines = ["このリポジトリの開いている作業記録（判断と進行状態の正本。書き方はスキル work-record）:"]
    for r in found[:MAX_LIST]:
        when = time.strftime("%m/%d %H:%M", time.localtime(r["mtime"]))
        where = "" if r["here"] else "（別のワークツリー）"
        ask = f"、リーダーに決めてほしいこと {r['pending']} 件" if r["pending"] else ""
        lines.append(f"- {r['title']}［{r['status']}、{when} 更新{ask}］{where} {r['path']}")
        if r["next"]:
            lines.append(f"  次の一手: {r['next']}")
    if len(found) > MAX_LIST:
        lines.append(f"- ほか {len(found) - MAX_LIST} 件")
    lines.append(
        "この会話の作業に当たる記録があれば、作業の前に Read で全部読む（この会話の依頼が別にあれば、依頼を先にする）。"
        "食い違ったときの優先の順は、安全と権限の決まり、いまの会話でのリーダーの指示、"
        "作業記録の有効な判断（出どころが端末からの入力か PRTS の指摘の物。リーダーの判断として扱う）、CLAUDE.md の一般の決まり、作業記録のうち Claude の技術の判断、そのほか（memory、issue、圧縮の要約）"
        "（グローバルの CLAUDE.md の「作業記録」）。記録はいまの指示を覆す根拠にせず、食い違えば指示に従い、記録に変更として書く。"
    )
    if payload.get("source") == "compact":
        lines.append(
            "圧縮の前に決まったことや分かったことが記録に無ければ、いま記録に書いてコミットする。"
            "圧縮の要約と記録が食い違えば、下の入力か会話の記録の原文で確かめる。"
        )
        recent, omitted = inputs_since_boundary(payload.get("transcript_path"))
        if recent:
            sid = payload.get("session_id") or "<session_id>"
            lines.append(
                "一つ前の圧縮の境目（無ければ会話の始め）より後の、端末からの入力（リーダーの入力として扱う。会話の記録から原文で、古い順）。"
                "いまの会話の指示として、作業記録より先に読む。記録には原文を写さず、要旨と出典（prts quote で確かめる）を書く:"
            )
            if omitted:
                lines.append(f"- ほか {omitted} 件（古いほう）")
            for at, text in recent:
                lines.append(f"- {at} 「{text}」")
            if omitted or any(text.endswith(TRUNCATED) for _, text in recent):
                lines.append(f"省いた入力と全文は prts candidates --session {sid} で読む。")
    emit("SessionStart", "\n".join(lines))


# 人の入力でない、Claude Code が user の役で差し込む文と、引き継ぎやセッションどうしの知らせの書き出し
MACHINE_PREFIXES = (
    "<command-", "<system-reminder>", "<task-notification>", "<local-command-", "<bash-", "<agent-message",
    "前のセッションからの引き継ぎ", "別のセッション（",
)
MAX_INPUTS = 8
MAX_INPUT_CHARS = 400
TRUNCATED = "…（以下略）"
HUMAN_SOURCES = ("typed", "queued", "suggestion_accepted")


def user_text(content) -> str:
    """user の content（文字列、または文や画像の塊の並び）から文を取り出す。画像は印に置き換える。"""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
            parts.append(block["text"])
        elif isinstance(block, dict) and block.get("type") == "image":
            parts.append("［画像］")
    return " ".join(parts)


def terminal_input(o: dict) -> tuple[str, str] | None:
    """会話の記録の一行が端末からの入力なら（時刻に出どころの注記を添えた文字列、原文）を、違えば None を返す。"""
    if o.get("isMeta") or o.get("isSidechain") or o.get("isCompactSummary"):
        return None
    if o.get("type") == "attachment":
        att = o.get("attachment") or {}
        origin = att.get("origin")
        if att.get("type") != "queued_command" or not isinstance(origin, dict) or origin.get("kind") != "human":
            return None
        text, note = user_text(att.get("prompt")), ""
    elif o.get("type") == "user":
        origin = o.get("origin")
        if not isinstance(origin, dict) or origin.get("kind") != "human":
            return None
        source = o.get("promptSource")
        if source not in HUMAN_SOURCES:
            return None
        text = user_text((o.get("message") or {}).get("content"))
        note = "（Claude の出した候補を選んだ入力）" if source == "suggestion_accepted" else ""
    else:
        return None
    if not text.strip() or text.lstrip().startswith(MACHINE_PREFIXES):
        return None
    at = o.get("timestamp", "")
    try:
        local = time.strftime("%m/%d %H:%M", time.localtime(datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()))
    except (AttributeError, ValueError):
        local = "時刻不明"
    body = text.strip()
    if len(body) > MAX_INPUT_CHARS:
        body = body[:MAX_INPUT_CHARS] + TRUNCATED
    return (local + note, body)


def inputs_since_boundary(transcript_path) -> tuple[list[tuple[str, str]], int]:
    """会話の記録から、二つ目に新しい compact_boundary（一つ以下なら会話の始め）より後の端末からの入力を古い順に返す。
    SessionStart の compact の時点で一番新しい境目はいま済んだ圧縮のもので、その前の区間が要約に溶けた所に当たる。
    いま済んだ圧縮の境目がまだ書かれていなくても、一つ前の区間まで含むだけで、入力を落とす側には倒れない。
    多ければ新しいほうから MAX_INPUTS 件と、省いた件数を返す。"""
    if not transcript_path:
        return [], 0
    spans: list[list[tuple[str, str]]] = [[]]
    # 途中で打った入力は、queued_command の添付と、promptSource が queued の user の行の両方に続けて残ることがある。
    # 組にするのは直前に集めた入力だけにする。離れた同じ文（「続けて」の打ち直しなど）を消さないため
    last: tuple[str, str] | None = None
    try:
        with open(transcript_path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                if "compact_boundary" in raw or '"user"' in raw or "queued_command" in raw:
                    try:
                        o = json.loads(raw)
                    except ValueError:
                        continue
                    if not isinstance(o, dict):
                        continue
                    if o.get("type") == "system" and o.get("subtype") == "compact_boundary":
                        spans.append([])
                        last = None
                        continue
                    got = terminal_input(o)
                    if not got:
                        continue
                    side = "attachment" if o.get("type") == "attachment" else o.get("promptSource")
                    other = {"attachment": "queued", "queued": "attachment"}.get(side)
                    if other and last == (other, got[1]):
                        last = None
                        continue
                    last = (side, got[1])
                    spans[-1].append(got)
    except OSError:
        return [], 0
    out = [x for span in spans[-2:] for x in span] if len(spans) >= 3 else [x for span in spans for x in span]
    return out[-MAX_INPUTS:], max(0, len(out) - MAX_INPUTS)


def state_file() -> Path:
    base = Path(os.environ.get("TMPDIR") or Path.home() / ".cache")
    return base / "work-record-reminded.json"


def prompt(payload: dict) -> None:
    cwd = payload.get("cwd") or os.getcwd()
    tops = checkouts(cwd)
    if not tops:
        return
    top = tops[0]
    head = git(top, "log", "-1", "--format=%H %ct")
    if not head:
        return
    sha, ct = head.split()
    stale = []
    for r in records(top):
        if r["status"] != "active":
            continue
        rel = os.path.relpath(r["path"], top)
        if git(top, "status", "--porcelain", "--", rel):
            continue
        last = git(top, "log", "-1", "--format=%ct", "--", rel)
        if last and int(last) < int(ct):
            stale.append(r)
    if not stale:
        return
    key = f"{sha}:" + ",".join(r["path"] for r in stale)
    sf = state_file()
    try:
        seen = json.loads(sf.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        seen = {}
    if seen.get(top) == key:
        return
    seen[top] = key
    try:
        sf.parent.mkdir(parents=True, exist_ok=True)
        sf.write_text(json.dumps(seen), encoding="utf-8")
    except OSError:
        pass
    names = "、".join(r["title"] for r in stale)
    emit(
        "UserPromptSubmit",
        f"作業記録（{names}）の最後のコミットが HEAD より古い。この依頼の区切りで、記録を今に合わせてコミットする。",
    )


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        if not isinstance(payload, dict):
            return
        if mode == "session":
            session(payload)
        elif mode == "prompt":
            prompt(payload)
    except Exception:  # noqa: BLE001 - フックの失敗で作業を止めない
        pass


if __name__ == "__main__":
    main()
