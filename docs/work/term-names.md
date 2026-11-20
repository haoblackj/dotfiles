---
title: 報告で技術の用語を自作の言い換えに置き換えさせない仕組み
status: waiting
---

## 目的
Claude が報告の中で、決まった技術の用語（サブエージェント、バックアップ、API など）を自分で作った言い換えに置き換えないことを、全部のリポジトリで守らせる仕組みを、dotfiles に作る。

- 出典: 端末からの入力（会話 f2dbae01、2026-11-21 01:55、発言 4d62c675）。要旨（Claude の要約）: 自作の言い換えでなく、決まった用語で呼ぶこと。
- 出典: 端末からの入力（会話 f2dbae01、2026-11-21 01:56、発言 b29fc4d5）。要旨（Claude の要約）: 全体で守らせたい。グローバルの CLAUDE.md は膨らませず、適切なやり方で。
- 出典: 端末からの入力（会話 f2dbae01、2026-11-21 01:57、発言 8778a196）。要旨（Claude の要約）: 「和語に言い換えない」と書けば済む話ではない。
- 出典: 端末からの入力（会話 f2dbae01、2026-11-21 01:59、発言 15b851bf）。要旨（Claude の要約）: 守らせる仕組みは適切なリポジトリ（dotfiles）で作らせる。

## いまの方針
仕組みの形（検出のしかた）をリーダーに選んでもらってから、設計書と計画を書く。

## 判明した事実
- 別の作業で、Claude がサブエージェントを報告の中で「担い手」と書いた。グローバルの CLAUDE.md の「コミュニケーション」の節には造語と和語の言い換えを禁じる行が既にあった（根拠: `~/.claude/CLAUDE.md` 192〜193 行）。
- グローバルの CLAUDE.md 自体が「実装の担い手」（144 行）、「自前の見張り」（117 行）と書いている。決まりの文が、禁じている言い換えを Claude に見せている。
- 言い換えは決まりの文に多数ある（2026-11-21 に数えた。グローバルの CLAUDE.md に「正本」3、「知らせ」11、「持ち物」3、「担い手」2。`~/.claude/skills/*/SKILL.md` に「書き手」18、「見張り」5、「写し」5）。報告の言い換えも数え切れない（スクリプトを「台本」など。出典: 端末からの入力（会話 811156f3、2026-11-21 02:02、発言 7ee953e5））。言い換えの一覧で止める形は新しい言い換えを取りこぼす。
- 巷の解き方（2026-11-21 にサブエージェントが調べた。結論の要旨）: 禁止語の一覧だけで未知の言い換えを止める方式は見つからなかった。見つかったのは三つ。(a) プロンプトの文体を望む出力に寄せる（Anthropic の prompting best practices に、プロンプトの書式が応答の書式に移るという記述がある。語彙への効きは公式に書かれていない）。(b) 翻訳の分野で、用語集（使う語の表）を入力に渡し、出力の後に用語集と照らして LLM に直させる（WMT 2023 の用語タスクの論文ほか）。(c) Claude Code の Stop フックの `type: "prompt"` で `last_assistant_message` を判定させ、`ok: false` と `reason` で差し戻す（公式の hooks の文書。連続の差し戻しは 8 回が上限、`stop_hook_active` あり）。prh や Vale は誤→正の辞書型で、未知の言い換えを見つける機能の記述は無い。LLM の判定は人の評価に完全には一致しないという研究がある。
  - 出典: https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices 、https://code.claude.com/docs/en/hooks 、https://aclanthology.org/2023.wmt-1.80 、https://docs.vale.sh/checks/substitution
- 評価の実践で知られる人たちと Anthropic 公式の直し方（2026-11-21 にサブエージェントが調べた。要旨）: 公式は「しないことでなく、することを書く」「理由を添える」「望む応答の例を一つ入れる」「プロンプトの文体を出力に合わせる」を勧め、気取った文体の癖は、癖の型と直し方を散文で定義して渡す例を出している。否定の指示が漏れを増やす公式の実例もある。Hamel Husain と Shreya Shankar は、記録を読んで失敗を分類して数え（error analysis）、プロンプトを直し、評価で効きを測る循環を勧める。実行時のガードは客観的な失敗に限り、主観的な基準は事後の評価器に置くと書いている。「do not mention X」の直後に X の確率が上がる測定（arXiv 2511.12381）もあるが、Claude の日本語では未測定。
  - 出典: https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5 、https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1 、https://hamel.dev/blog/posts/evals-faq/ 、https://arxiv.org/abs/2511.12381
- 会話の記録の assistant の本文（コード、鉤括弧の中を除く）で、言い換えの候補 12 語を週ごとに数えた。1000 本あたり 9 月中旬は 31〜58、9 月 28 日の週に 470、以後 170〜300。11 月 11 日に CLAUDE.md へ「写しと書かない」を足した後も「写し」は減っていない（11 月 9 日の週 174、16 日の週 98）。候補の語は話題で正しく使われる場合（「書き手」など）も数えるので、目安の値。（根拠: scratchpad の `count_coinages.py`）
- 日本語圏の実践者の直し方（2026-11-21 にサブエージェントが調べた。多くは記事の要約で読んだ物。要旨）: 技術用語の自作の言い換えをそのまま論じた記事と「Claude語」に当たる呼び名は見つからなかった。近い現象は「AI-Slop な日本語」「AI臭」「翻訳調」と呼ばれる。yomiyasu の作者（Zenn、2026-10-01）と溝口コージ氏（Zenn、2026-07-13）は、禁止語の一覧は別の語への置き換えに移るだけで効きにくいと書いている。yomiyasu は自分の SKILL.md もリンターで検査し、指示文の文体が出力に移るのを防いでいる。NCDC のいばらき氏（Zenn、2026-09-01）は、gh で投稿する日本語を Stop フックで Claude Haiku に判定させて差し戻している（それでも半分以上は手で直したと書いている）。textlint-rule-preset-ai-writing（azu 氏）は「表現でなく構造を縛る」方針で、自作の言い換えを見つける規則は無い。日本語で起きやすい理由を根拠付きで示した研究は見つからなかった。
  - 出典: https://zenn.dev/algoartis/articles/0b1c731881b25c 、https://zenn.dev/coji/articles/natural-japanese-ai-smell-lint 、https://zenn.dev/ncdc/articles/6ea029ba5ecf65 、https://github.com/textlint-ja/textlint-rule-preset-ai-writing
- 英語の報告を止めるフックが働いた最初は 11 月 2 日ごろの記録で、9 月 28 日の週の跳ね上がりの原因ではない。
- dotfiles には、応答の本文を Stop フックで機械的に調べる前例がある（`dot_claude/hooks/executable_stop-fabricated-turn-guard.py`。`last_assistant_message` を読み、見つけたら `decision: block` で書き直させる）。

## 判断の経緯
### 2026-11-21 採用: この現象を「Claude語」と呼ぶ
- 出どころ: 端末からの入力（会話 811156f3、2026-11-21 02:14、発言 0d5413bb）
- 要旨（Claude の要約）: Claude がリーダーの言葉（トッププロフェッショナル）まで別の語に言い換えたのを受けて、この種の言い換えを Claude語と呼ぶ。
- 理由: 理由の提示なし
- 状態: 有効

## いまの作業
巷の解き方、評価の実践者のやり方、日本語圏の実践者のやり方を順に調べた（リーダーの問いを受けて。問いへの答えは選択肢の問いへの返事で、`prts quote` では見つからないので出どころは未確認）。合わせた形をリーダーに示し、答えを待っている。

## 済んだこと
- 既存の決まりとフックを読んだ。

## 残っていること
- 形の選択、設計書、計画、実装とテスト、審査、取り込み。

## 次に Claude がすること
- リーダーの選んだ形で設計書を書く。

## リーダーに決めてほしいこと
- 英語圏と日本語圏の両方の実践を合わせた形（記録から Claude語を集めて表にする、指示文を標準の用語で書き直し、指示文を pre-commit で検査する、Stop フックで Haiku に判定させて差し戻す、同じ集計で前後を測る）で進めてよいか。Claude の案: この形。答えで何が変わるか: 常設の仕組み（pre-commit の検査と Stop フック）を足すか、毎ターンの遅れと費用。

## 参照
- `dot_claude/hooks/executable_stop-fabricated-turn-guard.py`
