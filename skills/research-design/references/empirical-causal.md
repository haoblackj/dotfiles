# 実証の因果、介入の効果（empirical-causal）

## いつ読むか

問いが「なぜ起きるか」「それは効くか」を問うとき。
原因と結果の関係や、ある介入（手段、施策、設定の変更）が結果を変えるかを確かめたいときに読む。
何が起きているかを数えるだけなら `empirical-descriptive.md` を読む。

## 設計の型

介入の効果の問いは、PICO の4つの要素で定式化する。
P は対象（Population）、I は介入（Intervention）、C は比べる相手（Comparison）、O は結果（Outcome）。
Cochrane Handbook は、レビューの目的を「[介入] が [健康上の問題] に [対象と状況] でどう効くかを評価する」という一文の形で書くことを勧めている。

PICO は Cochrane の介入のレビューで使う型で、問い一般の定式化ではない。
介入が無い因果の問い（なぜ起きたか）では、原因の候補と、その候補が結果を生む機構を問いに書く。

## 何を証拠と数えるか

比較のある研究の結果を証拠と数える。
ランダム化比較試験と、ランダム化していない研究（観察研究など）は、出発点の確実性が違う。
GRADE では、ランダム化比較試験の証拠は高い確実性から、ランダム化していない研究の証拠は低い確実性から評価を始める。
ランダム化していない研究が低く始まるのは、ランダム化が無いことで交絡と選択の偏りが入りうるためである。

個別の事例や体験談は、効果の証拠としては弱い。
仕組みの説明（なぜ効くはずか）は、効果があることの証拠ではない。

## 判定の仕方

GRADE は、証拠の確実性を高い、中程度、低い、非常に低いの4段階で評価し、次の5つの領域で下げる。

- 偏りのリスク（risk of bias）
- 結果の不一致（inconsistency）
- 非直接性（indirectness）。研究の対象や介入が、問いのものと違う。
- 不精確さ（imprecision）
- 出版の偏り（publication bias）

介入の効果の問いでは、「効いた」「効かなかった」だけでなく、その結論の確実性をこの段階で書く。
停止条件は、問いに直接答える比較の研究が見つかり確実性を評価できたとき、または探す範囲（データベース、期間、言語）を探し尽くしたときに置く。

## 出典

- Cochrane Handbook 第2章（目的の一文の形、PICO）: https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-02 。照合済み（2026-10-09）: "Where possible the style should be of the form 'To assess the effects of [intervention or comparison] for [health problem] in [types of people, disease or problem and setting if specified]'"、"the 'PICO' mnemonic, an acronym for Population, Intervention, Comparison(s) and Outcome"。
- Cochrane Handbook 第14章（GRADE）: https://www.cochrane.org/authors/handbooks-and-manuals/handbook/current/chapter-14 。照合済み（2026-10-09）: "In GRADE, a body of evidence from randomized trials begins with a high-certainty rating while a body of evidence from NRSI begins with a low-certainty rating. The lower rating with NRSI is the result of the potential bias induced by the lack of randomization (i.e. confounding and selection bias)."、"GRADE assessments of certainty are determined through consideration of five domains: risk of bias, inconsistency, indirectness, imprecision and publication bias."
- 「PICO は問い一般の定式化ではない」は、第2章が介入のレビューの問いの型として PICO を挙げていることからの、このスキルの読みである。
