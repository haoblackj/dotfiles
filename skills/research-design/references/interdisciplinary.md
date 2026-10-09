# 分野の特定と統合（interdisciplinary）

## いつ読むか

手順の5で、一つの問いが複数の分野の研究対象にまたがるときに読む。
一つの分野で足りる問いでは読まない。

## 設計の型

Repko と Szostak の学際研究の手順（10段階）のうち、次の3つを使う。

1. 関係する分野の特定（段階3）
2. 洞察とその出どころの対立の特定（段階7）
3. 洞察の間の共通の土台の作成（段階8）

### 関係しうる分野を並べる

関係しうる分野とは、問題や問いにかかわる現象を、少なくとも一つ研究対象に含む分野である（定義の後半は未確認。下の出典）。
問いを構成する現象に分け、現象ごとに、それを研究対象にしている分野を並べる。

この下調べは、`researcher` サブエージェントを haiku で走らせて頼む。指示の型:

```
問い: <問い>
この問いにかかわる現象: <現象の一覧>
仕事: 現象ごとに、それを研究対象にしている学問分野の候補を並べ、候補ごとに、その分野がその現象を扱っているとした根拠を一文と、根拠の URL を添えて返す。
してはいけないこと: 問いの答えを探すこと。文献の中身を要約すること。
```

### 最も関係する分野に絞る

候補ごとに、次の3つを問う。

- その問題は、その分野の視点が自然に向かう対象か。その問題（またはその主な構成要素）は、その分野の研究対象の一部か。
- その分野は、無視できないほどの研究の蓄積（洞察と、それを支える証拠）をその問題について持っているか。
- その分野は、その問題を説明する理論を一つ以上生み出しているか。

最も関係する分野は、しばしば3つか4つで、問題に最も直接つながり、最も重要な研究を生み、最も有力な理論を出している分野である。
絞った分野ごとに、3つの問いへの答えを `disciplines[].reason` に書く。

### 対立の扱いを決める

分野どうしで洞察が対立したときの扱いを、承認の前に `conflict_handling` に書く。
共通の土台とは、対立する分野の洞察や理論の間にあって、統合を可能にする共有の基盤である。
Repko は、洞察が対立するときに共通の土台を作る道を3つ挙げる。洞察が拠る理論の対立を調停する、概念の対立を調停する、洞察の下にある前提の対立を調停する。
デザインでは、対立が出たときにどの道を試すかと、調停できなかったときに対立をそのまま報告することを書く。

統合の位置づけそのものは、学際研究の論者の間でまだ争われている。
この手順を唯一の正解として扱わず、対立を隠さずに並べる道具として使う。

## 何を証拠と数えるか

分野を選ぶ根拠は、その分野がその現象を研究対象にしていることを示す資料（分野の教科書、学会の扱う主題、その現象を扱った研究の存在）である。
問いへの答えになる証拠は、この段では集めない。各問いの種類の参照ファイルに従い、承認の後に集める。

## 判定の仕方

- 3つの問いに答えられない分野は、候補に残しても絞り込みで外す。
- 分野の数で厳密さを演出しない。足りる数に絞る。
- 選ばなかった有力な候補があれば、外した理由を書く。

## 出典

- 段階の名前: Repko & Szostak『Interdisciplinary Research: Process and Theory』第4版、第3章の見本（SAGE）: https://cmn-cdn-001.sagepub.com/books/titles/271311/att_sb1_109113.pdf 。照合済み（2026-10-09）: "3. Identify relevant disciplines."、"7. Identify conflicts between insights and their sources."、"8. Create common ground between insights."。段階7と8の本文での説明は**未確認**（公開された本文が見つからない）。
- 関係しうる分野の定義: 同書第5版（2025）の Google Books の検索結果で "... potentially relevant discipline is one whose research domain" までを照合済み。"includes at least one phenomenon involved in the problem or research question" 以降は**未照合**（二次資料と、サブエージェントが見たスニペットによる）。
- 3つの問いと「しばしば3つか4つ」: 同書第3版（2017）第4章の抜粋（教員の個人サイトに置かれた教材で、出版社の配布ではない）: https://www.laurenrbeck.com/uploads/1/7/7/3/17738351/repko-and-szostak-chapter-3-and-4-excerpts-b-1.pdf 。照合済み（2026-10-09）: "The most relevant disciplines are those disciplines, often three or four, that are most directly connected to the problem, have produced the most important research on it, and have advanced the most compelling theories to explain it."、"Is the problem a natural focus for the discipline's perspective? Is it (or key components of it) a part of the subject matter of the discipline?"、"Has it produced a body of research (i.e., insights and supporting evidence) on the problem of such significance that it cannot be ignored?"、"Has it generated one or more theories to explain the problem?"
- 共通の土台の定義: 同書第4版、第1章の見本: https://cmn-cdn-001.sagepub.com/books/titles/271311/att_sb1_109112.pdf 。照合済み（2026-10-09）: "Common ground is the shared basis that exists between conflicting disciplinary insights or theories and makes integration possible"。
- 共通の土台を作る3つの道と、統合の位置づけが争われていること: Repko, A. F. (2007). Integrating interdisciplinarity. Issues in Integrative Studies, 25, 1–31: https://interdisciplinarystudies.org/wp-content/issues/vol25_2007/03_Vol_25_pp_1_31.pdf 。照合済み（2026-10-09）: "There are three ways to create common ground when insights conflict. The first and most direct way is to reconcile conflicts between the theories advanced by the insights (i.e., if the insights are theory-based). The second way is to reconcile conflicts between the concepts. The third way is to reconcile conflicts between assumptions that underlie the insights"、"Integrationists substantially agree that creating common ground is essential to achieving integration"、要旨 "With the role of integration within theories of interdisciplinarity still contested, definitional and methodological questions persist"。
- 下調べを haiku に頼むことと、その指示の型は、このスキルの設計上の判断（spec の担い手と費用）で、上の出典の主張ではない。
