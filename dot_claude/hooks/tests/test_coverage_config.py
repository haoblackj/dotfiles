"""カバレッジ設定（`[tool.coverage.*]`）の単体テスト。penguinEx 側の
`tests/test_coverage_config.py` と同じ構成。source と omit の中身だけが
このリポジトリ（chezmoi ソース）に合わせてある。

**期待値は設定から読み直さない。**ここに書き下した列挙が正であり、
`pyproject.toml` の側がこれと一致することを確かめる。

**penguinEx のテストからは chezmoi の設定を読めない**（隔離の中では
`~/.local/share/chezmoi` が使い捨て HOME に隠れる）ので、この検査は
chezmoi 側に置く。
"""
import os
import tomllib
import unittest

# .../chezmoi/dot_claude/hooks/tests/test_coverage_config.py から
# 4段上がるとリポジトリ直下（pyproject.toml がある場所）。
REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
)
PYPROJECT = os.path.join(REPO_ROOT, "pyproject.toml")

EXPECTED_SOURCE = [
    "dot_claude/hooks",
]

# executable_stop-fabricated-turn-guard.py はシェルテストからサブプロセス
# として検証されており、pytest --cov の計測は届かない。
EXPECTED_OMIT_ENTRY = "dot_claude/hooks/executable_stop-fabricated-turn-guard.py"

EXPECTED_DATA_FILE = "${COVERAGE_OUT_DIR?}/.coverage"


def _load_pyproject():
    with open(PYPROJECT, "rb") as f:
        return tomllib.load(f)


def _pyproject_text():
    with open(PYPROJECT, encoding="utf-8") as f:
        return f.read()


class CoverageConfigTest(unittest.TestCase):
    def test_branch_mode_enabled(self):
        data = _load_pyproject()
        run = data["tool"]["coverage"]["run"]
        self.assertIs(run["branch"], True)

    def test_source_matches_spec_enumeration(self):
        data = _load_pyproject()
        run = data["tool"]["coverage"]["run"]
        self.assertEqual(run["source"], EXPECTED_SOURCE)

    def test_source_includes_test_directory(self):
        data = _load_pyproject()
        run = data["tool"]["coverage"]["run"]
        self.assertIn("dot_claude/hooks", run["source"])

    def test_omit_has_single_reasoned_non_glob_entry(self):
        data = _load_pyproject()
        run = data["tool"]["coverage"]["run"]
        omit = run["omit"]
        self.assertEqual(omit, [EXPECTED_OMIT_ENTRY])
        # グロブでないこと。
        self.assertNotIn("*", EXPECTED_OMIT_ENTRY)

        # tomllib はコメントを捨てるので、理由が書かれているかは生テキストで
        # 確かめる。対象の行の直前に `#` で始まる行があること。
        text = _pyproject_text()
        idx = text.index('"' + EXPECTED_OMIT_ENTRY + '"')
        line_start = text.rfind("\n", 0, idx) + 1
        prev_line_end = line_start - 1
        prev_line_start = text.rfind("\n", 0, prev_line_end) + 1
        prev_line = text[prev_line_start:prev_line_end].strip()
        self.assertTrue(
            prev_line.startswith("#"),
            f"omit の直前行に理由のコメントが無い: {prev_line!r}",
        )

    def test_data_file_points_outside_repo(self):
        data = _load_pyproject()
        run = data["tool"]["coverage"]["run"]
        self.assertEqual(run["data_file"], EXPECTED_DATA_FILE)
        self.assertNotEqual(run["data_file"], ".coverage")


if __name__ == "__main__":
    unittest.main()
