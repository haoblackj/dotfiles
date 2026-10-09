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

まず、作業ディレクトリが GitHub のリポジトリかを確かめる。

```
gh repo view --json nameWithOwner --jq .nameWithOwner
```

`owner/name` が出たら、それが投稿先のリポジトリ（手順8 の `--repo`）になる。
失敗したら（git のリポジトリでない、GitHub の remote が無い、gh が認証されていない）、どこへ立てるかをリーダーに聞く。

投稿先のリポジトリで、依頼のタスクに対応する issue を探す。
あれば、そこへデザインを投稿する。
無ければ、そのリポジトリに issue を新しく立てる（確認は取らない）。

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
`type` には表の値だけを書く。`unclassified` のときの近い種類と当てはまらない点は、`unclassified.md` のとおり `evidence` の冒頭に書く。

### 5. 分野の特定

一つの問いが複数の分野の研究対象にまたがるときだけ、この段を踏む。
`references/interdisciplinary.md` を読む。

候補の分野の下調べは、Agent ツールで `subagent_type` を `researcher`、`model` を `haiku` にして頼む。
下調べへの指示には、次の3点を必ず書く。

- その現象を研究対象にしている分野の候補と、根拠の URL を並べるところで止める。
- 問いの答えを探さない。文献の中身を要約しない。
- 候補ごとに、その分野がその現象を扱っているとした根拠を一文で添える。

指示には問いの本文を書かず、問いを構成する現象の一覧だけを渡す。
問いを渡すと、分野の候補を並べる代わりに答えを探しに行きやすい。

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
3 なら投稿に失敗している。JSON は直さず、gh の出力を見て issue の番号、リポジトリ、認証を確かめる。
整形の結果を投稿の前に見たいときは `--dry-run` を付ける。

投稿したら、リーダーの承認で止まる。
直しを求められたら、JSON を直して投稿し直す。
前の版のコメントは消さず、GitHub の minimize（理由 `OUTDATED`）でたたむ。たたんだコメントは開けば読めるので、何を直したかの経緯が残る。
投稿のときに gh が出したコメントの URL の末尾の番号（`#issuecomment-<番号>`）から、たたむのに要る node_id を取る。

```
gh api repos/<owner>/<name>/issues/comments/<番号> --jq .node_id
gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' -f id=<node_id>
```

### 9. 渡し（このスキルの範囲外）

承認の後、メインのセッションが、承認された指示書に従って調査役に命令し、結果を同じ issue に積む。
このスキルはここを扱わない。

## 費用

- 参照ファイルは、判定した種類のものと、手順の段で名指ししたものだけを読む。
- 段ごとにサブエージェントを分けない。呼び出しのたびに文脈を読み直すので、デザインを作るだけの仕事に費用が数倍かかる。
- 分野の下調べのように、候補と根拠を並べるだけの仕事は haiku に頼む。判断は自分で持つ。
