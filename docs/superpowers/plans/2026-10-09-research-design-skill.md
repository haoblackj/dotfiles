# research-design スキル Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 調査の前にリサーチデザインを組み立てさせ、issue コメントでリーダーの承認を取るグローバルのスキル `research-design` を、dotfiles の `skills/research-design/` に置いて配る。

**Architecture:** `SKILL.md` は手順と関門だけを持ち、問いの種類ごとの知識は `references/` の8ファイルに分けて、判定した種類のものだけを読ませる。デザインはモデルが決まった項目の JSON に書き、`scripts/post_design.py`（標準ライブラリのみ）が必須の項目の欠けを検査し、Markdown に整形して `gh issue comment` で投稿する。手元へは `dot_claude/skills/symlink_research-design.tmpl` の symlink で、クラウドへは既存の `install-cloud.sh` の写しで配る。

**Tech Stack:** Markdown、Python 3（標準ライブラリ）、pytest 9、chezmoi

**Spec:** haoblackj/penguinEx の `docs/superpowers/specs/2026-10-09-research-design-skill-design.md`（承認済み、コミット 1eeefda）。置き場所と開発の流れは、このリポジトリの `docs/superpowers/specs/2026-10-09-self-made-skills-design.md`（dotfiles#48 の決定）。実装の issue は dotfiles#51。

## Global Constraints

- 作業はこのワークツリー（`.claude/worktrees/research-design-skill`、ブランチ `worktree-research-design-skill`）で行う。本チェックアウト（`~/.local/share/chezmoi`）は main に置いたままにする。
- `~/.claude/skills/` の下に実ディレクトリを作らない。`~/.local/share/claude-private` のチェックアウトに触れない。
- dotfiles は公開リポジトリである。スキル、参照ファイル、コミットメッセージ、issue と PR のコメントに、非公開リポジトリの中身（スキルを作るきっかけになった個別の依頼の経緯など）を書かない。spec へのリンクと、方法論の文献の内容は書いてよい。
- スクリプトは中身の良し悪しを判定しない。止めるのは、必須の項目の欠けと「答えによって判断がどう変わるか」の欠けだけ（spec「スクリプトの検査」）。
- スクリプトは Python の標準ライブラリだけで書く。
- 分野の下調べは `researcher` を haiku で走らせ、分野の候補を並べるところで止め、問いの答えを探させない（spec「範囲」「担い手と費用」）。
- 参照ファイルに写す引用と数値は、書く者が出典を自分で取得して逐語で照合する。サブエージェントの報告や penguinEx#97 の要約から、照合せずに写さない。照合できなかったものは、参照ファイルに「未照合」または「未確認」と明記する。
- ファイルの編集は Read / Edit / Write で行う。sed や python のワンライナーで書き換えない。
- コミットはパスを名指しする。既存ファイルは `git commit -- <パス>`、新規ファイルは `git add -N -- <パス>` を1ファイルずつ打ってから `git commit -- <パス>`。`git commit -a` と裸の `git commit` は使わない。
- PR はマージコミットで取り込む（スカッシュを推さない）。
- コミットメッセージの末尾に次の2行を付ける。
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EaMXJu4cQq7cQwJ8tbidCD`

## Review Focus

- 複数行の値（指示書の箇条書きなど）を入れたとき、整形で行が潰れず、`<details>` の中で Markdown として表示されること（Task 1 の `test_multiline_values_keep_their_lines`）。
- 空白だけの文字列、`null`、数値が入った項目を、埋まっているとみなさないこと（Task 1 の `test_blank_and_non_string_values_count_as_missing`）。
- `gh` の投稿が失敗したとき、スクリプトが 0 で終わって投稿済みと誤認させないこと（Task 1 の `test_gh_failure_is_returned`）。
- 分野の下調べが問いの答えを探し始めないこと。`SKILL.md` の下調べの指示に禁止を明記し（Task 3）、`--plugin-dir` の試しで下調べへの指示の文面を確かめる（Task 4）。
- 作業ディレクトリが GitHub のリポジトリでないとき、勝手に issue の置き場を決めず、リーダーに聞くこと（Task 3 の `SKILL.md` の「1. 置き場の確定」）。

---

### Task 1: `post_design.py` とそのテスト

**Files:**
- Create: `skills/research-design/scripts/post_design.py`
- Create: `skills/research-design/tests/test_post_design.py`
- Modify: `pyproject.toml`（`testpaths`）
- Modify: `dot_claude/hooks/tests/test_pytest_config.py:19-20`（`EXPECTED_TESTPATHS` とその上のコメント）、`:61`（テスト名）

テストの置き場は、既存の `dot_claude/hooks/tests/` と同じく、対象のコードの隣にする。
スキルのディレクトリごと `~/.claude/skills/` とクラウドへ配られるので、テストも一緒に届くが、読まれるのは `SKILL.md` と、そこから名指しされたファイルだけなので害は無い。

**Interfaces:**
- Consumes: なし
- Produces:
  - コマンド `python3 <スキルのディレクトリ>/scripts/post_design.py <design.json> --repo <owner/name> --issue <番号> [--dry-run]`。
  - 終了コード: 0 投稿した（`--dry-run` なら整形を標準出力へ出した）、1 必須の項目が欠けている（欠けたパスを標準エラーへ列挙）、2 JSON を読めない、それ以外は `gh` の終了コード。
  - デザインの JSON の形（Task 3 の `SKILL.md` がこの形をモデルに示す）:

```json
{
  "purpose": {"stated": "リーダーが言ったこと", "inferred": "Claude の推測"},
  "questions": [
    {
      "question": "問い",
      "derived_from": "目的のどこから導いたか",
      "decision_impact": "答えによって判断がどう変わるか",
      "type": "empirical-descriptive",
      "disciplines": [{"name": "分野", "reason": "選んだ理由"}],
      "evidence": "何を証拠と数えるか",
      "judgement": "判定の仕方",
      "stopping_condition": "停止条件",
      "brief": "調査役への指示書（Markdown）"
    }
  ],
  "conflict_handling": "分野どうしの対立の扱い（分野を2つ以上持つ問いがあるときだけ必須）",
  "discarded_questions": [{"question": "捨てた問い", "reason": "捨てた理由"}],
  "cost_estimate": "調査役を何本、どのモデルで走らせるか"
}
```

  - 必須: `purpose.stated`、`purpose.inferred`、空でない `questions`、問いごとの `question` `derived_from` `decision_impact` `type` `evidence` `judgement` `stopping_condition` `brief` と空でない `disciplines`（各要素の `name` `reason`）、`discarded_questions` のキー（空のリストは可、要素があれば `question` `reason`）、`cost_estimate`。値は空白でない文字列でなければ欠けとみなす。
  - `type` の値は検査しない（中身の判定はしない）。

- [ ] **Step 1: 失敗するテストを書く**

`skills/research-design/tests/test_post_design.py` を次の内容で作る。

```python
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
```

- [ ] **Step 2: テストが失敗することを確かめる**

確かめること: `skills/research-design/tests/` を対象に pytest を走らせ、`post_design.py` が無いために収集の段で失敗すること。

- [ ] **Step 3: `post_design.py` を書く**

`skills/research-design/scripts/post_design.py` を次の内容で作り、実行ビットを立てる（`git update-index --chmod=+x` ではなく、ファイルの属性として `chmod +x`）。

```python
#!/usr/bin/env python3
"""リサーチデザインの JSON を検査し、Markdown に整形して issue コメントとして投稿する。

中身の良し悪しは判定しない。必須の項目が欠けているときだけ、投稿せずに止まる
（spec: haoblackj/penguinEx の
docs/superpowers/specs/2026-10-09-research-design-skill-design.md「スクリプトの検査」）。

使い方:
    post_design.py <design.json> --repo <owner/name> --issue <番号> [--dry-run]

終了コード: 0 投稿した（--dry-run なら整形を標準出力へ出した）、1 必須の項目が欠けている、
2 入力を読めない、それ以外は gh の終了コードをそのまま返す。
"""
import argparse
import json
import subprocess
import sys

# (JSON のキー, コメントでの見出し)。並びがコメントでの並びになる。
QUESTION_FIELDS = [
    ("derived_from", "目的のどこから導いたか"),
    ("decision_impact", "答えによって判断がどう変わるか"),
    ("type", "種類"),
    ("evidence", "何を証拠と数えるか"),
    ("judgement", "判定の仕方"),
    ("stopping_condition", "停止条件"),
]


def _blank(value):
    return not isinstance(value, str) or not value.strip()


def find_missing(design):
    """欠けている項目のパスを、見つけた順に返す。空の文字列と文字列でない値も欠けとみなす。"""
    if not isinstance(design, dict):
        return ["(最上位がオブジェクトでない)"]
    missing = []

    purpose = design.get("purpose")
    if not isinstance(purpose, dict):
        missing.append("purpose")
    else:
        for key in ("stated", "inferred"):
            if _blank(purpose.get(key)):
                missing.append(f"purpose.{key}")

    questions = design.get("questions")
    if not isinstance(questions, list) or not questions:
        missing.append("questions")
        questions = []
    spans_disciplines = False
    for i, q in enumerate(questions):
        path = f"questions[{i}]"
        if not isinstance(q, dict):
            missing.append(path)
            continue
        for key in ["question"] + [k for k, _ in QUESTION_FIELDS] + ["brief"]:
            if _blank(q.get(key)):
                missing.append(f"{path}.{key}")
        disciplines = q.get("disciplines")
        if not isinstance(disciplines, list) or not disciplines:
            missing.append(f"{path}.disciplines")
            continue
        if len(disciplines) >= 2:
            spans_disciplines = True
        for j, d in enumerate(disciplines):
            for key in ("name", "reason"):
                if not isinstance(d, dict) or _blank(d.get(key)):
                    missing.append(f"{path}.disciplines[{j}].{key}")

    # 分野どうしの対立の扱いは、複数の分野にまたがる問いがあるときだけ要る。
    if spans_disciplines and _blank(design.get("conflict_handling")):
        missing.append("conflict_handling")

    # 捨てた問いが無いことはありうるので、空のリストは欠けとみなさない。
    discarded = design.get("discarded_questions")
    if not isinstance(discarded, list):
        missing.append("discarded_questions")
    else:
        for j, d in enumerate(discarded):
            for key in ("question", "reason"):
                if not isinstance(d, dict) or _blank(d.get(key)):
                    missing.append(f"discarded_questions[{j}].{key}")

    if _blank(design.get("cost_estimate")):
        missing.append("cost_estimate")
    return missing


def render(design):
    """検査を通った design を Markdown にする。"""
    out = ["## リサーチデザイン", ""]

    out += ["### 目的", ""]
    out += ["#### リーダーが言ったこと", "", design["purpose"]["stated"].strip(), ""]
    out += ["#### Claude の推測", "", design["purpose"]["inferred"].strip(), ""]

    out += ["### 問いの一覧", ""]
    for n, q in enumerate(design["questions"], 1):
        out += [f"#### Q{n}. {q['question'].strip()}", ""]
        for key, label in QUESTION_FIELDS:
            out += [f"##### {label}", "", q[key].strip(), ""]
        out += ["##### 関係する分野とその選定理由", ""]
        for d in q["disciplines"]:
            out.append(f"- {d['name'].strip()}: {d['reason'].strip()}")
        out.append("")

    if not _blank(design.get("conflict_handling")):
        out += ["### 分野どうしの対立の扱い", "", design["conflict_handling"].strip(), ""]

    out += ["### 捨てた問いとその理由", ""]
    if design["discarded_questions"]:
        for d in design["discarded_questions"]:
            out.append(f"- {d['question'].strip()}: {d['reason'].strip()}")
    else:
        out.append("なし")
    out.append("")

    out += ["### 調査役への指示書", ""]
    for n, q in enumerate(design["questions"], 1):
        # <details> の中で Markdown を効かせるには、summary の後に空行が要る。
        out += [
            "<details>",
            f"<summary>Q{n} の指示書</summary>",
            "",
            q["brief"].strip(),
            "",
            "</details>",
            "",
        ]

    out += ["### 費用の見込み", "", design["cost_estimate"].strip(), ""]
    return "\n".join(out)


def main(argv=None, run=subprocess.run):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("design", help="デザインの JSON ファイル")
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--issue", required=True, type=int, help="issue の番号")
    parser.add_argument("--dry-run", action="store_true", help="投稿せずに整形の結果を出す")
    args = parser.parse_args(argv)

    try:
        with open(args.design, encoding="utf-8") as f:
            design = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"デザインの JSON を読めない: {e}", file=sys.stderr)
        return 2

    missing = find_missing(design)
    if missing:
        print("必須の項目が欠けているので投稿しない:", file=sys.stderr)
        for m in missing:
            print(f"  - {m}", file=sys.stderr)
        return 1

    body = render(design)
    if args.dry_run:
        sys.stdout.write(body)
        return 0

    result = run(
        ["gh", "issue", "comment", str(args.issue), "--repo", args.repo, "--body-file", "-"],
        input=body,
        text=True,
    )
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
```

このコードとテストは、プランを書く時点で scratchpad で走らせ、17件が通ることを確かめてある（リポジトリの pytest の設定ではまだ走らせていない）。

- [ ] **Step 4: pytest の設定にテストのディレクトリを足す**

`pyproject.toml` の `testpaths` を次にする。

```toml
testpaths = ["dot_claude/hooks/tests", "skills/research-design/tests"]
```

`dot_claude/hooks/tests/test_pytest_config.py` の期待値を合わせる。このテストは「期待値を設定から読み直さない」方針なので、両方を書き換える。

```python
# このリポジトリのテストは、対象のコードの隣のディレクトリに置く。
EXPECTED_TESTPATHS = ["dot_claude/hooks/tests", "skills/research-design/tests"]
```

テスト名 `test_testpaths_points_at_the_single_test_directory` を `test_testpaths_lists_the_test_directories` に変える。
`pyproject.toml` の `pythonpath` を置かない旨のコメント（「このリポジトリのテスト2本は」）は、新しいテストも importlib で読むので、本数の記述だけを実態に合わせる。

- [ ] **Step 5: テストが通ることを確かめる**

確かめること:
- リポジトリのルートで pytest（pre-push のフックと同じ `-p no:cacheprovider`）を走らせ、既存の100件と新しい17件がすべて通ること。
- `skills/research-design/` の下に `__pycache__` ができても、`git status --short` に出ないこと（`.gitignore` の `__pycache__/` で隠れる）。

- [ ] **Step 6: コミットする**

```bash
git add -N -- skills/research-design/scripts/post_design.py
git add -N -- skills/research-design/tests/test_post_design.py
git commit -- skills/research-design/scripts/post_design.py skills/research-design/tests/test_post_design.py pyproject.toml dot_claude/hooks/tests/test_pytest_config.py
```

メッセージは `feat(research-design): デザインの JSON を検査して issue へ投稿するスクリプト` とし、末尾に Global Constraints の2行を付ける。

---

### Task 2: 未確認の出典の裏取り

参照ファイル（Task 3）を書く前に、spec が未確認とした出典の裏を取る。
結果は dotfiles#51 にコメントとして書き、Task 3 はそのコメントだけを根拠にする。

**Files:** なし（結果は dotfiles#51 のコメント）

**Interfaces:**
- Consumes: なし
- Produces: dotfiles#51 の「出典の裏取り」コメント。主張ごとに、照合済み（出典の URL と、照合した原文の短い引用）、未照合（読めた要約の出どころ）、未確認（原文にも要約にもたどり着けない）のどれかを書く。

裏を取る主張:

| 記号 | 主張 | 使う参照ファイル |
|---|---|---|
| A | de Vaus『Research Design in Social Research』は、社会調査を記述（descriptive）と説明（explanatory）の2種に分ける | `empirical-descriptive.md`、`empirical-causal.md` |
| B | Malhotra『Marketing Research』は、経営上の意思決定問題（management decision problem）を行動志向、マーケティングリサーチ問題（marketing research problem）を情報志向とする | `purpose-to-question.md` |
| C | Repko は、関係しうる分野を「その研究対象に、問題や問いにかかわる現象を少なくとも一つ含む分野」と定義し、分野をしばしば3つか4つに絞る | `interdisciplinary.md` |
| D | 分野を絞る基準「問題に直接つながる、研究の蓄積がある、有力な理論がある」（spec の流れの5。出どころが penguinEx#97 の調査結果に無い） | `interdisciplinary.md` |
| E | Repko の段階のうち、関係する分野の特定、洞察の対立の特定、共通の土台の作成の、本文での説明 | `interdisciplinary.md` |
| F | Alvesson & Sandberg (2011) の、前提を崩して問いを作る段階（problematization）の中身 | `purpose-to-question.md` |

- [ ] **Step 1: 原文の在りかを探させる**

`researcher` サブエージェント（既定の sonnet）に、A から F の原文を読める場所（出版社の見本の章、著者のサイトの PDF、Google Books のプレビュー、原文を引用している大学の講義資料）を探させる。
指示に含めること: 主張の真偽を判定させない。見つけた URL と、主張に当たる箇所の原文を逐語で返させる。読めなかった場所も、読めなかった理由とともに返させる。

- [ ] **Step 2: 自分で取得して逐語で照合する**

サブエージェントが返した URL を、メインのセッションが WebFetch で取得し、返された原文と逐語で照合する。
サブエージェントの報告にある引用と数値は誤ることがあるので、照合できなかったものは照合済みに数えない。

- [ ] **Step 3: dotfiles#51 にコメントを書く**

見出しは `## 出典の裏取り` とし、上の表の記号ごとに、照合済み、未照合、未確認のどれかと根拠を書く。
D が見つからなかったときは、`interdisciplinary.md` の絞り込みの基準を、照合できた C と E の範囲で書き直すことと、spec と食い違うことをコメントに書く。spec の書き換えは penguinEx 側の承認が要るので、このプランでは行わない。

---

### Task 3: 参照ファイル、`SKILL.md`、symlink テンプレート

**Files:**
- Create: `skills/research-design/SKILL.md`
- Create: `skills/research-design/references/purpose-to-question.md`
- Create: `skills/research-design/references/interdisciplinary.md`
- Create: `skills/research-design/references/empirical-descriptive.md`
- Create: `skills/research-design/references/empirical-causal.md`
- Create: `skills/research-design/references/normative.md`
- Create: `skills/research-design/references/conceptual.md`
- Create: `skills/research-design/references/interpretive.md`
- Create: `skills/research-design/references/unclassified.md`
- Create: `dot_claude/skills/symlink_research-design.tmpl`

**Interfaces:**
- Consumes: Task 1 のコマンドと JSON の形。Task 2 の dotfiles#51 のコメント。
- Produces: `~/.claude/skills/research-design/SKILL.md`（マージと apply の後）として読まれるスキル。

- [ ] **Step 1: 参照ファイルを書く**

8ファイルとも、次の見出しで書く（`unclassified.md` は「何を証拠と数えるか」と「判定の仕方」を持たない）。

```markdown
# <種類または段の名前>

## いつ読むか
## 設計の型
## 何を証拠と数えるか
## 判定の仕方
## 出典
```

「出典」には、項目ごとに URL と照合の状態（照合済み、未照合、未確認）を書く。
引用を載せるときは、書く時点で出典を取得して逐語で照合する（penguinEx#97 で照合済みとされたものも、このリポジトリへ写す前に取り直す）。

各ファイルに載せる中身:

- `purpose-to-question.md`: Booth ほか『The Craft of Research』の、実践上の問題と概念上の問題の区別と、どちらも「条件」と「その条件が生む望ましくない帰結」の二部構造を持つこと。"Solving a practical problem usually requires that we first solve a research problem"（https://roosevelt.ucsd.edu/_files/mmw/mmw121/from-topics-to-questions-mmw121-fa14.pdf ）。市場調査の意思決定問題から調査問題への落とし方（Task 2 の B）。別の導き方として、Alvesson & Sandberg (2011) の problematization（Task 2 の F）と、これが依頼者の目的から問いを導く手順ではなく理論的な貢献のための手順であること。問いを捨てる判定（どう答えが出ても判断が変わらない問いは捨てる）。
- `interdisciplinary.md`: Repko の段階のうち、関係する分野の特定（Task 2 の C、D）、洞察の対立の特定、共通の土台による統合（Task 2 の E）。Repko (2007) "Integrationists substantially agree that creating common ground is essential to achieving integration"（https://interdisciplinarystudies.org/wp-content/issues/vol25_2007/03_Vol_25_pp_1_31.pdf ）。統合の位置づけ自体に合意が無いこと（同じ論文の要旨）。下調べを haiku の `researcher` に頼むときの指示の型（分野の候補と根拠の URL を並べるところで止め、問いの答えを探さない）。
- `empirical-descriptive.md`: 何が起きているかを問う。記述の設計（Task 2 の A）。証拠は観測、統計、一次資料の記録。判定は、標本や出典の代表性と、数え方の定義が問いに合っているか。
- `empirical-causal.md`: なぜ起きるか、効くかを問う。介入の効果の問いは PICO で定式化する（PICO は介入の効果の問い専用の型で、一般の定式化ではない。Cochrane Handbook 第2章 https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-02 ）。GRADE の出発点（ランダム化比較試験の証拠は高い確実性から、非ランダム化の研究は低い確実性から始まる）と、格下げの5領域（Cochrane Handbook 第14章 https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-14 ）。
- `normative.md`: どうすべきかを問う。反照的均衡（SEP の Reflective Equilibrium の項）。証拠は原則、個別の判断、背景の理論。判定は整合性と、反例となる個別の判断への耐性。証拠の階層は無い。
- `conceptual.md`: それは何かを問う。概念分析（SEP の Analysis の項。必要十分条件の特定がもはや主目的とは見なされないこと）。判定は反例による検証。
- `interpretive.md`: テキストや資料が何を意味するかを問う。法解釈では、どの解釈の方法が正しいかは解釈が何を求めるかに依存すること（SEP の Legal Interpretation の項）、方法ごとに証拠の種類（テキスト、立法者の意図、目的）が違うこと。人文の一次資料の解釈もここに入る。
- `unclassified.md`: どの種類にも当てはまらないときに読む。むりに当てはめず、当てはまらないことをデザインの `type` に書き、関門2 でリーダーに相談する。理由は見せかけの厳密さを避けるため。理論物理や数学寄りの問いは当面ここに落とす。実証、規範、概念を一つの分類に並べた教科書は見つかっておらず、この分類は Creswell や de Vaus の実証の分類と、哲学と法学の方法論を組み合わせたものであることも書く。

SEP の各項の URL と引用は、書く時点で SEP を取得して確かめる。

- [ ] **Step 2: `SKILL.md` を書く**

`skills/research-design/SKILL.md` を次の内容で作る。

````markdown
---
name: research-design
description: issue を立てて調べるに値する調査を頼まれたとき、調査に入る前に使う。依頼から目的を言い直してリーダーに確かめ、目的から研究の問いを導き、問いの種類ごとに証拠の基準と停止条件を決めて、リサーチデザインを issue コメントに投稿し、リーダーの承認で止まる。調査の実行は範囲外。issue を立てるに値しない小さな調べものには使わない。
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/scripts/post_design.py *)
---

# Research Design

## これは何のためか

調べる前に、何を問い、なぜその問いなのか、何を証拠と数え、どう判定するかを組み立てる。
間違った問いで集めた正しい情報は、判断の役に立たない。
問いを思いつきで並べず、目的から導いた筋道と根拠を問いごとに残す。

このスキルの責任は、デザインを作ってリーダーの承認を得たところ（関門2）で終わる。
調査の実行は範囲外である。

## 使わない場面

- issue を立てるに値しない小さな調べもの。
- 承認済みのデザインがあり、その指示書に従って調べるだけのとき。

## 範囲の線

内側は、問いを設計するための下調べで、どの分野がその現象を研究対象にしているかを並べるところまで。
外側は、問いに答えるための調査で、文献を読み、証拠を集め、判定すること。
下調べは分野の候補を並べるところで止め、問いの答えを探さない。
承認前の問いで集めた情報が、承認後の調査に混ざるのを防ぐためである。

## 手順

### 1. 置き場の確定

依頼のタスクに対応する issue を、そのリポジトリで探す。
あれば、そこへデザインを投稿する。
無ければ、そのリポジトリに issue を新しく立てる（確認は取らない）。
作業ディレクトリが GitHub のリポジトリでないときは、どこへ立てるかをリーダーに聞く。

### 2. 目的の言い直し（関門1）

`references/purpose-to-question.md` を読む。

依頼を二部構造で言い直す。
実践上の問題なら「何が起きていて、それで何が困るか」。
理解したいことなら「何が分かっていなくて、それで何が困るか」。
リーダーが言ったことと、自分の推測を分けて書く。

ここで必ず止まり、リーダーに確かめてもらう。確かめが取れるまで次へ進まない。
言い直しが2回退けられたら、3回目は言い直しを出さない。一問ずつ聞き出す面接に切り替える。

### 3. 問いの導出

確かめた目的から、答えるべき研究の問いを導く。
問いごとに、目的のどの部分に効くか（`derived_from`）と、答えによって判断がどう変わるか（`decision_impact`）を書く。
どう答えが出ても判断が変わらない問いは捨て、捨てた理由を `discarded_questions` に残す。

### 4. 種類の判定と振り分け

問いごとに種類を判定し、その種類の参照ファイルだけを読む。全種類のファイルを読まない。

| 種類（`type` に書く値） | 問いの形 | 読むファイル |
|---|---|---|
| `empirical-descriptive` | 何が起きているか | `references/empirical-descriptive.md` |
| `empirical-causal` | なぜ起きるか、効くか | `references/empirical-causal.md` |
| `normative` | どうすべきか | `references/normative.md` |
| `conceptual` | それは何か | `references/conceptual.md` |
| `interpretive` | テキストや資料が何を意味するか | `references/interpretive.md` |
| `unclassified` | どれにも当てはまらない | `references/unclassified.md` |

むりに当てはめない。迷ったら `unclassified` にして、関門2 で相談する。

### 5. 分野の特定

一つの問いが複数の分野の研究対象にまたがるときだけ、この段を踏む。
`references/interdisciplinary.md` を読む。

候補の分野の下調べは、Agent ツールで `subagent_type` を `researcher`、`model` を `haiku` にして頼む。
下調べへの指示には、次の3点を必ず書く。

- その現象を研究対象にしている分野の候補と、根拠の URL を並べるところで止める。
- 問いの答えを探さない。文献の中身を要約しない。
- 候補ごとに、その分野がその現象を扱っているとした根拠を一文で添える。

候補から、`interdisciplinary.md` の基準で数分野に絞り、理由を `disciplines[].reason` に書く。
分野どうしで知見が対立したときの扱いを決め、`conflict_handling` に書く。

一つの分野で足りる問いでは、下調べを走らせない。その分野と選んだ理由だけを書く。

### 6. 証拠の基準と停止条件

問いごとに、種類の参照ファイルに沿って、何を証拠と数えるか（`evidence`）、どう判定するか（`judgement`）、どこで調べるのをやめるか（`stopping_condition`）を書く。

### 7. 調査役への指示書

問いごとに、承認後に走らせる調査役（`researcher` サブエージェント）への指示書を `brief` に書く。
中身は、問い、証拠の基準、停止条件、返し方。
返し方には、次を含める。

- 結論と、結論を支える引用や数値に、出典の URL と原文の箇所を添えて返す。
- 受け取ったメインのセッションは、引用と数値を出典で取得して逐語で照合してから文書へ写す。照合できなかったものは未照合と明記する。

調査役の既定は `researcher` の既定のモデル（sonnet）である。
高いモデルが要る問いは、その理由を指示書と `cost_estimate` に書き、承認の中で見せる。

### 8. デザインの提示（関門2）

デザインを次の形の JSON に書き、scratchpad に保存する。

```json
{
  "purpose": {"stated": "リーダーが言ったこと", "inferred": "推測"},
  "questions": [
    {
      "question": "問い",
      "derived_from": "目的のどこから導いたか",
      "decision_impact": "答えによって判断がどう変わるか",
      "type": "empirical-descriptive",
      "disciplines": [{"name": "分野", "reason": "選んだ理由"}],
      "evidence": "何を証拠と数えるか",
      "judgement": "判定の仕方",
      "stopping_condition": "停止条件",
      "brief": "調査役への指示書（Markdown）"
    }
  ],
  "conflict_handling": "分野どうしの対立の扱い（分野を2つ以上持つ問いがあるときだけ）",
  "discarded_questions": [{"question": "捨てた問い", "reason": "捨てた理由"}],
  "cost_estimate": "調査役を何本、どのモデルで走らせるか"
}
```

推測が無いときは `inferred` に「なし」と書く。捨てた問いが無いときは `discarded_questions` を空のリストにする。

次のコマンドで投稿する。

```
python3 ${CLAUDE_SKILL_DIR}/scripts/post_design.py <design.json> --repo <owner/name> --issue <番号>
```

終了コードが 1 なら、標準エラーに並んだ欠けた項目を埋めて、もう一度走らせる。
整形の結果を投稿の前に見たいときは `--dry-run` を付ける。

投稿したら、リーダーの承認で止まる。
直しを求められたら、JSON を直して投稿し直す。

### 9. 渡し（このスキルの範囲外）

承認の後、メインのセッションが、承認された指示書に従って調査役に命令し、結果を同じ issue に積む。
このスキルはここを扱わない。

## 費用

- 参照ファイルは、判定した種類のものと、手順の段で名指ししたものだけを読む。
- 段ごとにサブエージェントを分けない。呼び出しのたびに文脈を読み直すので、デザインを作るだけの仕事に費用が数倍かかる。
- 分野の下調べのように、候補と根拠を並べるだけの仕事は haiku に頼む。判断は自分で持つ。
````

- [ ] **Step 3: symlink テンプレートを書く**

`dot_claude/skills/symlink_research-design.tmpl` を次の1行で作る（`dot_claude/symlink_settings.json.tmpl` と同じ型）。

```
{{ .chezmoi.sourceDir }}/skills/research-design
```

- [ ] **Step 4: 公開してよい中身かを確かめる**

確かめること:
- `skills/research-design/` の下と symlink テンプレートに、非公開リポジトリの名前と、その中身（個別の依頼の経緯）が書かれていないこと（`AZ-104`、`claude-private`、`penguinEx#97` を grep して出ないこと。spec のリンクとしての `penguinEx` の名前は、SKILL.md と参照ファイルには書かない）。
- 参照ファイルの引用のすべてに、照合の状態が付いていること。

- [ ] **Step 5: コミットする**

新規ファイルを1ファイルずつ `git add -N -- <パス>` し、10ファイルを名指しして `git commit -- <パス>...` でコミットする。
メッセージは `feat(research-design): 手順と参照ファイルと配布の symlink` とし、末尾に Global Constraints の2行を付ける。

---

### Task 4: `--plugin-dir` での読み込みの確認と PR

**Files:** なし（確認の結果は PR の説明に書く）

**Interfaces:**
- Consumes: Task 1 から Task 3 のコミット。
- Produces: PR（base は main）。

架空の依頼でデザインを作らせる評価はしない（spec「確かめ方」）。ここで確かめるのは、スキルが読まれることと、スクリプトのパスが展開されることだけ。

- [ ] **Step 1: 別のセッションで読み込みを確かめる**

グローバルの CLAUDE.md の「対話セッションでの実機検証」に従い、Herdr のタブで `claude --plugin-dir <このワークツリーのルート>` のセッションを立てる。
確かめること:
- スキルの一覧に `<プラグイン名>:research-design` が出ること（プラグイン名が何になるかもここで記録する）。
- そのセッションに「research-design スキルの SKILL.md を読み、手順8 のコマンドのスクリプトのパスを表示して、そのスクリプトに `--help` を付けて走らせて」と頼み、`${CLAUDE_SKILL_DIR}` がワークツリーの `skills/research-design` に展開され、`--help` が使い方を出すこと。
- 手順5 の下調べへの指示の3点が、そのセッションが読んだ SKILL.md にそのまま載っていること。
- 終わったら、自分で立てたタブを閉じる。

- [ ] **Step 2: 全件のテストを走らせる**

確かめること: pre-push のフックと同じ pytest と bats がすべて通ること（push の時点でフックが走る）。

- [ ] **Step 3: push して PR を出す**

PR の説明に書くこと: 何を足したか、Task 2 の裏取りの結果（dotfiles#51 のコメントへのリンク）、Task 4 Step 1 の確認の結果、マージ後に行うこと（Task 5）。末尾に `🤖 Generated with [Claude Code](https://claude.com/claude-code)` とセッションの URL を付ける。
dotfiles#51 に PR へのリンクを状態コメントで書き、ラベルを `status:承認待ち` にする。

---

### Task 5: マージ後の反映と、クラウドでの確認

リーダーが PR をマージした後に行う。

**Files:**
- 読まれなかったときだけ Modify: `install-cloud.sh`、`install-cloud.bats`、`README.md`（別の PR）

- [ ] **Step 1: 本チェックアウトへ反映する**

本チェックアウトで `git pull` と `chezmoi apply` を行う。
確かめること:
- `~/.claude/skills/research-design` が、本チェックアウトの `skills/research-design` への symlink であること。
- 同期フックの push を走らせた後も、claude-private にこのスキルが吸い込まれていないこと。
- 新しいセッションでスキルの一覧に `research-design` が出ること。

ワークツリーは、マージ後に `git worktree remove` で外す（ワークツリーに残った古い `.chezmoitemplates` を chezmoi が拾うのを避ける）。

- [ ] **Step 2: クラウドのセッションで読まれるかを確かめる（dotfiles#48 の残件）**

クラウドの環境の Setup script はスナップショットとして最長で約7日キャッシュされるので、Setup script のコメント（`# rev <日付>`）を書き換えて作り直させる。これは claude.ai の環境の設定画面での操作で、自動化できないのでリーダーに頼む。
その後、クラウドのセッションを開き、確かめる。
- Setup script のログに `[install-cloud] 配置: ~/.claude/skills/research-design` が出ること。
- そのセッションのスキルの一覧に `research-design` が出ること。

クラウドのセッションの立て方（リーダーが claude.ai/code で開くか、こちらから一回きりのルーチンで立てるか）は、この時点で選び、結果とともに記録する。

- [ ] **Step 3: 結果を書く**

- dotfiles#48 に、クラウドで読まれたかどうかと、確かめた方法をコメントする。
  - 読まれた: README の「クラウドで配るもの」の表の `skills/` の行から「クラウドで読まれるかは最初のスキルで確かめる」を外す変更を、別の PR で出す。#48 を閉じる。
  - 読まれなかった: spec のとおり、`install-cloud.sh` の写す処理を外し、クラウドでは使えないことを README に書く変更を、別の PR で出す。
- dotfiles#51 に `## 状態` コメント（済んだこと、決定、次の一手）を書き、一つ前の状態コメントをたたむ。issue を閉じる。
- penguinEx#97 に、スキルが使えるようになったことをコメントする。受け入れの試験は penguinEx 側とリーダーが持つことも書く。

---

## 実行の担い手

着手の時点の利用枠のフックの知らせに従う。offload なら Task 1 の編集を `~/.codex/codex-delegate.sh` へ渡し、全件テスト、コミット、レビュー、PR は Claude が持つ。
Task 2 と Task 3 は、照合した出典をそのまま参照ファイルへ写す仕事で、照合の結果を持つ側が書くほうが渡し直しが無いので、Claude が持つ。
