"""work-record-context.py の単体テスト。一時の git リポジトリで確かめ、本物のリポジトリは使わない。"""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

HOOK_PATH = Path(__file__).resolve().parent.parent / "executable_work-record-context.py"
spec = importlib.util.spec_from_file_location("work_record_context", HOOK_PATH)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

RECORD = """---
title: 状態の持ち方
status: {status}
---

## 次に Claude がすること
- PRTS を本番へ入れる

## リーダーに決めてほしいこと
{ask}
"""


def git(cwd, *args):
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@e"}
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, env=env)


def run(mode, payload):
    out = io.StringIO()
    with patch("sys.argv", ["x", mode]), patch("sys.stdin", io.StringIO(json.dumps(payload))), contextlib.redirect_stdout(out):
        mod.main()
    text = out.getvalue().strip()
    return json.loads(text)["hookSpecificOutput"]["additionalContext"] if text else ""


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        git(self.root, "init", "-q", "-b", "main")
        git(self.root, "commit", "-q", "--allow-empty", "-m", "init")
        (self.root / "docs" / "work").mkdir(parents=True)
        self.env = patch.dict(os.environ, {"TMPDIR": self.tmp.name})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def write(self, name="a.md", status="active", ask="- 公開してよいか"):
        p = self.root / "docs" / "work" / name
        p.write_text(RECORD.format(status=status, ask=ask), encoding="utf-8")
        return p


class SessionTest(Base):
    def test_lists_open_records_without_body(self):
        p = self.write()
        self.write("done.md", status="done")
        text = run("session", {"cwd": str(self.root), "source": "startup"})
        self.assertIn("状態の持ち方", text)
        self.assertIn(str(p), text)
        self.assertIn("次の一手: PRTS を本番へ入れる", text)
        self.assertIn("リーダーに決めてほしいこと 1 件", text)
        self.assertNotIn("done.md", text)
        self.assertNotIn("圧縮の前", text)

    def test_compact_asks_to_write_back(self):
        self.write()
        text = run("session", {"cwd": str(self.root), "source": "compact"})
        self.assertIn("圧縮の前に決まったこと", text)

    def test_startup_states_priority_order(self):
        self.write()
        text = run("session", {"cwd": str(self.root), "source": "startup"})
        order = ["安全と権限の決まり", "いまの会話でのリーダーの指示", "作業記録のうちリーダーが決めた有効な判断"]
        positions = [text.index(o) for o in order]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("記録の判断に従う", text)

    def transcript(self, entries):
        path = Path(self.tmp.name) / "t.jsonl"
        with path.open("w", encoding="utf-8") as f:
            for e in entries:
                f.write(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n")
        return str(path)

    @staticmethod
    def said(text, at="2026-11-20T01:00:00.000Z", **extra):
        base = {"type": "user", "timestamp": at, "message": {"role": "user", "content": text},
                "origin": {"kind": "human"}, "promptSource": "typed"}
        return {**base, **extra}

    @staticmethod
    def queued(text, kind="human", at="2026-11-20T01:00:00.000Z"):
        return {"type": "attachment", "timestamp": at,
                "attachment": {"type": "queued_command", "prompt": text, "origin": {"kind": kind}, "humanTurn": True}}

    @staticmethod
    def boundary(at="2026-11-20T01:00:00.000Z"):
        return {"type": "system", "subtype": "compact_boundary", "content": "Conversation compacted", "timestamp": at}

    def compact(self, entries, session_id="sid-1"):
        path = self.transcript(entries)
        return run("session", {"cwd": str(self.root), "source": "compact", "transcript_path": path,
                               "session_id": session_id})

    @staticmethod
    def inputs_block(text):
        return text[text.index("端末からの入力"):]

    def test_compact_quotes_inputs_after_the_previous_boundary(self):
        self.write()
        text = self.compact([
            self.said("一つ前の圧縮より前の指示"),
            self.boundary(),
            self.said("やっぱり公開はしない"),
            self.said("前のセッションからの引き継ぎ。続ける"),
            self.said("いいよ", promptSource="suggestion_accepted"),
            self.said("The plugin sent a message", origin={"kind": "plugin"}),
            self.said("<system-reminder>x</system-reminder>"),
            self.said([{"type": "text", "text": "この画像の通りに直して"}, {"type": "image", "source": {}}]),
            self.queued("待ち行列の指示"),
            self.queued("peer の連絡", kind="peer"),
            self.boundary(),
        ])
        for present in ("「やっぱり公開はしない」", "「いいよ」", "この画像の通りに直して", "「待ち行列の指示」"):
            self.assertIn(present, text)
        for absent in ("一つ前の圧縮より前の指示", "前のセッションからの引き継ぎ", "The plugin", "system-reminder", "peer の連絡"):
            self.assertNotIn(absent, text)

    def test_single_boundary_reads_from_the_start(self):
        self.write()
        text = self.compact([self.said("最初の指示"), self.boundary()])
        self.assertIn("「最初の指示」", text)

    def test_injected_inputs_are_labeled_terminal_not_leader(self):
        self.write()
        text = self.compact([self.said("公開はしない"), self.boundary()])
        block = self.inputs_block(text)
        self.assertIn("端末からの入力", block)
        self.assertIn("発言者は記録から確定できない", block)
        self.assertNotIn("リーダー", block)
        self.assertNotIn("記録の判断に従う", text)

    def test_compact_keeps_latest_eight_and_counts_the_rest(self):
        self.write()
        text = self.compact([self.said(f"指示{i}") for i in range(1, 11)] + [self.boundary()], session_id="abc-123")
        self.assertNotIn("「指示2」", text)
        self.assertIn("「指示3」", text)
        self.assertIn("「指示10」", text)
        self.assertIn("ほか 2 件", text)
        self.assertIn("prts candidates --session abc-123", text)

    def test_other_worktree_record_mtime_does_not_hide_inputs(self):
        self.write()
        wt = Path(self.tmp.name) / "wt"
        git(self.root, "worktree", "add", "-q", "-b", "feat", str(wt))
        (wt / "docs" / "work").mkdir(parents=True, exist_ok=True)
        other = wt / "docs" / "work" / "w.md"
        other.write_text(RECORD.format(status="active", ask="なし"), encoding="utf-8")
        future = time.time() + 86400
        os.utime(other, (future, future))
        text = self.compact([self.said("公開はしない", at="2026-01-01T00:00:00.000Z"), self.boundary()])
        self.assertIn("「公開はしない」", text)

    def test_record_touched_after_input_does_not_hide_it(self):
        p = self.write()
        future = time.time() + 86400
        os.utime(p, (future, future))
        text = self.compact([self.said("公開はしない", at="2026-01-01T00:00:00.000Z"), self.boundary()])
        self.assertIn("「公開はしない」", text)

    def test_reads_crlf_front_matter(self):
        p = self.root / "docs" / "work" / "crlf.md"
        p.write_bytes(RECORD.format(status="done", ask="なし").replace("\n", "\r\n").encode("utf-8"))
        self.write("open.md", status="waiting")
        text = run("session", {"cwd": str(self.root), "source": "startup"})
        self.assertNotIn("crlf.md", text)
        self.assertIn("open.md", text)
        self.assertEqual(mod.front("---\r\ntitle: 題\r\nstatus: done\r\n---\r\n本文")["status"], "done")

    def test_inputs_since_boundary_returns_omitted_count(self):
        path = self.transcript([self.said(f"指示{i}") for i in range(12)])
        got, omitted = mod.inputs_since_boundary(path)
        self.assertEqual(len(got), 8)
        self.assertEqual(omitted, 4)

    def test_startup_does_not_quote_inputs(self):
        self.write()
        path = self.transcript([self.said("あとの指示", "2099-01-01T00:00:00.000Z")])
        text = run("session", {"cwd": str(self.root), "source": "startup", "transcript_path": path})
        self.assertNotIn("あとの指示", text)

    def test_silent_without_records_or_repo(self):
        self.assertEqual(run("session", {"cwd": str(self.root), "source": "startup"}), "")
        self.assertEqual(run("session", {"cwd": self.tmp.name, "source": "startup"}), "")

    def test_none_pending(self):
        self.write(ask="- なし")
        text = run("session", {"cwd": str(self.root), "source": "startup"})
        self.assertNotIn("決めてほしいこと", text.split("\n")[1])

    def test_other_worktree_records_are_listed(self):
        wt = Path(self.tmp.name) / "wt"
        git(self.root, "worktree", "add", "-q", "-b", "feat", str(wt))
        (wt / "docs" / "work").mkdir(parents=True, exist_ok=True)
        (wt / "docs" / "work" / "w.md").write_text(RECORD.format(status="waiting", ask="なし"), encoding="utf-8")
        text = run("session", {"cwd": str(self.root), "source": "startup"})
        self.assertIn("（別のワークツリー）", text)

    def test_broken_input_is_silent(self):
        out = io.StringIO()
        with patch("sys.argv", ["x", "session"]), patch("sys.stdin", io.StringIO("not json")), contextlib.redirect_stdout(out):
            mod.main()
        self.assertEqual(out.getvalue(), "")


class PromptTest(Base):
    def commit(self, *paths, msg="work", when=None):
        env = {}
        if when is not None:
            env = {"GIT_AUTHOR_DATE": f"@{when} +0000", "GIT_COMMITTER_DATE": f"@{when} +0000"}
        with patch.dict(os.environ, env):
            git(self.root, "add", *paths)
            git(self.root, "commit", "-q", "-m", msg)

    def test_reminds_once_when_record_commit_older_than_head(self):
        self.write()
        self.commit("docs/work/a.md", when=1_800_000_000)
        (self.root / "x.txt").write_text("x")
        self.commit("x.txt", when=1_800_000_100)
        text = run("prompt", {"cwd": str(self.root)})
        self.assertIn("作業記録（状態の持ち方）", text)
        self.assertEqual(run("prompt", {"cwd": str(self.root)}), "")

    def test_quiet_when_record_committed_with_code(self):
        p = self.write()
        old = time.time() - 3600
        os.utime(p, (old, old))
        (self.root / "x.txt").write_text("x")
        self.commit("docs/work/a.md", "x.txt")
        self.assertEqual(run("prompt", {"cwd": str(self.root)}), "")

    def test_quiet_when_record_has_uncommitted_changes(self):
        p = self.write()
        self.commit("docs/work/a.md", when=1_800_000_000)
        (self.root / "x.txt").write_text("x")
        self.commit("x.txt", when=1_800_000_100)
        p.write_text(p.read_text(encoding="utf-8") + "\n- 追記\n", encoding="utf-8")
        self.assertEqual(run("prompt", {"cwd": str(self.root)}), "")

    def test_quiet_when_record_is_untracked(self):
        self.write()
        self.assertEqual(run("prompt", {"cwd": str(self.root)}), "")

    def test_waiting_record_is_not_nagged(self):
        self.write(status="waiting")
        self.commit("docs/work/a.md", when=1_800_000_000)
        (self.root / "x.txt").write_text("x")
        self.commit("x.txt", when=1_800_000_100)
        self.assertEqual(run("prompt", {"cwd": str(self.root)}), "")


if __name__ == "__main__":
    unittest.main()
