#!/usr/bin/env python3
"""リサーチデザインの JSON を検査し、Markdown に整形して issue コメントとして投稿する。

中身の良し悪しは判定しない。必須の項目が欠けているときだけ、投稿せずに止まる
（spec: haoblackj/penguinEx の
docs/superpowers/specs/2026-10-09-research-design-skill-design.md「スクリプトの検査」）。

使い方:
    post_design.py <design.json> --repo <owner/name> --issue <番号> [--dry-run]

終了コード: 0 投稿した（--dry-run なら整形を標準出力へ出した）、1 必須の項目が欠けている、
2 入力を読めない、3 投稿に失敗した（gh を起動できない、または gh が 0 以外で終わった）。
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


def _one_line(value):
    """見出しと箇条書きは1行でしか成り立たないので、改行を含む空白の並びを空白1つにまとめる。"""
    return " ".join(value.split())


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
        out += [f"#### Q{n}. {_one_line(q['question'])}", ""]
        for key, label in QUESTION_FIELDS:
            out += [f"##### {label}", "", q[key].strip(), ""]
        out += ["##### 関係する分野とその選定理由", ""]
        for d in q["disciplines"]:
            out.append(f"- {_one_line(d['name'])}: {_one_line(d['reason'])}")
        out.append("")

    if not _blank(design.get("conflict_handling")):
        out += ["### 分野どうしの対立の扱い", "", design["conflict_handling"].strip(), ""]

    out += ["### 捨てた問いとその理由", ""]
    if design["discarded_questions"]:
        for d in design["discarded_questions"]:
            out.append(f"- {_one_line(d['question'])}: {_one_line(d['reason'])}")
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

    # gh は一般の失敗を 1 で返すので、そのまま返すと欠けの 1 と区別できない。投稿の失敗は 3 に揃える。
    try:
        result = run(
            ["gh", "issue", "comment", str(args.issue), "--repo", args.repo, "--body-file", "-"],
            input=body,
            text=True,
        )
    except OSError as e:
        print(f"投稿に失敗した（gh を起動できない）: {e}", file=sys.stderr)
        return 3
    if result.returncode != 0:
        print(
            f"投稿に失敗した（gh の終了コード {result.returncode}）。gh の出力を見て、"
            "issue の番号、リポジトリ、認証を確かめる。",
            file=sys.stderr,
        )
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
