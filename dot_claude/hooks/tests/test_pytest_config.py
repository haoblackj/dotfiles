"""pytest 設定の門（`[tool.pytest.ini_options]`）の単体テスト。

**期待値は設定から読み直さない。**ここに書き下した列挙が正であり、
`pyproject.toml` の側がこれと一致することを確かめる。

spec: penguinEx の
docs/superpowers/specs/2026-09-06-test-foundation-design.md の層3。
"""
import os
import tomllib
import unittest

# このファイルは <repo>/dot_claude/hooks/tests/ にある。
REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
PYPROJECT = os.path.join(REPO_ROOT, "pyproject.toml")

# このリポジトリのテストは1ディレクトリに集まっている。
EXPECTED_TESTPATHS = ["dot_claude/hooks/tests"]


def _load(path):
    with open(path, "rb") as f:
        return tomllib.load(f)


def _ini():
    return _load(PYPROJECT)["tool"]["pytest"]["ini_options"]


def _pyproject_text():
    with open(PYPROJECT, encoding="utf-8") as f:
        return f.read()


class PytestConfigTest(unittest.TestCase):
    def test_strict_is_enabled(self):
        self.assertIs(_ini()["strict"], True)

    def test_minversion_pins_pytest_nine(self):
        # **`strict` と対で必要。**pytest 8 以下では `strict` が未知の ini
        # として警告だけ出て黙って無効になる。
        self.assertEqual(_ini()["minversion"], "9")

    def test_filterwarnings_turns_warnings_into_errors(self):
        self.assertEqual(_ini()["filterwarnings"][0], "error")

    def test_every_allowed_warning_has_a_written_reason(self):
        fw = _ini()["filterwarnings"]
        text = _pyproject_text()
        for entry in fw[1:]:
            idx = text.index('"' + entry + '"')
            line_start = text.rfind("\n", 0, idx) + 1
            prev_line = text[text.rfind("\n", 0, line_start - 1) + 1:line_start - 1].strip()
            self.assertTrue(
                prev_line.startswith("#"),
                f"許した警告の直前行に理由のコメントが無い: {entry!r}",
            )

    def test_testpaths_points_at_the_single_test_directory(self):
        self.assertEqual(_ini()["testpaths"], EXPECTED_TESTPATHS)

    def test_no_pythonpath_is_needed_here(self):
        # **このリポジトリのテスト2本はどちらも素の兄弟 import に依存しない**
        # （importlib.util で自前に読む）。penguinEx 側と違って pythonpath は
        # 要らない。足すと「なぜ要るのか」の根拠が無い設定が残る。
        self.assertNotIn("pythonpath", _ini())

    def test_import_mode_is_not_overridden_to_importlib(self):
        ini = _ini()
        self.assertNotIn("import_mode", ini)
        for opt in ini["addopts"]:
            self.assertNotIn("importlib", opt)

    def test_log_level_is_set(self):
        self.assertEqual(_ini()["log_level"], "INFO")

    def test_addopts_asks_for_the_full_summary(self):
        self.assertIn("-ra", _ini()["addopts"])


class StrictActuallyFiresTest(unittest.TestCase):
    """`strict = true` が実際に効いていることを、子プロセスで確かめる。

    **設定の値を読むだけでは足りない。**設定が正しくても pytest 側の
    解釈が変われば門は消える。登録していないマーカーを打ったテストを
    使い捨てのリポジトリへ置き、`strict` の有無だけを変えて2回走らせる。
    """

    MARKED_TEST = (
        "import pytest\n"
        "\n"
        "\n"
        "@pytest.mark.this_marker_is_not_registered\n"
        "def test_placeholder():\n"
        "    assert True\n"
    )

    def _run_in_temp_repo(self, ini_body):
        import subprocess
        import sys
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "pyproject.toml"), "w", encoding="utf-8") as f:
                f.write("[tool.pytest.ini_options]\n" + ini_body)
            with open(os.path.join(tmp, "test_marked.py"), "w", encoding="utf-8") as f:
                f.write(self.MARKED_TEST)
            return subprocess.run(
                [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", tmp],
                cwd=tmp,
                capture_output=True,
                text=True,
            )

    def test_unregistered_marker_passes_without_strict(self):
        # 対照。`strict` が無ければ打ち間違えたマーカーは黙って通る。
        # **この側が落ちるなら、次の検査は `strict` とは無関係な理由で
        # 赤くなっている。**
        result = self._run_in_temp_repo('minversion = "9"\n')
        self.assertEqual(
            result.returncode, 0,
            f"strict 無しでも落ちた。この検査は strict を測っていない:\n"
            f"{result.stdout}\n{result.stderr}",
        )

    def test_unregistered_marker_fails_with_strict(self):
        # 本命。`strict = true` を足しただけで、同じテストが落ちる。
        result = self._run_in_temp_repo('minversion = "9"\nstrict = true\n')
        self.assertNotEqual(
            result.returncode, 0,
            f"strict = true でも打ち間違えたマーカーが通った:\n"
            f"{result.stdout}\n{result.stderr}",
        )
        self.assertIn("this_marker_is_not_registered", result.stdout + result.stderr)


def test_this_repositorys_config_is_the_effective_one(pytestconfig):
    """このリポジトリで実際に走っている pytest が、この pyproject.toml の
    `[tool.pytest.ini_options]` を読んでいることを確かめる。

    **上のテストは「ファイルに何が書いてあるか」しか見ていない。**
    `StrictActuallyFiresTest` も `strict` が使い捨てのリポジトリで効くこと
    しか証明しない。もし `pytest.ini` や `setup.cfg` がこのリポジトリに
    足されたら、pytest は `[tool.pytest.ini_options]` を無視してそちらを
    使う。そうなっても上のテストは pyproject.toml を直接読んでいるだけ
    なので全部緑のまま残り、門がいつの間にか無効化されたことに誰も
    気付けない。`pytestconfig.getini` は pytest が実際に採用した設定
    ソースを経由するので、ここが緑であることは「この pyproject.toml が
    有効である」ことの証拠になる。

    `unittest.TestCase` のメソッドにはしない。`pytestconfig` フィクスチャは
    `TestCase` のサブクラス内では使えない。
    """
    assert pytestconfig.getini("strict") is True


if __name__ == "__main__":
    unittest.main()
