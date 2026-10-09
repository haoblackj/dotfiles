"""post_design.py の単体テスト。

spec: haoblackj/penguinEx の
docs/superpowers/specs/2026-10-09-research-design-skill-design.md「スクリプトの検査」。
"""
import contextlib
import copy
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "post_design.py"
spec = importlib.util.spec_from_file_location("post_design", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def _design():
    return {
        "purpose": {"stated": "S", "inferred": "I"},
        "questions": [
            {
                "question": "Q",
                "derived_from": "D",
                "decision_impact": "X",
                "type": "empirical-descriptive",
                "disciplines": [{"name": "N", "reason": "R"}],
                "evidence": "E",
                "judgement": "J",
                "stopping_condition": "T",
                "brief": "B",
            }
        ],
        "discarded_questions": [{"question": "DQ", "reason": "DR"}],
        "cost_estimate": "C",
    }


EXPECTED = """## リサーチデザイン

### 目的

#### リーダーが言ったこと

S

#### Claude の推測

I

### 問いの一覧

#### Q1. Q

##### 目的のどこから導いたか

D

##### 答えによって判断がどう変わるか

X

##### 種類

empirical-descriptive

##### 何を証拠と数えるか

E

##### 判定の仕方

J

##### 停止条件

T

##### 関係する分野とその選定理由

- N: R

### 捨てた問いとその理由

- DQ: DR

### 調査役への指示書

<details>
<summary>Q1 の指示書</summary>

B

</details>

### 費用の見込み

C
"""


class FakeRun:
    def __init__(self, returncode=0):
        self.calls = []
        self.returncode = returncode

    def __call__(self, cmd, **kwargs):
        self.calls.append((cmd, kwargs))
        return SimpleNamespace(returncode=self.returncode)


class PostDesignTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def _write(self, design):
        path = os.path.join(self.tmp.name, "design.json")
        with open(path, "w", encoding="utf-8") as f:
            if isinstance(design, str):
                f.write(design)
            else:
                json.dump(design, f, ensure_ascii=False)
        return path

    def _main(self, design, *extra, run=None):
        run = run or FakeRun()
        out, err = io.StringIO(), io.StringIO()
        argv = [self._write(design), "--repo", "o/r", "--issue", "7", *extra]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = mod.main(argv, run=run)
        return code, run, out.getvalue(), err.getvalue()

    def test_complete_design_is_posted_once_as_rendered(self):
        code, run, _, _ = self._main(_design())
        self.assertEqual(code, 0)
        self.assertEqual(len(run.calls), 1)
        cmd, kwargs = run.calls[0]
        self.assertEqual(
            cmd, ["gh", "issue", "comment", "7", "--repo", "o/r", "--body-file", "-"]
        )
        self.assertEqual(kwargs["input"], EXPECTED)

    def test_render_has_the_fixed_shape(self):
        self.assertEqual(mod.render(_design()), EXPECTED)

    def test_missing_decision_impact_stops_without_posting(self):
        d = _design()
        del d["questions"][0]["decision_impact"]
        code, run, _, err = self._main(d)
        self.assertEqual(code, 1)
        self.assertEqual(run.calls, [])
        self.assertIn("questions[0].decision_impact", err)

    def test_every_missing_field_is_listed(self):
        d = _design()
        del d["purpose"]["stated"]
        del d["cost_estimate"]
        del d["questions"][0]["brief"]
        code, run, _, err = self._main(d)
        self.assertEqual(code, 1)
        self.assertEqual(run.calls, [])
        for path in ("purpose.stated", "cost_estimate", "questions[0].brief"):
            self.assertIn(path, err)

    def test_blank_and_non_string_values_count_as_missing(self):
        d = _design()
        d["questions"][0]["evidence"] = "   "
        d["questions"][0]["judgement"] = None
        d["questions"][0]["stopping_condition"] = 3
        self.assertEqual(
            mod.find_missing(d),
            [
                "questions[0].evidence",
                "questions[0].judgement",
                "questions[0].stopping_condition",
            ],
        )

    def test_empty_question_list_is_missing(self):
        d = _design()
        d["questions"] = []
        self.assertEqual(mod.find_missing(d), ["questions"])

    def test_discipline_without_reason_is_missing(self):
        d = _design()
        d["questions"][0]["disciplines"] = [{"name": "N"}]
        self.assertEqual(mod.find_missing(d), ["questions[0].disciplines[0].reason"])

    def test_conflict_handling_is_required_only_when_a_question_spans_disciplines(self):
        d = _design()
        self.assertEqual(mod.find_missing(d), [])
        d["questions"][0]["disciplines"].append({"name": "N2", "reason": "R2"})
        self.assertEqual(mod.find_missing(d), ["conflict_handling"])
        d["conflict_handling"] = "H"
        self.assertEqual(mod.find_missing(d), [])
        self.assertIn("### 分野どうしの対立の扱い\n\nH\n", mod.render(d))

    def test_no_discarded_questions_is_allowed_and_rendered_as_none(self):
        d = _design()
        d["discarded_questions"] = []
        self.assertEqual(mod.find_missing(d), [])
        self.assertIn("### 捨てた問いとその理由\n\nなし\n", mod.render(d))

    def test_discarded_questions_key_itself_is_required(self):
        d = _design()
        del d["discarded_questions"]
        self.assertEqual(mod.find_missing(d), ["discarded_questions"])

    def test_content_is_not_judged(self):
        # 種類の値が参照ファイルの名前に無くても止めない。中身の判定はスクリプトの責任外。
        d = _design()
        d["questions"][0]["type"] = "どれにも当てはまらない独自の種類"
        code, run, _, _ = self._main(d)
        self.assertEqual(code, 0)
        self.assertEqual(len(run.calls), 1)

    def test_multiline_values_keep_their_lines(self):
        d = _design()
        d["questions"][0]["brief"] = "- 一つ目\n- 二つ目"
        self.assertIn(
            "<summary>Q1 の指示書</summary>\n\n- 一つ目\n- 二つ目\n\n</details>",
            mod.render(d),
        )

    def test_questions_are_numbered_in_order(self):
        d = _design()
        second = copy.deepcopy(d["questions"][0])
        second["question"] = "Q2本文"
        d["questions"].append(second)
        body = mod.render(d)
        self.assertIn("#### Q2. Q2本文", body)
        self.assertIn("<summary>Q2 の指示書</summary>", body)

    def test_dry_run_prints_without_posting(self):
        code, run, out, _ = self._main(_design(), "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(run.calls, [])
        self.assertEqual(out, EXPECTED)

    def test_unreadable_json_exits_2_without_posting(self):
        code, run, _, err = self._main("{not json")
        self.assertEqual(code, 2)
        self.assertEqual(run.calls, [])
        self.assertIn("読めない", err)

    def test_non_object_top_level_is_reported_as_missing(self):
        code, run, _, _ = self._main([1, 2])
        self.assertEqual(code, 1)
        self.assertEqual(run.calls, [])

    def test_gh_failure_is_returned(self):
        code, _, _, _ = self._main(_design(), run=FakeRun(returncode=4))
        self.assertEqual(code, 4)


if __name__ == "__main__":
    unittest.main()
