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
    def test_reminds_once_when_record_older_than_commit(self):
        p = self.write()
        old = time.time() - 3600
        os.utime(p, (old, old))
        (self.root / "x.txt").write_text("x")
        git(self.root, "add", "x.txt")
        git(self.root, "commit", "-q", "-m", "work")
        text = run("prompt", {"cwd": str(self.root)})
        self.assertIn("作業記録（状態の持ち方）が最後のコミットより古い", text)
        self.assertEqual(run("prompt", {"cwd": str(self.root)}), "")

    def test_quiet_when_record_is_fresh(self):
        self.write()
        self.assertEqual(run("prompt", {"cwd": str(self.root)}), "")

    def test_waiting_record_is_not_nagged(self):
        p = self.write(status="waiting")
        old = time.time() - 3600
        os.utime(p, (old, old))
        git(self.root, "commit", "-q", "--allow-empty", "-m", "work")
        self.assertEqual(run("prompt", {"cwd": str(self.root)}), "")


if __name__ == "__main__":
    unittest.main()
