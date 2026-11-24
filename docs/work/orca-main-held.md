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
ワークツリー `main-2`、CLAUDE.md、Orca の設定は、リーダーの答えを待って変える。

## 判明した事実

- Orca がワークツリー `main-2` を作ったのは 2026-11-21 03:03:19。作ったのは Orca のデスクトップのアプリで、`orca` CLI ではない（根拠: Orca の記録の `creatorProvenance` がデスクトップの端末を指し、`cliProvenance` が無い）。
- そのとき本番の作業コピーは `main` ではなく `ops/work-records` に乗っていて、`main` はどのワークツリーも取り出していなかった（根拠: 本番の作業コピーの HEAD の reflog。`ops/work-records` から `origin/main` へ移ったのは 2026-11-21 03:38:01）。
- `main-2` は、新しいブランチを切らずに既存の `main` を取り出す指定（Orca の画面の「Reuse branch」）で作られた（根拠: Orca の記録で `baseRef` が `refs/heads/main`、`preserveBranchOnDelete` が true。`preserveBranchOnDelete` は、既存のブランチを取り出したときと「Reuse branch」のときだけ書かれる。Orca 1.4.266 の `orcad-server.js` を読んだ）。
- Orca の作成の画面は、ブランチの一覧から `main` か `origin/main` を選ぶと「Reuse branch」を最初から入れる（根拠: 同じ 1.4.266 のモバイルの画面のコードの `defaultReuse`。デスクトップの画面のコードは Windows 側にあり、読んでいない）。
- 「Reuse branch」は、そのブランチをほかのワークツリーが取り出していると、`Branch "main" is already checked out at ...` のエラーで断られる（根拠: `orcad-server.js` のコード。実機では試していない）。
- Orca の設定に、「Reuse branch」の初期値を変える項目と、特定のブランチの再利用を禁じる項目は見つからなかった（根拠: 実行中の Orca の設定の控えと `orca repo --help`）。`orca repo set-base-ref` が変えるのは新しいブランチの起点だけ。
- Orca のほかのワークツリーは、すべて専用のブランチか切り離した HEAD で、`baseRef` が `refs/heads/main` の物と `preserveBranchOnDelete` が true の物は `main-2` だけ（根拠: 2026-11-25 の `orca worktree list --json` の全 16 件と Orca の記録）。`~/repo/github.com/haoblackj` の git のリポジトリも、`main` か `master` を取り出しているのは本体の作業コピーだけだった。
- Orca は、ワークツリーを新しく作るとき、起点の `origin/main` に対応する手元の `main` を早送りすることがある（設定 `refreshLocalBaseRefOnWorktreeCreate`）。`main` を取り出している作業コピーに、追跡しているファイルの変更が無ければ、その作業コピーで `git merge --ff-only` を打つ（根拠: `orcad-server.js` のコード。WSL の中の Orca の設定は false だが、デスクトップのアプリは作成のたびに自分の設定を渡せる）。
- `main-2` の reflog の 2026-11-22 21:59:26 の早送りは、デスクトップのアプリが別のワークツリーを作った時刻と秒まで同じで、マージの形も上のコードと合う。デスクトップのアプリで、この設定が入っていると推定する（Windows 側の設定は読んでいない）。
- 本番の作業コピーが `main` に乗ったので、この推定が正しければ、次にデスクトップのアプリで dotfiles のワークツリーを作ると、本番の作業コピーが早送りされる。symlink で配っている `settings.json` と公開のスキルは、その時点で効く。
- 2026-11-25 00:08、前の会話の Claude が `main-2` を同じコミット（e532082）のままブランチから外し、`main` を origin/main（33d4250）へ進めて本番の作業コピーを乗せた（根拠: reflog）。
- `main-2` には 2026-11-22 から動いたままの Claude Code が 2 つある（会話 3c33ee18 と、2026-11-22 18:12 に起動した 1 つ）。前の会話の引き継ぎの文は「プロセスは無かった」としていたが、違っていた。`main-2` に未コミットの変更と追跡外のファイルは無く、HEAD の e532082 は origin/main に含まれている（2026-11-25 に確かめた）。

## 判断の経緯

### 2026-11-25 採用: 再発は、Orca の設定ではなく、本番の作業コピーを main に乗せ続けることで防ぐ

- 出どころ: Claude の判断
- 理由: Orca に、再利用を禁じる設定が無い。本番の作業コピーが `main` に乗っていれば、Orca は自分で再利用を断る。`main` が空いたことが `main-2` の作られた条件なので、空けないことが条件を消す。
- 状態: 有効

## いまの作業

リーダーの答えを待っている。

## 済んだこと

- Orca が `main` を取り出した条件と、ほかのリポジトリに同じ形のワークツリーが無いことを確かめた。

## 残っていること

- `main-2`、CLAUDE.md、Orca のデスクトップの設定についての答えを受けて変える。

## 次に Claude がすること

- 下の問いの答えを受け、CLAUDE.md に書くなら、このブランチ `haoblackj/orca-main-held` で直して PR にする。

## リーダーに決めてほしいこと

- dotfiles の CLAUDE.md に「本番の作業コピーは `main` に乗せたままにし、作業のブランチはワークツリーで切る。進めるのは `git pull --ff-only` で、`main` がほかで取り出されていて乗れないときは、切り離さずにその取り出し元を直す」を足すか。Claude の案: 足す。作業のセッションが本番の作業コピーを別のブランチに移すと、`main` が空いて同じことが起きるため。トレードオフ: 決まりなので、守らないセッションは止められない。答えで変わるか: 足さなければ、`main` が空く条件が残る。
- `main-2` を残すか、消すか。Claude の案: 中で動いている 2 つの Claude Code を閉じた後に消す。変更は残っておらず、役目の `main` は本番の作業コピーが持つため。トレードオフ: 消すと、中の 2 つの会話の端末も閉じる（会話の記録は `~/.claude/projects/` に残る）。答えで変わるか: 残しても、切り離した HEAD なので `main` は塞がない。
- Orca のデスクトップの設定で、ワークツリーを作るときに手元の `main` を早送りする設定を切るか。Claude の案: 切る。本番の作業コピーが、別の作業のためのワークツリーの作成で進むのを避けるため。トレードオフ: 本番の作業コピーを進めるには `git pull --ff-only` が要る。答えで変わるか: 入れたままなら、symlink の `settings.json` とスキルが、ワークツリーの作成をきっかけに新しくなる。
- `docs/work/pre-push-speed.md` の「済んだこと」にある、切り離した HEAD を進めた記述を今の形へ書き換えるか。Claude の案: 書き換えない。2026-11-23 に実際に行ったことの記録で、今の決まりは CLAUDE.md に置くため。トレードオフ: その記述だけを読むと、切り離した HEAD が今の運用に見える。答えで変わるか: 書き換えると、当時の手順の記録が消える。

## 参照

- [pre-push-speed.md](pre-push-speed.md)、[claude-ops-records.md](claude-ops-records.md)
