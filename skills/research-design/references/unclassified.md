# どの種類にも当てはまらないとき（unclassified）

## いつ読むか

手順の4で、問いが実証の記述、実証の因果、規範、概念、解釈のどれにも当てはまらないとき、または当てはまるか迷ったときに読む。

## 設計の型

むりに当てはめない。
当てはまらないことをデザインに書き、関門2 でリーダーに相談する。
型に押し込むと、その型の証拠の基準と判定の仕方が、問いに合わないまま厳密そうに見えてしまう（見せかけの厳密さ）。

デザインには次を書く。

- `type`: `unclassified` と、近い種類があればその名前と、当てはまらない点
- `evidence` と `judgement`: 仮の案と、それが仮であること
- `stopping_condition`: 仮の案

理論物理や数学寄りの問い（証明や理論の整合性を問うもの）は、このスキルの文献調査が扱っていないので、当面ここに落とす。

## 分類についての但し書き

このスキルの種類の分け方（実証の記述、実証の因果、規範、概念、解釈）を一つの分類として並べた方法論の教科書は、見つかっていない。
実証の側の分け方（記述と説明）は de Vaus に、問いの性質で設計を選ぶ考え方は Creswell によるもので、規範、概念、解釈は哲学と法学の方法論がそれぞれ別に持つものを組み合わせた。
分け方そのものが仮のもので、当てはまらない問いが出ることは想定している。

当てはまらない問いが出たら、その問いと、どう扱ったかを、スキルの改善のために dotfiles の issue に書く。

## 出典

- de Vaus, D. (2001). Research Design in Social Research. SAGE. 第1章（SAGE 公式の見本）: https://cmn-cdn-001.sagepub.com/books/titles/205847/att_sb1_9385.pdf 。照合済み（2026-10-09）: "Social researchers ask two fundamental types of research questions: 1 What is going on (descriptive research)? 2 Why is it going on (explanatory research)?"
- Creswell, J. W. (2014). Research Design 第4版、第1章（SAGE の見本）: https://in.sagepub.com/sites/default/files/upm-binaries/55588_Chapter_1_Sample_Creswell_Research_Design_4e.pdf 。照合済み（2026-10-09）: "The selection of a research approach is also based on the nature of the research problem or issue being addressed, the researchers' personal experiences, and the audiences for the study."
- 「一つの分類として並べた教科書は見つかっていない」は、2026-10-09 の文献調査で見つけられなかったことを指し、無いことの確認ではない。
