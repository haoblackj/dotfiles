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
COSMIC_RAY = os.path.join(REPO_ROOT, ".cosmic-ray.toml")

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

    def test_this_test_file_is_excluded_from_mutation(self):
        # **層2の Task 6 が同じ穴を開け、Task 10 のレビューまで見つからなかった。**
        # 新しく足したテスト .py を変異テストの除外へ登録し忘れると、
        # テスト自身が変異の対象になる。
        excluded = _load(COSMIC_RAY)["cosmic-ray"]["excluded-modules"]
        self.assertIn("dot_claude/hooks/tests/test_pytest_config.py", excluded)


if __name__ == "__main__":
    unittest.main()
