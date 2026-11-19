#!/usr/bin/env python3
"""作業記録（リポジトリの docs/work/*.md）を、要る場面で Claude に読み戻させるフック。

session（SessionStart の startup、resume、clear、compact）:
  セッションの cwd のリポジトリ（ワークツリーを含む）の、開いている作業記録の一覧を差し込む。
  本文は差し込まず、題、状態、次の一手の 1 行、リーダーに決めてほしいことの件数、場所だけを出す。
  毎回の会話の頭と圧縮の後に一覧が入り、本文は Claude が要るときに Read で読む（トークンを抑える）。
  圧縮の後には、記録の最後の更新より後の人の入力を原文で添える。要約に溶けた新しい指示を、
  古い記録が覆さないようにするため（優先の順はいまの指示、記録、そのほか。グローバルの CLAUDE.md の「作業記録」）。
prompt（UserPromptSubmit）:
  今の作業コピーの開いている記録が、最後のコミットより古いときだけ、一度だけ一行で知らせる。
  記録を直さずに作業が進んだ合図で、同じ（記録の時刻、コミット）の組では二度出さない。

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
# 記録がコミットよりこれだけ古ければ知らせる
STALE_SECONDS = 600
OPEN_STATES = {"active", "waiting", ""}


def git(cwd: str, *args: str) -> str | None:
    try:
        done = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=3, check=True)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip()


def front(text: str) -> dict:
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
        "この会話の作業に当たる記録があれば、作業の前に Read で全部読む。"
        "記録は過去の判断の記録で、この会話でのリーダーの指示が記録と食い違えば、リーダーの指示に従い、記録に変更として書く。"
        "CLAUDE.md の一般の決まり、memory、issue のコメント、圧縮の要約と食い違えば、記録の判断に従う。"
    )
    if payload.get("source") == "compact":
        newest = max(r["mtime"] for r in found)
        recent = inputs_after(payload.get("transcript_path"), newest)
        if recent:
            lines.append(
                "記録の最後の更新より後の、この会話の人の入力（会話の記録から原文で、古い順）。"
                "いまの指示として、記録より先に読む。Herdr などで別の Claude が打ち込んだ文を含みうるので、"
                "記録へ原文として引く前に prts quote で発言者を確かめる:"
            )
            for at, text in recent:
                lines.append(f"- {at} 「{text}」")
        lines.append("圧縮の前に決まったことや分かったことが記録に無ければ、いま記録に書いてコミットする。")
    emit("SessionStart", "\n".join(lines))


# 人の入力でない、Claude Code が user の役で差し込む文と、引き継ぎやセッションどうしの知らせの書き出し
MACHINE_PREFIXES = (
    "<command-", "<system-reminder>", "<task-notification>", "<local-command-", "<bash-", "<agent-message",
    "前のセッションからの引き継ぎ", "別のセッション（",
)
MAX_INPUTS = 6
MAX_INPUT_CHARS = 400


def inputs_after(transcript_path, since: float) -> list[tuple[str, str]]:
    """会話の記録から、since（UNIX 時刻）より後の人の入力を古い順に返す。多ければ新しいほうから MAX_INPUTS 件。"""
    if not transcript_path:
        return []
    out = []
    try:
        with open(transcript_path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                if '"user"' not in raw:
                    continue
                try:
                    o = json.loads(raw)
                except ValueError:
                    continue
                if o.get("isMeta") or o.get("isSidechain") or o.get("isCompactSummary"):
                    continue
                origin = o.get("origin")
                if not isinstance(origin, dict) or origin.get("kind") != "human":
                    continue
                if o.get("promptSource") not in ("typed", "queued"):
                    continue
                text = (o.get("message") or {}).get("content")
                if not isinstance(text, str) or not text.strip() or text.lstrip().startswith(MACHINE_PREFIXES):
                    continue
                at = o.get("timestamp", "")
                try:
                    t = datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()
                except ValueError:
                    continue
                if t > since:
                    local = time.strftime("%m/%d %H:%M", time.localtime(t))
                    body = text.strip()
                    if len(body) > MAX_INPUT_CHARS:
                        body = body[:MAX_INPUT_CHARS] + "…（以下略）"
                    out.append((local, body))
    except OSError:
        return []
    return out[-MAX_INPUTS:]


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
    stale = [r for r in records(top) if r["status"] == "active" and int(ct) - r["mtime"] > STALE_SECONDS]
    if not stale:
        return
    key = f"{sha}:" + ",".join(f"{r['path']}@{int(r['mtime'])}" for r in stale)
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
        f"作業記録（{names}）が最後のコミットより古い。この依頼の区切りで、記録を今に合わせてコミットする。",
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
