import contextlib
import hashlib
import importlib.util
import io
import json
import multiprocessing
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

    def test_message_has_no_newlines(self):
        """JSON でない本文の改行を message へ持ち込まない。

        健診は message を `CAUSE:` の1行へ埋め込む。改行が残ると1レコードが
        複数行へ割れ、`KEY=値` / `接頭辞:値` の約束が壊れる。障害の最中こそ
        報告が要るので、ここで畳んでおく。
        """
        kind, detail = self.classify(
            502, "<html>\n<head><title>502 Bad Gateway</title></head>\n"
                 "<body>\r\n<h1>502</h1>\t</body>\n</html>\n")
        self.assertEqual(kind, "api")
        self.assertNotIn("\n", detail["message"])
        self.assertNotIn("\r", detail["message"])
        self.assertNotIn("\t", detail["message"])
        # 中身は落とさない。畳むだけで捨ててはいない。
        self.assertIn("502 Bad Gateway", detail["message"])


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

    def test_main_uses_a_cache_already_rebuilt_by_another_session(self):
        """main の手順2は reset_stale_cache を経由し、ロックの中でディスクを
        読み直す。手順1（main の最初の読み）と手順2（ロック内の読み直し）の
        間に別セッション(B)が先に作り直して項目を確定していれば、その進捗を
        空で上書きせず、想起にも使う（issue #59 レビューの major 指摘）。

        手順2を旧経路 save_cache(memory_dir, cache) に戻す変異では
        reset_stale_cache が呼ばれず、load_cache の2回目の呼び出しそのものが
        起きない。その場合 B の進捗を再現するタイミングが無く、cache は
        手順1で得た空の雛形のまま上書き保存され、想起も出ない。
        """
        calls = {"n": 0}
        real_load_cache = mod.load_cache
        fresh_vec = [1.0, 0.0, 0.0, 0.0]

        def racy_load_cache(memory_dir):
            calls["n"] += 1
            if calls["n"] == 2:
                # 手順1と手順2の間に B が版の印を直して a.md を確定させた体
                with open(os.path.join(memory_dir, "a.md"), "rb") as f:
                    h = hashlib.sha256(f.read()).hexdigest()
                fresh = {"model": mod.CACHE_MODEL,
                         "entries": {"a.md": {"hash": h, "description": "あるメモ",
                                              "vector": fresh_vec}}}
                with open(os.path.join(memory_dir, mod.CACHE_NAME), "w") as f2:
                    json.dump(fresh, f2)
            return real_load_cache(memory_dir)

        with open(os.path.join(self.dir, mod.CACHE_NAME), "w") as f:
            json.dump({"model": "old-model", "entries": {}}, f)

        def fake_embed(texts, cfg, timeout=None):
            return [fresh_vec for _ in texts]

        with patch.object(mod, "load_cache", racy_load_cache), \
             patch.object(mod, "embed_texts", fake_embed), \
             patch.object(mod, "update_index", lambda *a, **k: None):
            out = self.run_main("あるメモについて詳しく教えてほしい")

        self.assertEqual(calls["n"], 2)
        with open(os.path.join(self.dir, mod.CACHE_NAME)) as f:
            saved = json.load(f)
        self.assertIn("a.md", saved["entries"])  # B の進捗が空で上書きされていない
        self.assertIn("[memory-recall]", out)    # 想起にも使われている
        self.assertIn("a.md", out)

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

    def test_deadline_inside_the_split_recursion_is_still_logged(self):
        """分割の再帰の中で締め切りを越えた回も partial を残す。

        process_batch は入口で締め切りを見つけると何も記録せず False を返す。
        update_index が返り値を捨てていた頃は、最後の束がこの経路へ入ると
        hit_deadline が立たず partial も出ず、索引から消えたファイルだけが
        残った。健診はそれを「原因の記録なし」としか書けず、ただの時間切れが
        正体不明の故障と見分けられなくなる。
        """
        for i in range(4):
            self.write(f"f{i}.md", f"内容{i}")

        def always_document(texts, cfg, timeout=None):
            raise mod.EmbedError("document",
                                 {"message": "Sequence too long: 9000 > 8192"})

        with patch.object(mod, "embed_texts", always_document), \
             patch.object(mod, "time") as fake_time:
            # 1: update_index の束チェック（締め切り前）
            # 2: process_batch 入口（締め切り前）
            # 3: 分割してよいかの判定（締め切り前）
            # 4,5: 割った先の入口（締め切り後 → 何も記録せず False）
            # 6: update_index が返り値を見たあとの判定（締め切り後）
            fake_time.monotonic.side_effect = [0, 0, 0, 100, 100, 100, 100, 100]
            mod.update_index(self.dir, self.fresh_cache(), {}, 10)
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


# fork を名指しする。Python 3.14 の Linux 既定は forkserver で、子が importlib で
# 読み込んだ mod と patch を引き継げない。
_MP = multiprocessing.get_context("fork")


def _session(memory_dir, log_path, barrier, opts, out_q):
    """1セッション相当の子プロセス。snapshot を読み、barrier のあとで索引を更新する。

    opts の鍵:
      vec            この session の偽 embed が返すベクトル
      fail_on        本文にこの文字列を含む断片を api で落とす（session ごとの delta を分ける）
      wait_index     update_index に入る前に待つ Event
      delete_first   update_index に入る直前にディスクから消すファイル名
      set_on_embed   最初の埋め込みで立てる Event（ファイル一覧の列挙が済んだ印）
      wait_on_embed  埋め込みの前に待つ Event（commit の順序を決める）
    """
    patches = [patch.object(mod, "LOG_PATH", log_path),
               patch.object(mod, "LOCK_PATH", log_path + ".lock"),
               patch.object(mod, "BATCH_SIZE", 1)]
    for p in patches:
        p.start()
    try:
        cache, _reason, _prev = mod.load_cache(memory_dir)   # snapshot
        barrier.wait(timeout=10)                             # 両方が同じ snapshot を持つ
        if opts.get("wait_index"):
            opts["wait_index"].wait(timeout=10)
        if opts.get("delete_first"):
            os.unlink(os.path.join(memory_dir, opts["delete_first"]))

        def fake(texts, cfg, timeout=None):
            if opts.get("set_on_embed"):
                opts["set_on_embed"].set()
            if opts.get("wait_on_embed"):
                opts["wait_on_embed"].wait(timeout=10)
            if opts.get("fail_on") and any(opts["fail_on"] in t for t in texts):
                raise mod.EmbedError("api", {"message": "this session skips it"})
            return [list(opts["vec"]) for _ in texts]

        with patch.object(mod, "embed_texts", fake):
            t0 = time.monotonic()
            ok = mod.update_index(memory_dir, cache, {}, time.monotonic() + 10)
            out_q.put({"ok": ok, "elapsed": time.monotonic() - t0,
                       "entries": sorted(cache["entries"])})
    except BaseException as e:  # 子の失敗は親へ運ぶ。黙って死ぶと join だけが通る。
        out_q.put({"error": f"{type(e).__name__}: {e}"})


class TestConcurrentCommit(unittest.TestCase):
    """2セッションが同じ snapshot から別々に索引を更新する（issue #13）。

    順序は Event で固定する。A が commit を終えてから B の埋め込みを進めるので、
    B は必ず A より後に commit し、かつ A の commit より前に読んだ snapshot を持つ。
    これが issue の「後勝ち」を作る最小の条件で、順序が決まっているので
    落ちるときは毎回落ちる。
    """

    A_VEC = (1.0, 0.0, 0.0, 0.0)
    B_VEC = (0.0, 1.0, 0.0, 0.0)

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

    def indexed_entry(self, name, vec=(1.0, 0.0, 0.0, 0.0)):
        with open(os.path.join(self.dir, name), "rb") as f:
            h = hashlib.sha256(f.read()).hexdigest()
        return {"hash": h, "description": name, "vector": list(vec)}

    def write_cache(self, entries):
        with open(os.path.join(self.dir, mod.CACHE_NAME), "w") as f:
            json.dump({"model": mod.CACHE_MODEL, "entries": entries}, f)

    def disk_entries(self):
        with open(os.path.join(self.dir, mod.CACHE_NAME)) as f:
            return json.load(f)["entries"]

    def run_a_then_b(self, a_opts, b_opts):
        """A と B を同じ snapshot から走らせ、A の commit のあとで B の埋め込みを進める。"""
        barrier = _MP.Barrier(2)
        go_b = _MP.Event()
        out_q = _MP.Queue()
        b_opts = dict(b_opts, wait_on_embed=go_b)
        procs = [_MP.Process(target=_session,
                             args=(self.dir, self.log_path, barrier, o, out_q))
                 for o in (a_opts, b_opts)]
        a, b = procs
        b.start()
        a.start()
        a.join(timeout=20)
        go_b.set()
        b.join(timeout=20)
        results = [out_q.get(timeout=5) for _ in procs]
        for r in results:
            self.assertNotIn("error", r, r)
        self.assertEqual([a.exitcode, b.exitcode], [0, 0])
        return results

    def test_both_sessions_additions_survive(self):
        """(1) 別々の項目を足した2つの session の結果が両方残る。"""
        self.write("x.md", "内容X")
        self.write("y.md", "内容Y")
        self.write_cache({})
        self.run_a_then_b({"vec": self.A_VEC, "fail_on": "内容Y"},
                          {"vec": self.B_VEC, "fail_on": "内容X"})
        got = self.disk_entries()
        self.assertEqual(sorted(got), ["x.md", "y.md"])
        self.assertEqual(got["x.md"]["vector"], list(self.A_VEC))
        self.assertEqual(got["y.md"]["vector"], list(self.B_VEC))

    def test_deleted_entry_is_not_resurrected_by_a_stale_snapshot(self):
        """(2) A が消した項目を、削除前の snapshot を持つ B の保存が復活させない。"""
        self.write("gone.md", "消える")
        self.write("y.md", "内容Y")
        self.write_cache({"gone.md": self.indexed_entry("gone.md")})
        listed_b = _MP.Event()
        # B は gone.md がまだ在る状態でファイル一覧を取り、埋め込みで止まる。
        # A はその印を待ってから gone.md を消し、項目を取り除いて commit する。
        self.run_a_then_b({"vec": self.A_VEC, "fail_on": "内容Y",
                           "wait_index": listed_b, "delete_first": "gone.md"},
                          {"vec": self.B_VEC, "set_on_embed": listed_b})
        got = self.disk_entries()
        self.assertNotIn("gone.md", got)
        self.assertIn("y.md", got)

    def test_same_entry_first_commit_wins_for_identical_content(self):
        """(3) 同じ内容を両方が埋め込んだら、先に commit した側のベクトルが残る。

        規則: ハッシュが同じ項目は先の commit を残す（後から同じ内容を埋め込み
        直しても上書きしない）。順序を入れ替えれば勝者も入れ替わることまで見る。
        片方だけ見ると「常に A」という別の規則と区別がつかない。
        """
        self.write("s.md", "同じ内容")
        self.write_cache({})
        self.run_a_then_b({"vec": self.A_VEC}, {"vec": self.B_VEC})
        self.assertEqual(self.disk_entries()["s.md"]["vector"], list(self.A_VEC))

        self.write_cache({})
        self.run_a_then_b({"vec": self.B_VEC}, {"vec": self.A_VEC})
        self.assertEqual(self.disk_entries()["s.md"]["vector"], list(self.B_VEC))

    def test_commit_waits_a_bounded_time_and_carries_over(self):
        """(4) commit ロックが取れないとき、待ちに上限があり、保存を諦めて持ち越す。"""
        self.write("x.md", "内容X")
        lock = os.path.join(self.dir, mod.CACHE_NAME + ".lock")
        open(lock, "w").close()   # 別 session が commit 中の体
        cache = {"model": mod.CACHE_MODEL, "entries": {}}
        with patch.object(mod, "embed_texts", const_embed()):
            t0 = time.monotonic()
            ok = mod.update_index(self.dir, cache, {}, time.monotonic() + 10)
            elapsed = time.monotonic() - t0
        self.assertFalse(ok)
        self.assertFalse(os.path.exists(os.path.join(self.dir, mod.CACHE_NAME)))
        # 上限は締め切り 4.2 秒の一部に収まる。ここを超えると発言のたびに
        # ロック待ちで想起の応答が目に見えて遅れる。
        self.assertLessEqual(mod.COMMIT_LOCK_WAIT_SEC, mod.DEADLINE_SEC * 0.15)
        self.assertLess(elapsed, mod.COMMIT_LOCK_WAIT_SEC + 0.5)
        self.assertGreaterEqual(elapsed, mod.COMMIT_LOCK_WAIT_SEC * 0.8)
        with open(self.log_path) as f:
            rows = [json.loads(x) for x in f if x.strip()]
        self.assertTrue(any(r.get("target") == mod.CACHE_NAME and r.get("kind") == "local"
                            for r in rows))
        # ロックが解けた次の回で保存される（持ち越し）
        os.remove(lock)
        with patch.object(mod, "embed_texts", const_embed()):
            self.assertTrue(mod.update_index(self.dir, cache, {}, time.monotonic() + 10))
        self.assertIn("x.md", self.disk_entries())

    def test_stale_lock_theft_restores_a_lock_found_fresh_after_rename(self):
        """mtime のチェックと rename の間に別プロセスが同じ path へ新しい
        ロックを作り直していたら、奪った先の mtime で気づいて元へ戻す
        （レビュー #59 の minor race 指摘: check-then-remove の非原子性）。
        """
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "x.lock")
            open(path, "w").close()
            calls = {"n": 0}
            real_getmtime = os.path.getmtime

            def racy_getmtime(p):
                calls["n"] += 1
                if calls["n"] == 1:
                    return time.time() - 999  # 最初のチェックでは古く見える
                return time.time()  # 奪った直後の再チェックでは新しい
            with patch.object(mod.os.path, "getmtime", racy_getmtime):
                got = mod.acquire_lock(path, stale_sec=60, wait_sec=0)
            self.assertFalse(got)
            self.assertTrue(os.path.exists(path))  # 元へ戻されている
            leftovers = [f for f in os.listdir(d) if f != "x.lock"]
            self.assertEqual(leftovers, [])  # 退避ファイルが残っていない

    def test_stale_commit_lock_is_stolen(self):
        self.write("x.md", "内容X")
        lock = os.path.join(self.dir, mod.CACHE_NAME + ".lock")
        open(lock, "w").close()
        os.utime(lock, (time.time() - 999, time.time() - 999))
        cache = {"model": mod.CACHE_MODEL, "entries": {}}
        with patch.object(mod, "embed_texts", const_embed()):
            self.assertTrue(mod.update_index(self.dir, cache, {}, time.monotonic() + 10))
        self.assertIn("x.md", self.disk_entries())
        self.assertFalse(os.path.exists(lock))

    def test_commit_drops_a_delta_whose_file_changed_meanwhile(self):
        """commit 時点のファイルと合わないハッシュの項目は書かない。次の発言で作り直す。"""
        self.write("s.md", "旧い内容")
        stale = self.indexed_entry("s.md", self.A_VEC)
        self.write("s.md", "新しい内容")
        merged = mod.commit_cache(self.dir, {"s.md": stale}, set())
        self.assertEqual(merged["entries"], {})
        self.assertEqual(self.disk_entries(), {})

    def test_commit_drops_a_delta_whose_file_is_gone(self):
        """埋め込みの最中に消えたファイルの項目を、実体なしのまま載せない。"""
        self.write("s.md", "内容")
        entry = self.indexed_entry("s.md", self.A_VEC)
        os.unlink(os.path.join(self.dir, "s.md"))
        merged = mod.commit_cache(self.dir, {"s.md": entry}, set())
        self.assertEqual(merged["entries"], {})

    def test_commit_keeps_an_entry_whose_file_came_back(self):
        """snapshot で消えていたファイルが commit 時点で戻っていたら削除しない。"""
        self.write("s.md", "内容")
        entry = self.indexed_entry("s.md", self.A_VEC)
        self.write_cache({"s.md": entry})
        merged = mod.commit_cache(self.dir, {}, {"s.md"})
        self.assertIn("s.md", merged["entries"])
        self.assertIn("s.md", self.disk_entries())

    def test_commit_replaces_an_entry_whose_hash_is_stale_on_disk(self):
        """ディスクの項目が古いハッシュなら、現在の内容に合う側が勝つ。"""
        self.write("s.md", "旧い内容")
        old = self.indexed_entry("s.md", self.A_VEC)
        self.write_cache({"s.md": old})
        self.write("s.md", "新しい内容")
        new = self.indexed_entry("s.md", self.B_VEC)
        merged = mod.commit_cache(self.dir, {"s.md": new}, set())
        self.assertEqual(merged["entries"]["s.md"]["vector"], list(self.B_VEC))

    def test_reset_does_not_wipe_a_cache_another_session_already_rebuilt(self):
        """版の印の作り直し中に、別 session が確定した進捗を空で上書きしない。

        A が old-model を読んで捨てる判断をしたあと、B が先に空へ戻して
        項目を確定していた場合、A の「空で保存」は B の進捗を消す。
        commit と同じロックの中でディスクを読み直し、まだ古いときだけ書く。
        """
        self.write("s.md", "内容")
        # A が読んだ時点では old-model だったが、いまは B が作り直したあと
        self.write_cache({"s.md": self.indexed_entry("s.md")})
        wrote, latest = mod.reset_stale_cache(self.dir)
        self.assertFalse(wrote)
        self.assertIn("s.md", latest["entries"])
        self.assertIn("s.md", self.disk_entries())

    def test_reset_writes_the_empty_cache_when_the_disk_is_still_stale(self):
        with open(os.path.join(self.dir, mod.CACHE_NAME), "w") as f:
            json.dump({"model": "old-model", "entries": {"s.md": {}}}, f)
        wrote, latest = mod.reset_stale_cache(self.dir)
        self.assertTrue(wrote)
        self.assertEqual(latest["entries"], {})
        self.assertEqual(self.disk_entries(), {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
