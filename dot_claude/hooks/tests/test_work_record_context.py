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

    def test_current_instruction_outranks_record(self):
        self.write()
        text = run("session", {"cwd": str(self.root), "source": "startup"})
        self.assertIn("この会話でのリーダーの指示が記録と食い違えば、リーダーの指示に従い", text)
        self.assertNotIn("記録の新しい判断に従う", text)

    def transcript(self, entries):
        path = Path(self.tmp.name) / "t.jsonl"
        with path.open("w", encoding="utf-8") as f:
            for e in entries:
                f.write(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n")
        return str(path)

    @staticmethod
    def said(text, at, **extra):
        base = {"type": "user", "timestamp": at, "message": {"role": "user", "content": text},
                "origin": {"kind": "human"}, "promptSource": "typed"}
        return {**base, **extra}

    def test_compact_quotes_inputs_after_the_record(self):
        p = self.write()
        mtime = 1_800_000_000
        os.utime(p, (mtime, mtime))
        iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))  # noqa: E731
        path = self.transcript([
            self.said("記録より前の指示", iso(mtime - 60)),
            self.said("やっぱり公開はしない", iso(mtime + 60)),
            self.said("前のセッションからの引き継ぎ。続ける", iso(mtime + 70)),
            self.said("候補の文", iso(mtime + 80), promptSource="suggestion_accepted"),
            self.said("The plugin sent a message", iso(mtime + 90), origin={"kind": "plugin"}),
            self.said("x" * 500, iso(mtime + 100)),
        ])
        text = run("session", {"cwd": str(self.root), "source": "compact", "transcript_path": path})
        self.assertIn("「やっぱり公開はしない」", text)
        self.assertIn("…（以下略）", text)
        for absent in ("記録より前の指示", "前のセッションからの引き継ぎ", "候補の文", "The plugin"):
            self.assertNotIn(absent, text)

    def test_compact_keeps_only_the_latest_inputs(self):
        p = self.write()
        os.utime(p, (1_800_000_000, 1_800_000_000))
        iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))  # noqa: E731
        path = self.transcript([self.said(f"指示{i}", iso(1_800_000_000 + i)) for i in range(1, 10)])
        text = run("session", {"cwd": str(self.root), "source": "compact", "transcript_path": path})
        self.assertNotIn("「指示3」", text)
        self.assertIn("「指示4」", text)
        self.assertIn("「指示9」", text)

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
