---
title: Orca のワークツリーが main を取り出し、本番の作業コピーが main に乗れなくなる原因を直す
status: waiting
---

## 目的

本番の作業コピー（`~/.local/share/chezmoi`）が `main` に乗れず、ブランチから切り離した HEAD で進められていた原因を、Orca の使い方から直す。

- 出典: 端末からの入力（会話 e5468ff9、2026-11-25 00:08、発言 fab1f378）。要旨（Claude の要約）: 本番の作業コピーが切り離した HEAD になっている状態をやめさせる。
- 出典: 端末からの入力（会話 e5468ff9、2026-11-25 00:09、発言 98810c73）。要旨（Claude の要約）: Orca の使い方に原因があるはずなので、そこから直す。

## いまの方針

本番の作業コピーを `main` に乗せたままにする。
Orca は、ほかのワークツリーが取り出しているブランチの再利用を断るので、本番の作業コピーが `main` に乗っている間は、Orca のワークツリーが `main` を取り出さない。
決まりは dotfiles の CLAUDE.md の「本番の作業コピーのブランチ」に置く。

## 判明した事実

- Orca がワークツリー `main-2` を作ったのは 2026-11-21 03:03:19。作ったのは Orca のデスクトップのアプリで、`orca` CLI ではない（根拠: Orca の記録の `creatorProvenance` がデスクトップの端末を指し、`cliProvenance` が無い）。
- そのとき本番の作業コピーは `main` ではなく `ops/work-records` に乗っていて、`main` はどのワークツリーも取り出していなかった（根拠: 本番の作業コピーの HEAD の reflog。`ops/work-records` から `origin/main` へ移ったのは 2026-11-21 03:38:01）。
- `main-2` は、新しいブランチを切らずに既存の `main` を取り出す指定（Orca の画面の「Reuse branch」）で作られた（根拠: Orca の記録で `baseRef` が `refs/heads/main`、`preserveBranchOnDelete` が true。`preserveBranchOnDelete` は、既存のブランチを取り出したときと「Reuse branch」のときだけ書かれる。Orca 1.4.266 の `orcad-server.js` を読んだ）。
- Orca の作成の画面は、ブランチの一覧から `main` か `origin/main` を選ぶと「Reuse branch」を最初から入れる（根拠: 同じ 1.4.266 のモバイルの画面のコードの `defaultReuse`。デスクトップの画面のコードは Windows 側にあり、読んでいない）。
- 「Reuse branch」は、そのブランチをほかのワークツリーが取り出していると、`Branch "main" is already checked out at ...` のエラーで断られる（根拠: `orcad-server.js` のコード。実機では試していない）。
- Orca の設定に、「Reuse branch」の初期値を変える項目と、特定のブランチの再利用を禁じる項目は見つからなかった（根拠: 実行中の Orca の設定の控えと `orca repo --help`）。`orca repo set-base-ref` が変えるのは新しいブランチの起点だけ。
- Orca のほかのワークツリーは、すべて専用のブランチか切り離した HEAD で、`baseRef` が `refs/heads/main` の物と `preserveBranchOnDelete` が true の物は `main-2` だけ（根拠: 2026-11-25 の `orca worktree list --json` の全 16 件と Orca の記録）。`~/repo/github.com/haoblackj` の git のリポジトリも、`main` か `master` を取り出しているのは本体の作業コピーだけだった。
- Orca は、ワークツリーを新しく作るとき、起点の `origin/main` に対応する手元の `main` を早送りすることがある（設定 `refreshLocalBaseRefOnWorktreeCreate`）。`main` を取り出している作業コピーに、追跡しているファイルの変更が無ければ、その作業コピーで `git merge --ff-only` を打つ（根拠: `orcad-server.js` のコード。WSL の中の Orca の設定は false だが、デスクトップのアプリは作成のたびに自分の設定を渡せる）。
- `main-2` の reflog の 2026-11-22 21:59:26 の早送りは、デスクトップのアプリが別のワークツリーを作った時刻と秒まで同じで、マージの形も上のコードと合う。2026-11-25 に、デスクトップのアプリの設定の控えを読み、この設定が入っていた（true）ことを確かめた。画面での名前は「ローカル main を最新の状態に保つ」（設定の「Git とソース管理」）。
- この設定が入ったままで本番の作業コピーが `main` に乗っていると、デスクトップのアプリで dotfiles のワークツリーを作ったときに、本番の作業コピーが早送りされうる。symlink で配っている `settings.json` と公開のスキルは、その時点で効く。
- 2026-11-25 00:08、前の会話の Claude が `main-2` を同じコミット（e532082）のままブランチから外し、`main` を origin/main（33d4250）へ進めて本番の作業コピーを乗せた（根拠: reflog）。
- `main-2` には、消す前、2026-11-22 から動いたままの Claude Code が 2 つあった（会話 3c33ee18 と、2026-11-22 18:12 に起動した 1 つ）。前の会話の引き継ぎの文は「プロセスは無かった」としていたが、違っていた。`main-2` に未コミットの変更と追跡外のファイルは無く、HEAD の e532082 は origin/main に含まれている（2026-11-25 に確かめた）。

## 判断の経緯

### 2026-11-25 採用: 再発は、Orca の設定ではなく、本番の作業コピーを main に乗せ続けることで防ぐ

- 出どころ: Claude の判断
- 理由: Orca に、再利用を禁じる設定が無い。本番の作業コピーが `main` に乗っていれば、Orca は自分で再利用を断る。`main` が空いたことが `main-2` の作られた条件なので、空けないことが条件を消す。
- 状態: 有効

### 2026-11-25 棄却: 本番の作業コピーでのコミットを CLAUDE.md で禁じる

- 出どころ: Claude の判断（コードレビューの指摘への答え）
- 理由: 軽微な変更を main に直接コミットする決まりがグローバルにあり、リーダーが求めていない禁止になる。手元のコミットが進んでいるだけなら `git pull --ff-only` は失敗せず、origin/main も別に進んで分かれたときだけ失敗する（使い捨てのリポジトリで確かめた）。
- 状態: 有効

### 2026-11-25 採用: 残りの 4 つは Claude の案のとおりにする

- 出どころ: 端末からの入力（会話 e35fb046、2026-11-25 00:18、発言 143bde97）
- 要旨（Claude の要約）: 示された 4 つの問いは、すべて推奨のとおりにする。
- 中身: dotfiles の CLAUDE.md に、本番の作業コピーを `main` に乗せたままにする決まりを足す。`main-2` は中の 2 つの Claude Code を閉じてから消す。Orca のデスクトップの、手元の `main` を早送りする設定を切る。`docs/work/pre-push-speed.md` の切り離した HEAD の記述は書き換えない。その記述の進め方は、CLAUDE.md の「本番の作業コピーのブランチ」で置き換わった。
- 理由: 理由の提示なし
- 状態: 有効

## いまの作業

リーダーが、CLAUDE.md の決まりの PR を main に取り込むかを決めるのを待っている。

## 済んだこと

- Orca が `main` を取り出した条件と、ほかのリポジトリに同じ形のワークツリーが無いことを確かめた。
- `main-2` の 2 つの Claude Code（会話 3c33ee18 と 2ccab80c）が、2026-11-22 のターンを終えて待機中で、打ちかけの文が無いことを確かめて閉じ、`orca worktree rm` で `main-2` を消した（2026-11-25）。消す前の HEAD は e532082 で、変更と、無視されたファイルを含む追跡外のファイルは無かった。`orca worktree list` と `git worktree list` から消え、フォルダも無い。
- Orca のデスクトップの「ローカル main を最新の状態に保つ」を画面から切り、保存された値が false になったことを設定の控えで確かめた（2026-11-25 00:21）。戻すときは同じ画面で入れる。
- dotfiles の CLAUDE.md に「本番の作業コピーのブランチ」の節を足した（このブランチ）。コードレビュー（requesting-code-review）に、設計の前提を崩す指摘は無かった。「ブランチから外す」を `git switch --detach` と書き、pre-push-speed の記述が置き換わったことをこの記録に書いた。

## 残っていること

- PR を main に取り込み、本番の作業コピーを `git pull --ff-only` で進める。

## 次に Claude がすること

- リーダーが取り込みを決めたら、PR を main に取り込み、本番の作業コピーを `git pull --ff-only` で進め、この記録を done にする。

## リーダーに決めてほしいこと

- CLAUDE.md の決まりの PR を main に取り込むか。Claude の案: 取り込む。文書だけの変更で、配るファイルは変わらないため。トレードオフ: 取り込むと、dotfiles で動くすべてのセッションがこの決まりを読む。答えで変わるか: 取り込まなければ、決まりはどのセッションにも届かない。

## 参照

- [pre-push-speed.md](pre-push-speed.md)、[claude-ops-records.md](claude-ops-records.md)
