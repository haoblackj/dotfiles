---
title: 退役スキルの削除、report-skills の Codex との共有、古い chezmoi の worktree の片付け
status: waiting
---

## 目的

出典: 端末からの入力（会話 61805cba、2026-11-28 19:20、発言 1d11b5ef）

要旨（Claude の要約）: スキルの棚卸しの結果を受けて、次の 3 件を片付ける。
退役した mulmoterminal のスキル 10 本を、Codex のスキルの置き場と非公開リポジトリの退役の置き場の両方から履歴を残さず消す（退役の置き場のほかのスキルは残す）。
report-skills を Claude 側の正本に一本化し、Codex の古い実体の写しをやめて正本を参照させ、ほかのマシンでも chezmoi で再現できるようにする。
削除済みの session-handoff の残骸を持つ古い chezmoi の worktree を、未コミットや未マージの作業が無いものだけ外し、残るものはリーダーに確かめる。

## いまの方針

1 と 2 は済んだ。
3 は、未コミットも未マージのコミットも無い worktree だけを外し、ブランチは消さずに残した。
未マージのコミットが残る worktree 4 つは、リーダーの答えを待っている。

## 判明した事実

- Codex 0.171.0 は `~/.codex/skills/` の下の symlink のスキルを読む（根拠: `codex debug prompt-input` の出力に、symlink の先の正本の description が載った）。
- 置き換える前の Codex のプロンプトには、旧版の広いトリガーの description が載っていた（同じく `codex debug prompt-input`）。
- Codex の写しの `agents/openai.yaml` は正本と同じ中身だった（`diff -r`）。
- `install-cloud.sh` は `dot_codex/` を配らないので、クラウドセッションには影響しない。
- 未マージのコミットが残る worktree 4 つの内訳（2026-11-28 に `git log origin/main..<ブランチ>` と `git cherry` で数えた。どれも未コミットの変更は無い）。
  - `.claude/worktrees/gh-guard-data-path`: 開いている PR #96 のブランチ。main に無いコミットが 4 つ（バグの書き置きの足し外しなど）。
  - `.claude/worktrees/issue86-work-ownership`: PR の無いブランチ。main に無いコミットが 1 つ（判断の持ち主の節のまとめ、Refs #86）。
  - `.claude/worktrees/example-text`、`.claude/worktrees/public-private-names`: PR の無いブランチで、main に無いコミットが 36 と 37。公開済みの情報の監査のころのコミットで、main の書き換えの前の版を持つ可能性がある（Claude の推定で、確かめていない）。

## 判断の経緯

### 2026-11-28 採用: Claude Code 側の report-skills は skillOverrides の off のままにする
- 出どころ: 質問のツールへの回答（会話 61805cba、2026-11-28）
- 要旨（Claude の要約）: Claude 側は今の off を保ち、Codex からだけ使えるようにする。
- 理由: 理由の提示なし（Claude の推奨を選んだ）。
- 状態: 有効

### 2026-11-28 採用: Codex のスキルは `dot_codex/skills/symlink_<名前>.tmpl` で claude-private の正本へ symlink する
- 出どころ: Claude の判断
- 理由: `dot_claude/skills/symlink_<名前>.tmpl` と同じ型で、`chezmoi apply` でほかのマシンにも再現できる。正本を直接指すので、`~/.claude/skills/` の symlink を同期フックが張り直すかどうかに依らない。
- 状態: 有効

### 2026-11-28 採用: 外した worktree のブランチは消さない
- 出どころ: Claude の判断
- 理由: どのブランチを残すか消すかはリーダーの判断（グローバルの CLAUDE.md の指示範囲の厳守）。依頼は worktree の片付けで、ブランチの削除は含まない。
- 状態: 有効

## いまの作業

リーダーの答え待ち。

## 済んだこと

- 非公開リポジトリの退役の置き場から mulmoterminal のスキル 10 本と退役の説明のファイルを `git rm` してコミットし、push した。退役の置き場のほかのスキルは残した。
- `~/.codex/skills/mulmoterminal-*` 10 本を `trash-put` でごみ箱へ移した。
- `~/.codex/skills/report-skills` の旧版の写しを `trash-put` でごみ箱へ移し、`dot_codex/skills/symlink_report-skills.tmpl` を足してこのワークツリーをソースに `chezmoi apply` した。
- 本番の chezmoi の worktree のうち、未コミットも未マージも無い 4 つ（`.claude/worktrees/` の `herdr-remnants`、`herdr-tab-restore-label`、`imozuru-serve` と、`~/.mulmoterminal/worktrees/chezmoi-1fae523b/10-task`）を `git worktree remove` で外した。

## 残っていること

- 未マージのコミットが残る worktree 4 つの扱い。
- この PR の取り込み後、本番の作業コピーで `chezmoi apply ~/.codex/skills/report-skills` が差を出さないことを確かめる。

## 次に Claude がすること

- リーダーの答えに従って、未マージの worktree 4 つを外すか残す。
- 取り込み後に、本番の作業コピーをソースに `chezmoi diff ~/.codex/skills` が空であることを確かめる。

## リーダーに決めてほしいこと

- 未マージのコミットが残る worktree 4 つ（上の「判明した事実」）をどうするか。Claude の案: PR #96 のブランチの worktree は PR が開いている間は残し、ほかの 3 つは worktree だけ `git worktree remove` で外してブランチは残す（コミットはブランチに残るので失われず、ワークツリー内の古い `.chezmoitemplates` の衝突も消える）。トレードオフ: ブランチを残すので、ブランチの一覧には古いものが残る。答えで何が変わるか: 外す worktree の数。

## 参照

- PR（このブランチ、作成後に足す）
