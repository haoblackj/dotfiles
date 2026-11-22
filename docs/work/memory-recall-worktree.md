---
title: ワークツリーのセッションでもメモリの想起（memory_recall）を効かせ、/resume がワークツリーをまたぐかを確かめる
status: done
---

## 目的

Orca のワークスペース（git のワークツリー）で作業を続けても、これまでの使い方に支障が出ないようにする。
トランスクリプトがワークツリーごとに分かれることで支障が出る所を洗い出し、見つかった `memory_recall.py` の不具合を直し、`/resume` がワークツリーをまたげるかを試す。
依頼の出典: 未確認（Claude が出した次の作業の候補をリーダーが選んだ文。`prts quote` は端末からの入力として引けないと返した）。
要旨（Claude の要約）: memory_recall を直し、/resume も試す。

## いまの方針

`memory_recall.py` は、フックの入力の `cwd` から git の共通ディレクトリを引き、リポジトリ本体のパスから Claude Code と同じ memory の置き場を求める。
見つからなければ従来どおり transcript の隣の `memory` を見る。
直しは PR #111 で main に入り、本番へ配った。

## 判明した事実

- Claude Code の auto memory は、ワークツリーのセッションでもリポジトリ本体のパスを `~/.claude/projects/<project>/` の名前にする。transcript はワークツリーのパスの側のフォルダに入る（根拠: このセッションは Orca のワークツリーを cwd にして始まり、memory の置き場として本体側のフォルダを渡された。公式ドキュメントの memory のページは「リポジトリ単位、ワークツリー間で共有」と書く）。
- 直す前の `memory_recall.py` は transcript の隣の `memory` だけを見ていたため、ワークツリーのセッションでは黙って何もしていなかった（根拠: Orca のワークツリーの transcript のフォルダを渡すと `resolve_memory_dir` が `None` を返した）。
- トランスクリプトが分かれても困らないもの: D ドライブへの退避（`~/.claude/projects` を丸ごと写す）、prts（全フォルダから session id で探す）、作業記録の一覧とセッションの題のフック（Claude Code から渡されるパスと git のワークツリーの一覧を使う）、claude-private への memory の同期（本体のフォルダの memory が対象）。
- `claude --resume` の一覧は、既定では今のワークツリーのセッションだけを出す。Ctrl+W で同じリポジトリのほかのワークツリーのセッションも出る（根拠: scratchpad に本体とワークツリーを作り、それぞれで対話のセッションを一つずつ作って、本体から一覧を開いた。2026-11-22、Claude Code 2.1.329）。
- 本体から一覧を開いてワークツリーのセッションを選ぶと、会話はそのワークツリーの transcript に書き足されるが、作業のフォルダは開いた側（本体）のままになる（根拠: 上の試しで、再開した画面の見出しと会話の中の cwd が本体を指し、ワークツリー側の transcript の更新時刻が進んだ）。
- `claude -p` で作ったセッションは `/resume` の一覧に出ない（根拠: 同じ試しで、`-p` のセッションだけのときは「No sessions in this project yet」と出た）。
- `claude --continue` は「いまのフォルダの最新のセッション」を開く（根拠: `claude --help`）。

## 判断の経緯

### 2026-11-22 採用: PR #111 を main へ取り込む
- 出どころ: 端末からの入力（会話 eba981b1、2026-11-22 09:27、発言 584360f5）
- 要旨（Claude の要約）: マージする。
- 理由: 理由の提示なし。
- 状態: 有効

### 2026-11-22 採用: 本体のパスから求めた memory を、transcript の隣より先に探す
- 出どころ: Claude の判断
- 理由: Claude Code 自身が本体のパスで memory を置くので、それに合わせるのがいちばん食い違いが少ない。git の外や、名前が合わないとき（長いパスの短縮、BMP の外の文字、シンボリックリンク）は従来の解決へ落ちるので、今までより悪くならない。
- 状態: 有効

## いまの作業

なし（済んだ）。

## 済んだこと

- `memory_recall.py` の直しとテスト（PR #111、コミット 56bdfe2、6790404）。全テスト 211 件が通った。コードレビューで指摘された「git の出力が UTF-8 で読めないと従来の解決へ落ちない」を直した。
- `/resume` がワークツリーをまたぐかの試し（上の「判明した事実」）。
- PR #111 を squash で main へ取り込んだ（6e6b70a）。本番の作業コピーを main の先端へ進め、`chezmoi apply` で `~/.claude/hooks/memory_recall.py` とそのテストだけを配った。`chezmoi status ~/.claude/hooks/` の違いは 0 件。配る前のフックの控えは `~/.cache/memory-recall-worktree/memory_recall.py.before-111`。
- Orca のワークスペース（`~/orca/workspaces/chezmoi/main`）で新しいセッションを立て、利用枠の表示についての質問を送った。transcript に、フックが本体側の memory から `user_statusline_usage_is_remaining.md` を類似度 0.74 で差し込んだ記録が残った。

## 残っていること

- なし。

## 次に Claude がすること

- なし。

## リーダーに決めてほしいこと

- なし

## 参照

- PR: https://github.com/haoblackj/dotfiles/pull/111
- 公式ドキュメント: https://code.claude.com/docs/en/memory
