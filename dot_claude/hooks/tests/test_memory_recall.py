import importlib.util
import os
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
            cache = mod.load_cache(d)
            self.assertEqual(cache, {"model": mod.MODEL, "entries": {}})
            cache["entries"]["a.md"] = {"hash": "h", "description": "d", "vector": [1.0]}
            mod.save_cache(d, cache)
            self.assertEqual(mod.load_cache(d)["entries"]["a.md"]["hash"], "h")
            # 破損 → 空で再出発
            Path(d, mod.CACHE_NAME).write_text("{broken json")
            self.assertEqual(mod.load_cache(d)["entries"], {})
            # モデル不一致 → 空で再出発
            Path(d, mod.CACHE_NAME).write_text(
                '{"model": "old-model", "entries": {"a.md": {}}}')
            self.assertEqual(mod.load_cache(d)["entries"], {})
            # 有効なJSONだがdictでない → 空で再出発
            Path(d, mod.CACHE_NAME).write_text("[1, 2, 3]")
            self.assertEqual(mod.load_cache(d)["entries"], {})
            Path(d, mod.CACHE_NAME).write_text("null")
            self.assertEqual(mod.load_cache(d)["entries"], {})


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
                cache = mod.load_cache(d)
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
                cache = mod.load_cache(d)
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
                cache = mod.load_cache(d)
                # 締切を過去にする → 1バッチも処理せず持ち越し
                done = mod.update_index(d, cache, {}, time.monotonic() - 1)
                self.assertFalse(done)
                self.assertEqual(len(cache["entries"]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
