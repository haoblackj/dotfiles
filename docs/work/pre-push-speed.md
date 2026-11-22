---
title: pre-push のテストを速くする
status: active
---

## 目的

pre-push のテストが遅すぎるので、実態と原因を調べる（出典: 端末からの入力（会話 e649f52f、2026-11-22 22:29、発言 28cc0de4）。要旨は Claude の要約）。
調べた結果を受けて、bats を並列で走らせ、本物の Haiku を呼ぶテストを偽物に替える（出典: 端末からの入力（会話 e649f52f、2026-11-22 22:42、発言 22560e63）。要旨は Claude の要約）。

## いまの方針

pre-commit の bats フックは、GNU parallel があればコアの数だけ並列に走らせ、無ければ順に走らせる。
`session-title-promote.bats` は `PATH` の先頭に偽の `claude` を置き、渡した引数と、答えを採るか捨てるかを確かめる。

## 判明した事実

- 直す前の pre-push の段（`pre-commit run --hook-stage pre-push --all-files`）は CLOCK_MONOTONIC で 101.6 秒。bats が 97.2 秒、pytest が 2.8 秒、sp-repo-review が 0.3 秒（2026-11-22 に測った値）。
- bats は 365 件を 1 コアで順に走らせていて、CPU の使用率は 53%。マシンは 16 コア。
- `session-title-promote.bats` の 7 件が本物の `claude -p --model haiku` を呼び、合わせて約 22 秒かかっていた。push のたびに利用枠も使っていた。
- 時間切れを待つ作りのテストが合わせて約 17 秒（herdr が固まる場合、codexbar の serve が応答しない場合、statusline の herdr が遅い場合、usage-route のサーバーに届かない場合と応答しない場合）。今回は手を入れていない。
- WSL の CLOCK_REALTIME が約 5.5 秒ごとに前後へ飛んでいて、`bats -T` のテストごとの時間が見かけで 7.5 秒前後になる。本題と別のバグとして `ideas/bugs/2026-11-22-wsl-realtime-clock-jumps.md` に書いた。
- 直した後の pre-push の段は、3 回続けて 19.0 秒、22.2 秒、21.1 秒で、3 回とも全部通った。GNU parallel が無い場合（moreutils 風の `parallel` を `PATH` の先頭に置いた）は順に走って 76.4 秒で、全部通った。

## 判断の経緯

### 2026-11-22 採用: bats を並列で走らせ、Haiku を偽物にする
- 出どころ: 端末からの入力（会話 e649f52f、2026-11-22 22:42、発言 22560e63）
- 要旨（Claude の要約）: 調べた結果の二つの手（bats の並列化、Haiku の偽物化）を両方行う。
- 理由: 理由の提示なし
- 状態: 有効

### 2026-11-22 採用: GNU parallel が無い環境では順に走らせる
- 出どころ: Claude の判断
- 理由: `bats --jobs` は GNU parallel が無いとエラーで止まる。クラウドのコンテナなど GNU parallel の無い環境でも pre-push を通すため。
- 状態: 有効

## いまの作業

コミットを push して PR を作り、コードレビューを受ける。

## 済んだこと

- bats フックの並列化と、`session-title-promote.bats` の偽の `claude` への置き換え（コミット 18e2e31）。

## 残っていること

- コードレビューと、既定ブランチへの取り込み（取り込みはリーダーの判断）。

## 次に Claude がすること

- PR のコードレビューを受け、指摘があれば直す。

## リーダーに決めてほしいこと

- なし

## 参照

- コミット 18e2e31
- `ideas/bugs/2026-11-22-wsl-realtime-clock-jumps.md`
