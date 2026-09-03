import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

HOOK_PATH = Path(__file__).resolve().parent.parent / "memory_recall.py"
spec = importlib.util.spec_from_file_location("memory_recall", HOOK_PATH)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

PROJECTS_BASE = os.path.join(os.path.expanduser("~"), ".claude", "projects")


def fake_embed_factory(dim=4):
    """テキストごとに決定論的な直交風ベクトルを返す偽embed。呼び出し回数を記録する。"""
    calls = []

    def fake_embed(texts, cfg, timeout=None):
        calls.append(list(texts))
        vecs = []
        for t in texts:
            i = abs(hash(t)) % dim
            v = [0.0] * dim
            v[i] = 1.0
            vecs.append(v)
        return vecs

    fake_embed.calls = calls
    return fake_embed


class TestResolveMemoryDir(unittest.TestCase):
    def test_rejects_non_string(self):
        self.assertIsNone(mod.resolve_memory_dir(None))
        self.assertIsNone(mod.resolve_memory_dir(123))

    def test_rejects_relative_path(self):
        self.assertIsNone(mod.resolve_memory_dir("projects/x/session.jsonl"))

    def test_rejects_outside_projects_base(self):
        self.assertIsNone(mod.resolve_memory_dir("/etc/passwd"))

    def test_rejects_dotdot(self):
        p = PROJECTS_BASE + "/x/../../../etc/session.jsonl"
        self.assertIsNone(mod.resolve_memory_dir(p))

    def test_returns_none_when_memory_dir_missing(self):
        p = PROJECTS_BASE + "/no-such-project-xyz/session.jsonl"
        self.assertIsNone(mod.resolve_memory_dir(p))

    def test_resolves_existing_memory_dir(self):
        # 実在するこのプロジェクトのメモリディレクトリで検証する
        proj = PROJECTS_BASE + "/-home-yagu001-repo-github-com-haoblackj-penguinEx"
        got = mod.resolve_memory_dir(proj + "/fake-session.jsonl")
        self.assertEqual(got, proj + "/memory")


class TestPureLogic(unittest.TestCase):
    def test_normalize_unit_length(self):
        v = mod.normalize([3.0, 4.0])
        self.assertAlmostEqual(v[0], 0.6, places=6)
        self.assertAlmostEqual(v[1], 0.8, places=6)

    def test_normalize_zero_vector(self):
        self.assertEqual(mod.normalize([0.0, 0.0]), [0.0, 0.0])

    def test_read_description(self):
        text = "---\nname: x\ndescription: 身長183cmのメモ\nmetadata:\n  type: user\n---\n本文"
        self.assertEqual(mod.read_description(text), "身長183cmのメモ")

    def test_read_description_missing(self):
        self.assertEqual(mod.read_description("本文だけ"), "")

    def test_list_memory_files_excludes(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ["a.md", "MEMORY.md", ".embeddings.json", "b.txt", "c.md"]:
                Path(d, name).write_text("x")
            files = mod.list_memory_files(d)
            self.assertEqual(sorted(files), ["a.md", "c.md"])

    def test_cache_roundtrip_and_corruption(self):
        with tempfile.TemporaryDirectory() as d:
            cache, _reason, _prev = mod.load_cache(d)
            self.assertEqual(cache, {"model": mod.CACHE_MODEL, "entries": {}})
            cache["entries"]["a.md"] = {"hash": "h", "description": "d", "vector": [1.0]}
            mod.save_cache(d, cache)
            self.assertEqual(mod.load_cache(d)[0]["entries"]["a.md"]["hash"], "h")
            # 破損 → 空で再出発
            Path(d, mod.CACHE_NAME).write_text("{broken json")
            self.assertEqual(mod.load_cache(d)[0]["entries"], {})
            # モデル不一致 → 空で再出発
            Path(d, mod.CACHE_NAME).write_text(
                '{"model": "old-model", "entries": {"a.md": {}}}')
            self.assertEqual(mod.load_cache(d)[0]["entries"], {})
            # 有効なJSONだがdictでない → 空で再出発
            Path(d, mod.CACHE_NAME).write_text("[1, 2, 3]")
            self.assertEqual(mod.load_cache(d)[0]["entries"], {})
            Path(d, mod.CACHE_NAME).write_text("null")
            self.assertEqual(mod.load_cache(d)[0]["entries"], {})


class TestSecretsAndIndex(unittest.TestCase):
    def test_load_secrets(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, "tok")
            p.write_text("# comment\nCF_ACCOUNT_ID=acct123\nCF_API_TOKEN=tok456\n")
            cfg = mod.load_secrets(str(p))
            self.assertEqual(cfg["CF_ACCOUNT_ID"], "acct123")
            self.assertEqual(cfg["CF_API_TOKEN"], "tok456")

    def test_load_secrets_missing_key(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, "tok")
            p.write_text("CF_ACCOUNT_ID=only\n")
            with self.assertRaises(KeyError):
                mod.load_secrets(str(p))

    def test_update_index_embeds_new_and_skips_unchanged(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "a.md").write_text("---\ndescription: A\n---\n中身A")
            Path(d, "b.md").write_text("---\ndescription: B\n---\n中身B")
            fake = fake_embed_factory()
            with patch.object(mod, "embed_texts", fake):
                cache, _reason, _prev = mod.load_cache(d)
                done = mod.update_index(d, cache, {}, time.monotonic() + 60)
                self.assertTrue(done)
                self.assertEqual(sorted(cache["entries"]), ["a.md", "b.md"])
                self.assertEqual(len(fake.calls), 1)  # 1バッチ
                # 2回目: 変更なし → 埋め込み呼び出しゼロ
                done = mod.update_index(d, cache, {}, time.monotonic() + 60)
                self.assertTrue(done)
                self.assertEqual(len(fake.calls), 1)

    def test_update_index_prunes_deleted(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "a.md").write_text("x")
            fake = fake_embed_factory()
            with patch.object(mod, "embed_texts", fake):
                cache, _reason, _prev = mod.load_cache(d)
                mod.update_index(d, cache, {}, time.monotonic() + 60)
                Path(d, "a.md").unlink()
                mod.update_index(d, cache, {}, time.monotonic() + 60)
                self.assertEqual(cache["entries"], {})

    def test_update_index_carries_over_on_deadline(self):
        with tempfile.TemporaryDirectory() as d:
            for i in range(25):  # バッチ10件 × 3回分
                Path(d, f"f{i:02}.md").write_text(f"中身{i}")
            fake = fake_embed_factory()
            with patch.object(mod, "embed_texts", fake):
                cache, _reason, _prev = mod.load_cache(d)
                # 締切を過去にする → 1バッチも処理せず持ち越し
                done = mod.update_index(d, cache, {}, time.monotonic() - 1)
                self.assertFalse(done)
                self.assertEqual(len(cache["entries"]), 0)

    def test_update_index_saves_partial_progress_on_exception(self):
        with tempfile.TemporaryDirectory() as d:
            for i in range(15):  # バッチ10件+5件の2バッチ分
                Path(d, f"f{i:02}.md").write_text(f"中身{i}")
            calls = []

            def flaky_embed(texts, cfg, timeout=None):
                calls.append(list(texts))
                if len(calls) >= 2:
                    raise RuntimeError("network down")
                return [[1.0, 0.0] for _ in texts]

            with patch.object(mod, "embed_texts", flaky_embed):
                cache, _reason, _prev = mod.load_cache(d)
                with self.assertRaises(RuntimeError):
                    mod.update_index(d, cache, {}, time.monotonic() + 60)
            # 1バッチ目(10件)はディスクに保存されているはず
            reloaded, _reason, _prev = mod.load_cache(d)
            self.assertEqual(len(reloaded["entries"]), 10)


class TestScoringAndMain(unittest.TestCase):
    def test_top_matches_threshold_order_k(self):
        entries = {
            "hi.md": {"description": "高", "vector": [1.0, 0.0]},
            "mid.md": {"description": "中", "vector": [0.8, 0.6]},
            "low.md": {"description": "低", "vector": [0.0, 1.0]},
            "baddim.md": {"description": "次元違い", "vector": [1.0]},
        }
        got = mod.top_matches([1.0, 0.0], entries, threshold=0.5, k=2)
        self.assertEqual([g[1] for g in got], ["hi.md", "mid.md"])

    def _run_main(self, stdin_obj, env):
        old_env = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                with patch.object(sys, "stdin", io.StringIO(json.dumps(stdin_obj))):
                    mod.main()
            return out.getvalue()
        finally:
            for k, v in old_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_main_injects_on_match(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "height.md").write_text("---\ndescription: 身長183cm\n---\n本文")
            secrets = Path(d, "tok")
            secrets.write_text("CF_ACCOUNT_ID=a\nCF_API_TOKEN=t\n")

            def fake_embed(texts, cfg, timeout=None):
                return [[1.0, 0.0] for _ in texts]  # 全部同一 → 類似度1.0

            with patch.object(mod, "embed_texts", fake_embed):
                out = self._run_main(
                    {"prompt": "背が高い人向けの家具を探している"},
                    {"MEMORY_RECALL_DIR": d, "MEMORY_RECALL_SECRETS": str(secrets)},
                )
            self.assertIn("[memory-recall]", out)
            self.assertIn("height.md", out)
            self.assertIn("身長183cm", out)

    def test_main_silent_when_below_threshold(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "height.md").write_text("---\ndescription: 身長183cm\n---\n本文")
            secrets = Path(d, "tok")
            secrets.write_text("CF_ACCOUNT_ID=a\nCF_API_TOKEN=t\n")

            def fake_embed(texts, cfg, timeout=None):
                # 索引時は[1,0]、クエリ時は直交する[0,1] → 類似度0
                if any("身長" in t or "本文" in t for t in texts):
                    return [[1.0, 0.0] for _ in texts]
                return [[0.0, 1.0] for _ in texts]

            with patch.object(mod, "embed_texts", fake_embed):
                out = self._run_main(
                    {"prompt": "全く関係ない話題についての発言です"},
                    {"MEMORY_RECALL_DIR": d, "MEMORY_RECALL_SECRETS": str(secrets)},
                )
            self.assertEqual(out, "")

    def test_main_silent_on_short_prompt(self):
        out = self._run_main({"prompt": "OK!"}, {"MEMORY_RECALL_DIR": "/nonexistent"})
        self.assertEqual(out, "")

    def test_main_silent_on_api_failure(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "a.md").write_text("x")
            secrets = Path(d, "tok")
            secrets.write_text("CF_ACCOUNT_ID=a\nCF_API_TOKEN=t\n")

            def broken_embed(texts, cfg, timeout=None):
                raise RuntimeError("boom")

            # log を差し替えずに走らせると本番の ~/.claude/logs/memory-recall.log へ
            # RuntimeError: boom が追記される。実際に混入事故を起こしたので差し替える。
            logged = []
            with patch.object(mod, "log", logged.append):
                with patch.object(mod, "embed_texts", broken_embed):
                    out = self._run_main(
                        {"prompt": "これは十分な長さのある発言です"},
                        {"MEMORY_RECALL_DIR": d, "MEMORY_RECALL_SECRETS": str(secrets)},
                    )
            self.assertEqual(out, "")
            self.assertTrue(any("boom" in (m.get("message") or "") for m in logged))

    def test_main_logs_bad_stdin(self):
        logged = []
        with patch.object(mod, "log", logged.append):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                with patch.object(sys, "stdin", io.StringIO("not json at all")):
                    mod.main()
        self.assertEqual(out.getvalue(), "")
        self.assertTrue(any("bad stdin payload" in (m.get("message") or "") for m in logged))


class TestLogging(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.log_path = os.path.join(self.tmp.name, "memory-recall.log")
        self.patches = [
            patch.object(mod, "LOG_PATH", self.log_path),
            patch.object(mod, "LOCK_PATH", self.log_path + ".lock"),
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def read_lines(self):
        with open(self.log_path) as f:
            return [json.loads(line) for line in f if line.strip()]

    def test_writes_json_line_with_offset_timestamp(self):
        mod.log({"stage": "index", "kind": "document", "target": "a.md"})
        rows = self.read_lines()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["kind"], "document")
        self.assertEqual(rows[0]["target"], "a.md")
        # ts はオフセット付き（末尾が +0900 のような形）
        self.assertRegex(rows[0]["ts"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4}$")

    def test_appends_without_truncating(self):
        mod.log({"kind": "api", "message": "one"})
        mod.log({"kind": "api", "message": "two"})
        self.assertEqual([r["message"] for r in self.read_lines()], ["one", "two"])

    def test_rotates_into_generations_and_drops_oldest(self):
        with patch.object(mod, "LOG_MAX_BYTES", 50):
            for i in range(6):
                mod.log({"kind": "api", "message": f"m{i}" * 20})
        self.assertTrue(os.path.exists(self.log_path + ".1"))
        self.assertTrue(os.path.exists(self.log_path + ".3"))
        self.assertFalse(os.path.exists(self.log_path + ".4"))

    def test_log_generations_newest_first(self):
        mod.log({"kind": "api", "message": "x"})
        open(self.log_path + ".1", "w").close()
        open(self.log_path + ".2", "w").close()
        self.assertEqual(
            mod.log_generations(),
            [self.log_path, self.log_path + ".1", self.log_path + ".2"],
        )

    def test_skips_rotation_when_lock_is_held(self):
        # 先に上限を超えるログを作らないと、rotate_log_if_needed が
        # getsize の判定で return してロックの分岐を一度も通らない。
        # 詰め物も JSON にしておく（read_lines が全行を解析するため）。
        mod.log({"kind": "api", "message": "filler"})
        open(self.log_path + ".lock", "w").close()
        with patch.object(mod, "LOG_MAX_BYTES", 10):
            mod.log({"kind": "api", "message": "held"})
        # ロックが取れないので退避せず、追記だけ行う
        self.assertFalse(os.path.exists(self.log_path + ".1"))
        self.assertEqual([r["message"] for r in self.read_lines()],
                         ["filler", "held"])

    def test_steals_stale_lock(self):
        mod.log({"kind": "api", "message": "filler"})
        lock = self.log_path + ".lock"
        open(lock, "w").close()
        os.utime(lock, (time.time() - 999, time.time() - 999))
        with patch.object(mod, "LOG_MAX_BYTES", 10):
            mod.log({"kind": "api", "message": "steal"})
        self.assertTrue(os.path.exists(self.log_path + ".1"))
        self.assertFalse(os.path.exists(lock))  # 使い終わったロックは消えている


class TestLoadCacheReason(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, obj):
        with open(os.path.join(self.dir, mod.CACHE_NAME), "w") as f:
            json.dump(obj, f)

    def test_absent(self):
        cache, reason, prev = mod.load_cache(self.dir)
        self.assertEqual(reason, "absent")
        self.assertIsNone(prev)
        self.assertEqual(cache, {"model": mod.CACHE_MODEL, "entries": {}})

    def test_unreadable_when_broken_json(self):
        with open(os.path.join(self.dir, mod.CACHE_NAME), "w") as f:
            f.write("{ this is not json")
        _, reason, prev = mod.load_cache(self.dir)
        self.assertEqual(reason, "unreadable")
        self.assertIsNone(prev)

    def test_unreadable_when_shape_is_wrong(self):
        self.write({"model": mod.CACHE_MODEL, "entries": "not a dict"})
        _, reason, _ = mod.load_cache(self.dir)
        self.assertEqual(reason, "unreadable")

    def test_model_mismatch_reports_previous(self):
        # 印を付ける前でも後でも不一致になる値を使う。
        # 実在のモデル名を書くと、このタスクの CACHE_MODEL と一致して "ok" になる。
        self.write({"model": "old-model", "entries": {}})
        _, reason, prev = mod.load_cache(self.dir)
        self.assertEqual(reason, "model_mismatch")
        self.assertEqual(prev, "old-model")

    def test_ok(self):
        self.write({"model": mod.CACHE_MODEL, "entries": {"a.md": {"hash": "h"}}})
        cache, reason, prev = mod.load_cache(self.dir)
        self.assertEqual(reason, "ok")
        self.assertIsNone(prev)
        self.assertIn("a.md", cache["entries"])

    def test_does_not_write(self):
        path = os.path.join(self.dir, mod.CACHE_NAME)
        self.write({"model": "old", "entries": {}})
        before = open(path).read()
        mod.load_cache(self.dir)
        self.assertEqual(open(path).read(), before)

    def test_url_value_and_cache_value_are_separate_constants(self):
        # URL の組み立てに使う値へ印が混ざらないこと。印の付与はタスク7。
        self.assertNotIn("#", mod.MODEL)
        self.assertTrue(mod.CACHE_MODEL.startswith(mod.MODEL))


class FakeHTTPError(Exception):
    """urllib.error.HTTPError の read() と code だけを真似る。"""
    def __init__(self, code, body):
        self.code = code
        self._body = body.encode()
    def read(self):
        return self._body


class TestClassify(unittest.TestCase):
    def classify(self, code, body):
        return mod.classify_http_error(FakeHTTPError(code, body))

    def test_auth(self):
        kind, detail = self.classify(
            401, '{"result":null,"success":false,'
                 '"errors":[{"code":10000,"message":"Authentication error"}]}')
        self.assertEqual(kind, "auth")
        self.assertEqual(detail["code"], 10000)

    def test_document_with_measured_tokens(self):
        kind, detail = self.classify(
            400, '{"errors":[{"message":"AiError: AiError: Sequence too long: '
                 '9003 > 8192 (f660721d)","code":3030}],"success":false}')
        self.assertEqual(kind, "document")
        self.assertEqual(detail["tokens"], 9003)
        self.assertEqual(detail["limit"], 8192)

    def test_batch_with_measured_tokens(self):
        kind, detail = self.classify(
            400, '{"errors":[{"message":"AiError: AiError: Max context reached '
                 '80030 tokens but model supports only 60000 (173b31cf)",'
                 '"code":3030}],"success":false}')
        self.assertEqual(kind, "batch")
        self.assertEqual(detail["tokens"], 80030)
        self.assertEqual(detail["limit"], 60000)

    def test_unclassified_400_falls_back_to_api_and_keeps_body(self):
        kind, detail = self.classify(
            400, '{"errors":[{"code":7000,"message":"No route for that URI"}]}')
        self.assertEqual(kind, "api")
        self.assertIn("No route", detail["message"])

    def test_unknown_status_falls_back_to_api(self):
        kind, _ = self.classify(418, "not json at all")
        self.assertEqual(kind, "api")

    def test_server_error_is_api(self):
        kind, _ = self.classify(503, '{"errors":[{"message":"upstream"}]}')
        self.assertEqual(kind, "api")


if __name__ == "__main__":
    unittest.main(verbosity=2)
