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


def const_embed(vec=(1.0, 0.0, 0.0, 0.0)):
    """常に同じベクトルを返す偽 embed。文書も発言も同じ向きになり類似度が1.0になる。"""
    def fake(texts, cfg, timeout=None):
        return [list(vec) for _ in texts]
    return fake


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
    def setUp(self):
        # update_index は自分で log() を呼ぶ。差し替えないと本番のログへ書き込む。
        self.tmp = tempfile.TemporaryDirectory()
        self.log_path = os.path.join(self.tmp.name, "log")
        self.p = [patch.object(mod, "LOG_PATH", self.log_path),
                  patch.object(mod, "LOCK_PATH", self.log_path + ".lock")]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in self.p:
            p.stop()
        self.tmp.cleanup()

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

    def test_update_index_keeps_successful_files_when_a_batch_fails(self):
        """束が1つ落ちても、他の束で成功したファイルはディスクに残る。"""
        with tempfile.TemporaryDirectory() as d:
            for i in range(4):
                with open(os.path.join(d, f"f{i}.md"), "w") as f:
                    f.write(f"内容{i}")
            def fails_on_f2(texts, cfg, timeout=None):
                if any("内容2" in t for t in texts):
                    raise mod.EmbedError("api", {"message": "boom"})
                return fake_embed_factory()(texts, cfg, timeout)
            cache = {"model": mod.CACHE_MODEL, "entries": {}}
            with patch.object(mod, "BATCH_SIZE", 1), \
                 patch.object(mod, "embed_texts", fails_on_f2):
                mod.update_index(d, cache, {}, time.monotonic() + 10)
            with open(os.path.join(d, mod.CACHE_NAME)) as f:
                saved = json.load(f)
            self.assertEqual(set(saved["entries"]), {"f0.md", "f1.md", "f3.md"})


class TestScoringAndMain(unittest.TestCase):
    def setUp(self):
        # main() は update_index 経由で自分の log() を呼ぶ。差し替えないと
        # 遅いマシンで締め切りを越えたとき本番の ~/.claude/logs/memory-recall.log へ
        # partial レコードが書き込まれる（過去に実際に汚染した事故がある）。
        self.tmp = tempfile.TemporaryDirectory()
        self.log_path = os.path.join(self.tmp.name, "log")
        self.p = [patch.object(mod, "LOG_PATH", self.log_path),
                  patch.object(mod, "LOCK_PATH", self.log_path + ".lock")]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in self.p:
            p.stop()
        self.tmp.cleanup()

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
                env = {"MEMORY_RECALL_DIR": d, "MEMORY_RECALL_SECRETS": str(secrets)}
                # 1回目: 想起は空だが索引が作られる
                self._run_main({"prompt": "背が高い人向けの家具を探している"}, env)
                # 2回目: 前回作った索引に対して想起する
                out = self._run_main(
                    {"prompt": "背が高い人向けの家具を探している"}, env)
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
        self.assertIn("#", mod.CACHE_MODEL)


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


class TestMainOrder(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        with open(os.path.join(self.dir, "a.md"), "w") as f:
            f.write("---\ndescription: あるメモ\n---\n本文")
        self.log_path = os.path.join(self.dir, "log")
        self.p = [patch.object(mod, "LOG_PATH", self.log_path),
                  patch.object(mod, "LOCK_PATH", self.log_path + ".lock")]
        for p in self.p:
            p.start()
        self.env = patch.dict(os.environ, {"MEMORY_RECALL_DIR": self.dir})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        for p in self.p:
            p.stop()
        self.tmp.cleanup()

    def rows(self):
        if not os.path.exists(self.log_path):
            return []
        with open(self.log_path) as f:
            return [json.loads(x) for x in f if x.strip()]

    def run_main(self, prompt="メモの想起がちゃんと動くかを確かめたい"):  # 19文字
        buf = io.StringIO()
        with patch.object(sys, "stdin", io.StringIO(json.dumps({"prompt": prompt}))), \
             contextlib.redirect_stdout(buf), \
             patch.object(mod, "load_secrets", lambda *a, **k: {
                 "CF_ACCOUNT_ID": "x", "CF_API_TOKEN": "y"}):
            mod.main()
        return buf.getvalue()

    def test_recall_returns_even_if_index_update_raises(self):
        """索引の更新が例外を投げても想起は返る。issue #11 の本体。"""
        fake = const_embed()
        # 先に索引を作っておく
        with patch.object(mod, "embed_texts", fake):
            self.run_main()
        with patch.object(mod, "embed_texts", fake), \
             patch.object(mod, "update_index",
                          lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))):
            out = self.run_main("あるメモについて詳しく教えてほしい")  # 17文字
        self.assertIn("[memory-recall]", out)

    def test_query_failure_skips_index_update(self):
        called = []
        def boom(texts, cfg, timeout=None):
            raise mod.EmbedError("api", {"message": "down"})
        with patch.object(mod, "embed_texts", boom), \
             patch.object(mod, "update_index",
                          lambda *a, **k: called.append(True)):
            self.run_main()
        self.assertEqual(called, [])
        self.assertEqual(self.rows()[-1]["stage"], "query")
        self.assertEqual(self.rows()[-1]["kind"], "api")

    def test_migration_saved_and_logged_even_when_query_fails(self):
        """捨てた回の保存と migration は、想起が失敗しても済んでいる。"""
        with open(os.path.join(self.dir, mod.CACHE_NAME), "w") as f:
            json.dump({"model": "old-model", "entries": {"gone.md": {}}}, f)
        def boom(texts, cfg, timeout=None):
            raise mod.EmbedError("auth", {"message": "no key"})
        with patch.object(mod, "embed_texts", boom):
            self.run_main()
        with open(os.path.join(self.dir, mod.CACHE_NAME)) as f:
            saved = json.load(f)
        self.assertEqual(saved["model"], mod.CACHE_MODEL)
        self.assertEqual(saved["entries"], {})
        kinds = [r["kind"] for r in self.rows()]
        self.assertIn("migration", kinds)

    def test_first_run_does_not_log_migration(self):
        with patch.object(mod, "embed_texts", fake_embed_factory()):
            self.run_main()
        self.assertNotIn("migration", [r["kind"] for r in self.rows()])

    def test_recall_proceeds_when_the_empty_cache_cannot_be_saved(self):
        """手順2の保存が失敗しても想起は止めない（目標1）。"""
        with open(os.path.join(self.dir, mod.CACHE_NAME), "w") as f:
            json.dump({"model": "old-model", "entries": {}}, f)
        called = []
        def boom_save(memory_dir, cache):
            raise OSError("読み取り専用")
        with patch.object(mod, "save_cache", boom_save), \
             patch.object(mod, "embed_texts",
                          lambda *a, **k: called.append(True) or [[1.0, 0, 0, 0]]):
            self.run_main()
        # 発言の埋め込みまで到達している
        self.assertTrue(called)
        rec = [r for r in self.rows()
               if r.get("kind") == "local" and r.get("stage") == "startup"]
        self.assertTrue(rec)


class TestFragments(unittest.TestCase):
    def test_short_text_is_one_fragment(self):
        self.assertEqual(mod.split_fragments("あいう"), ["あいう"])

    def test_empty_text_is_one_fragment(self):
        self.assertEqual(mod.split_fragments(""), [""])

    def test_splits_without_overlap_and_loses_nothing(self):
        text = "x" * (mod.FRAGMENT_CHARS * 2 + 123)
        frags = mod.split_fragments(text)
        self.assertEqual(len(frags), 3)
        self.assertEqual("".join(frags), text)
        self.assertEqual(len(frags[0]), mod.FRAGMENT_CHARS)
        self.assertEqual(len(frags[2]), 123)

    def test_exact_multiple_has_no_empty_tail(self):
        frags = mod.split_fragments("y" * (mod.FRAGMENT_CHARS * 2))
        self.assertEqual(len(frags), 2)

    def test_single_fragment_average_equals_the_vector(self):
        v = mod.normalize([1.0, 2.0, 3.0, 4.0])
        got = mod.weighted_average([v], [4000])
        for a, b in zip(got, v):
            self.assertAlmostEqual(a, b, places=5)

    def test_average_is_unit_length(self):
        a = mod.normalize([1.0, 0.0, 0.0, 0.0])
        b = mod.normalize([0.0, 1.0, 0.0, 0.0])
        got = mod.weighted_average([a, b], [6000, 6000])
        self.assertAlmostEqual(sum(x * x for x in got), 1.0, places=4)

    def test_longer_fragment_pulls_the_average(self):
        a = mod.normalize([1.0, 0.0, 0.0, 0.0])
        b = mod.normalize([0.0, 1.0, 0.0, 0.0])
        got = mod.weighted_average([a, b], [6000, 1000])
        self.assertGreater(got[0], got[1])

    def test_empty_file_does_not_crash(self):
        """空のメモリファイルは断片1つ・重み0になる。落ちないこと。

        spec の実測どおり API は空文字列を正常に返すので、この経路は実在する。
        得られるのはゼロベクトルで、閾値を超えないだけ。
        """
        got = mod.weighted_average([mod.normalize([0.0, 0.0, 0.0, 0.0])], [0])
        self.assertEqual(len(got), 4)
        self.assertEqual(sum(abs(x) for x in got), 0.0)


class TestUpdateIndexFileLevelCommit(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.log_path = os.path.join(self.dir, "log")
        self.p = [patch.object(mod, "LOG_PATH", self.log_path),
                  patch.object(mod, "LOCK_PATH", self.log_path + ".lock")]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in self.p:
            p.stop()
        self.tmp.cleanup()

    def write(self, name, text):
        with open(os.path.join(self.dir, name), "w") as f:
            f.write(text)

    def fresh_cache(self):
        return {"model": mod.CACHE_MODEL, "entries": {}}

    def test_long_file_becomes_one_entry(self):
        self.write("long.md", "あ" * (mod.FRAGMENT_CHARS * 2 + 10))
        self.write("short.md", "短い")
        cache = self.fresh_cache()
        with patch.object(mod, "embed_texts", fake_embed_factory()):
            mod.update_index(self.dir, cache, {}, time.monotonic() + 10)
        self.assertEqual(set(cache["entries"]), {"long.md", "short.md"})
        self.assertEqual(len(cache["entries"]["long.md"]["vector"]), 4)

    def test_file_with_a_failed_fragment_is_not_written(self):
        """断片が1つでも落ちたファイルは entries へ入らない。設計2の中心。

        呼び出し回数では狙えない。昇順処理で短いファイルが先に来るため。
        長い文書の2つの断片を別の文字で埋めて、後半の断片だけを落とす。
        """
        self.write("long.md", "あ" * mod.FRAGMENT_CHARS + "い" * mod.FRAGMENT_CHARS)
        self.write("ok.md", "短い")
        def tail_fails(texts, cfg, timeout=None):
            if any(t.startswith("い") for t in texts):
                raise mod.EmbedError("api", {"message": "tail fails"})
            return fake_embed_factory()(texts, cfg, timeout)
        with patch.object(mod, "BATCH_SIZE", 1), \
             patch.object(mod, "embed_texts", tail_fails):
            mod.update_index(self.dir, cache := self.fresh_cache(), {},
                             time.monotonic() + 10)
        # 前半の断片は成功しているが、揃っていないので確定しない
        self.assertNotIn("long.md", cache["entries"])

    def test_other_files_in_the_same_run_are_still_written(self):
        self.write("long.md", "あ" * mod.FRAGMENT_CHARS + "い" * mod.FRAGMENT_CHARS)
        self.write("ok.md", "短い")
        def tail_fails(texts, cfg, timeout=None):
            if any(t.startswith("い") for t in texts):
                raise mod.EmbedError("api", {"message": "tail fails"})
            return fake_embed_factory()(texts, cfg, timeout)
        with patch.object(mod, "BATCH_SIZE", 1), \
             patch.object(mod, "embed_texts", tail_fails):
            mod.update_index(self.dir, cache := self.fresh_cache(), {},
                             time.monotonic() + 10)
        self.assertIn("ok.md", cache["entries"])
        self.assertNotIn("long.md", cache["entries"])

    def test_deadline_leaves_unfinished_files_unwritten(self):
        """締め切りで断片を処理しきれなかったファイルも書き込まない。"""
        self.write("long.md", "あ" * mod.FRAGMENT_CHARS + "い" * mod.FRAGMENT_CHARS)
        calls = {"n": 0}
        def slow(texts, cfg, timeout=None):
            calls["n"] += 1
            if calls["n"] > 1:
                raise AssertionError("締め切り後に呼ばれた")
            return fake_embed_factory()(texts, cfg, timeout)
        with patch.object(mod, "BATCH_SIZE", 1), \
             patch.object(mod, "embed_texts", slow), \
             patch.object(mod, "time") as fake_time:
            # 1回目(update_indexの束チェック)と2回目(process_batch入口)は締め切り前、
            # 3回目(次の束のupdate_indexチェック)で締め切り後にする
            fake_time.monotonic.side_effect = [0, 0, 100]
            mod.update_index(self.dir, cache := self.fresh_cache(), {}, 10)
        self.assertEqual(cache["entries"], {})

    def test_deletion_alone_is_persisted(self):
        """新規も変更も無く削除だけの回でもキャッシュを保存する。"""
        cache = {"model": mod.CACHE_MODEL,
                 "entries": {"gone.md": {"hash": "h", "description": "d",
                                         "vector": [1.0, 0, 0, 0]}}}
        with patch.object(mod, "embed_texts", fake_embed_factory()):
            mod.update_index(self.dir, cache, {}, time.monotonic() + 10)
        with open(os.path.join(self.dir, mod.CACHE_NAME)) as f:
            self.assertEqual(json.load(f)["entries"], {})

    def test_shortest_files_are_processed_first(self):
        self.write("big.md", "あ" * 5000)
        self.write("small.md", "い" * 10)
        seen = []
        def recorder(texts, cfg, timeout=None):
            seen.extend(len(t) for t in texts)
            return fake_embed_factory()(texts, cfg, timeout)
        with patch.object(mod, "BATCH_SIZE", 1), \
             patch.object(mod, "embed_texts", recorder):
            mod.update_index(self.dir, self.fresh_cache(), {}, time.monotonic() + 10)
        self.assertEqual(seen[0], 10)

    def test_auth_stops_the_index_update(self):
        for i in range(5):
            self.write(f"f{i}.md", f"内容{i}")
        calls = {"n": 0}
        def always_auth(texts, cfg, timeout=None):
            calls["n"] += 1
            raise mod.EmbedError("auth", {"message": "no key"})
        with patch.object(mod, "BATCH_SIZE", 1), \
             patch.object(mod, "embed_texts", always_auth):
            mod.update_index(self.dir, self.fresh_cache(), {}, time.monotonic() + 10)
        self.assertEqual(calls["n"], 1)

    def test_api_continues_to_the_next_batch(self):
        for i in range(3):
            self.write(f"f{i}.md", f"内容{i}")
        calls = {"n": 0}
        def always_api(texts, cfg, timeout=None):
            calls["n"] += 1
            raise mod.EmbedError("api", {"message": "down"})
        with patch.object(mod, "BATCH_SIZE", 1), \
             patch.object(mod, "embed_texts", always_api):
            mod.update_index(self.dir, self.fresh_cache(), {}, time.monotonic() + 10)
        self.assertEqual(calls["n"], 3)

    @unittest.skipIf(os.geteuid() == 0, "root は権限を無視するので再現できない")
    def test_unreadable_memory_file_is_skipped(self):
        self.write("ok.md", "読める")
        bad = os.path.join(self.dir, "bad.md")
        self.write("bad.md", "読めない")
        os.chmod(bad, 0o000)
        try:
            with patch.object(mod, "embed_texts", fake_embed_factory()):
                mod.update_index(self.dir, cache := self.fresh_cache(), {},
                                 time.monotonic() + 10)
            self.assertIn("ok.md", cache["entries"])
            self.assertNotIn("bad.md", cache["entries"])
        finally:
            os.chmod(bad, 0o644)

    def test_partial_is_logged_when_deadline_hits(self):
        for i in range(5):
            self.write(f"f{i}.md", f"内容{i}")
        with patch.object(mod, "BATCH_SIZE", 1), \
             patch.object(mod, "embed_texts", fake_embed_factory()):
            mod.update_index(self.dir, self.fresh_cache(), {}, time.monotonic() - 1)
        with open(self.log_path) as f:
            kinds = [json.loads(x)["kind"] for x in f if x.strip()]
        self.assertIn("partial", kinds)

    def test_stale_mark_makes_every_file_pending(self):
        """版の印が合わないキャッシュは捨てられ、全件が未処理になる。"""
        with tempfile.TemporaryDirectory() as d:
            for i in range(3):
                with open(os.path.join(d, f"f{i}.md"), "w") as f:
                    f.write(f"内容{i}")
            # 旧い印で、しかも中身が入っているキャッシュを置く
            with open(os.path.join(d, mod.CACHE_NAME), "w") as f:
                json.dump({"model": "@cf/baai/bge-m3",
                           "entries": {"f0.md": {"hash": "古い", "description": "d",
                                                 "vector": [1.0, 0, 0, 0]}}}, f)
            cache, reason, prev = mod.load_cache(d)
            self.assertEqual(reason, "model_mismatch")
            self.assertEqual(prev, "@cf/baai/bge-m3")
            self.assertEqual(cache["entries"], {})   # 中身は引き継がれない
            fake = fake_embed_factory()
            with patch.object(mod, "embed_texts", fake):
                mod.update_index(d, cache, {}, time.monotonic() + 60)
            self.assertEqual(sorted(cache["entries"]),
                             ["f0.md", "f1.md", "f2.md"])   # 全件が作り直された


class TestIsolation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.log_path = os.path.join(self.tmp.name, "log")
        self.p = [patch.object(mod, "LOG_PATH", self.log_path),
                  patch.object(mod, "LOCK_PATH", self.log_path + ".lock")]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in self.p:
            p.stop()
        self.tmp.cleanup()

    def rows(self):
        with open(self.log_path) as f:
            return [json.loads(x) for x in f if x.strip()]

    def test_binary_split_names_the_single_culprit(self):
        batch = [(f"f{i}.md", 0, f"text{i}") for i in range(4)]

        def fails_on_f2(texts, cfg, timeout=None):
            if any(t == "text2" for t in texts):
                raise mod.EmbedError("document",
                                     {"message": "Sequence too long: 9000 > 8192",
                                      "tokens": 9000, "limit": 8192})
            return fake_embed_factory()(texts, cfg, timeout)

        collected = {}
        with patch.object(mod, "embed_texts", fails_on_f2):
            mod.process_batch(batch, {}, time.monotonic() + 10, collected)
        docs = [r for r in self.rows() if r["kind"] == "document"]
        self.assertEqual(len(docs), 1)
        self.assertEqual(docs[0]["target"], "f2.md")
        self.assertEqual(docs[0]["tokens"], 9000)
        self.assertEqual(docs[0]["stage"], "index")   # stage の3値目を照合する

    def test_successful_half_is_kept(self):
        batch = [(f"f{i}.md", 0, f"text{i}") for i in range(4)]

        def fails_on_f2(texts, cfg, timeout=None):
            if any(t == "text2" for t in texts):
                raise mod.EmbedError("document", {"message": "Sequence too long: 9000 > 8192"})
            return fake_embed_factory()(texts, cfg, timeout)

        collected = {}
        with patch.object(mod, "embed_texts", fails_on_f2):
            mod.process_batch(batch, {}, time.monotonic() + 10, collected)
        self.assertEqual(set(collected), {"f0.md", "f1.md", "f3.md"})

    def test_records_fragment_position(self):
        batch = [("long.md", 2, "x" * 100)]

        def always_doc(texts, cfg, timeout=None):
            raise mod.EmbedError("document", {"message": "Sequence too long: 9000 > 8192"})

        with patch.object(mod, "embed_texts", always_doc):
            mod.process_batch(batch, {}, time.monotonic() + 10, {})
        rec = [r for r in self.rows() if r["kind"] == "document"][0]
        self.assertEqual(rec["fragment"], 2)
        self.assertEqual(rec["span"], [2 * mod.FRAGMENT_CHARS,
                                       2 * mod.FRAGMENT_CHARS + 100])

    def test_api_failure_carries_no_target(self):
        """api は target を持たない。付けると健診が捨てて報告から消える。"""
        batch = [("only.md", 0, "text")]

        def always_api(texts, cfg, timeout=None):
            raise mod.EmbedError("api", {"message": "down"})

        with patch.object(mod, "embed_texts", always_api):
            mod.process_batch(batch, {}, time.monotonic() + 10, {})
        rec = [r for r in self.rows() if r["kind"] == "api"][0]
        self.assertNotIn("target", rec)
        self.assertNotIn("fragment", rec)

    def test_batch_kind_is_resplit(self):
        batch = [(f"f{i}.md", 0, f"t{i}") for i in range(4)]
        calls = {"n": 0}

        def big_first(texts, cfg, timeout=None):
            calls["n"] += 1
            if len(texts) == 4:
                raise mod.EmbedError("batch",
                                     {"message": "Max context reached 120000 tokens "
                                                 "but model supports only 60000",
                                      "tokens": 120000, "limit": 60000})
            return fake_embed_factory()(texts, cfg, timeout)

        collected = {}
        with patch.object(mod, "embed_texts", big_first):
            mod.process_batch(batch, {}, time.monotonic() + 10, collected)
        self.assertEqual(len(collected), 4)

    def test_document_split_on_odd_batch_is_a_true_halve(self):
        """document は parts=2。奇数件の束を割ったとき単発1件×n個ではなく
        ちょうど2束(2件+3件)に分かれることを確認する。固定ステップの旧実装だと
        2,2,1 の3束になり、この境界計算でしか通らない。"""
        batch = [(f"f{i}.md", 0, f"text{i}") for i in range(5)]
        sizes = []

        def fails_only_on_full_batch(texts, cfg, timeout=None):
            sizes.append(len(texts))
            if len(texts) == 5:
                raise mod.EmbedError("document",
                                     {"message": "Sequence too long: 9000 > 8192"})
            return fake_embed_factory()(texts, cfg, timeout)

        collected = {}
        with patch.object(mod, "embed_texts", fails_only_on_full_batch):
            mod.process_batch(batch, {}, time.monotonic() + 10, collected)
        self.assertEqual(sizes, [5, 2, 3])
        self.assertEqual(len(collected), 5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
