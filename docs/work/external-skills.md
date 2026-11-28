---
title: 外から取ってくるスキルを claude-private から外し、Claude.ai から同期されたスキルを外す
status: active
---

## 目的

出典: 端末からの入力（会話 3eac4129、2026-11-28 19:20、発言 16dc9d50）

要旨（Claude の要約）:
外部のメンテナが作るスキルが、同期フックの `migrate_new` で claude-private へ写されて管理されている。
これを claude-private で写さない形へ移す（設計書 `docs/superpowers/specs/2026-11-13-external-skills-design.md` を元に、2026-11-24 に加わった `tsuzuri` と `referent-first` も含める）。
あわせて、Claude.ai から同期されたスキル（`~/.claude/skills/synced/` と claude-private の `skills/synced/`）を外し、同期フックが `synced` と `.trash` を二度と取り込まないようにする。
同期がまた起きる仕組みがあれば調べ、手元で止められることと Claude.ai の画面での操作が要ることをリーダーへ案内する。
外部のメンテナのスキルの中身には手を入れず、入れ方と管理の経路だけを直す。
claude-private の私的なスキルは対象外で、claude-private では本作業の担当のパスだけを名指しでコミットする（別の作業が同じ clone を触っている）。

追加の依頼（端末からの入力（会話 3eac4129、2026-11-28 19:24、発言 bc0d6fca））: すでに着手したワークツリーやセッションが無いかを確かめる。

## いまの方針

設計書の案 A（宣言ファイル、入れるスクリプトと更新のコマンド、同期フックの除外）をそのまま作り、2026-11-28 の追補（設計書の末尾）で `tsuzuri`、`referent-first`、Claude.ai から同期されたスキルの扱いを足す。
dotfiles の変更を PR にし、リーダーが main へ取り込んだ後に、claude-private からの `git rm` と手元での入れ直しを行う。

## 判明した事実

- 2026-11-28 に、この作業に着手したワークツリー、ブランチ、PR、セッションは無かった（根拠: 全ワークツリーの未コミットの変更と、`main` に無いコミットの題、`gh pr list`、手元の会話の記録を `external-skills.txt` などで検索、`ListAgents`）。issue #90 は開いたままで、設計書のコミット 364159b のあと実装のコミットは無い。
- 別のワークツリーのセッションが imozuru の同梱物の欠けを読み取りだけで調べている。ファイルを書かないので、この作業とぶつからない。
- claude-private の `skills/imozuru`（28 ファイル）、`skills/tsuzuri`（17 ファイル）、`skills/referent-first`（1 ファイル）は、すべてのファイルが上流（`MaryCache/imozuru`、`MaryCache/tsuzuri`、`u-ichi/agent-plugins`）の git の履歴にある同じ中身で、こちらの改変は無い。上流の先端より古いだけ（根拠: 2026-11-28 に各ファイルの `git hash-object` を上流の `git log --all --find-object` で探した）。
- claude-private の `skills/reverse-engineer-anything` は npm の `rea-agents@6.9.0` の同梱のスキル（`version: "62"`）と同じで、MCP の登録 `rea` も `npx -y rea-agents@6.9.0 mcp`。npm の最新は 6.10.1（同梱は `version: "63"`）。`~/.agents/skills/reverse-engineer-anything` は記録の無い古い写し（`version: "42"`）。
- tsuzuri の利用者の校正辞書はスキルの外の `dot_config/tsuzuri/words.tsv` にあり、スキルを入れ直しても残る。
- skills CLI の記録（`~/.agents/.skill-lock.json`）には `imozuru`、`tsuzuri`、`referent-first` の取得元がすでにある。`referent-first` の上流の場所は `plugins/referent-first/skills/referent-first/SKILL.md`。
- Claude.ai から同期されたスキルは Claude Code の機能「Skills synced from claude.ai」で、claude.ai にログインしたセッションの開始時と、動いている間およそ 10 分（何もしていなければ 40 分）ごとに `~/.claude/skills/synced/` へ落とされる。消しても、claude.ai で有効なうちは次の同期で戻る。ユーザーの設定 `"syncClaudeAiSkills": false` で止まり、止めると次の起動で同期済みのスキルが `~/.claude/skills/.trash/` へ移される。claude.ai の画面（`claude.ai/customize/skills/yours`）でスキルを切ると、次の同期で手元から消える。Cowork とクラウドのセッションは手元の `~/.claude/skills/` を読まず、claude.ai で有効なスキルを読む（根拠: https://code.claude.com/docs/en/skills.md の「Skills synced from claude.ai」、手元の `claude` の本体に `syncClaudeAiSkills` の文字列がある）。
- claude-private の `skills/synced/` は 2026-09-18 の自動コミット（d3bc47b）で取り込まれた。`~/.claude/skills/synced` は claude-private へのリンクなので、Claude Code の同期は claude-private の中へ書いている。
- 同期フックの `migrate_new` は `"$HOME"/.claude/skills/*/` を回すので、ドットで始まる `.trash` は bash の既定でもともと拾わない。

## 判断の経緯

### 2026-11-13 採用: 宣言ファイルで外から取ってくるスキルを管理する（案 A）
- 出どころ: 未確認（設計書と issue #90 の本文。2026-11-20 より前の記録）
- 要旨（Claude の要約）: 三案から案 A を選んだと設計書に書かれている。今回の依頼（会話 3eac4129、発言 16dc9d50）が設計書を元に作るよう求めているので、設計書の中身を今回の依頼の条件として扱う。
- 状態: 有効

### 2026-11-28 採用: `tsuzuri` と `referent-first` は skills CLI の取り方で宣言する
- 出どころ: Claude の判断
- 理由: どちらも上流が GitHub のリポジトリで、skills CLI の記録にすでに取得元がある。`referent-first` をプラグインで入れると、スキルの名前が `referent-first:referent-first` になり、output style「エクシア（能天使）」が名指しする skill「referent-first」と合わない。プラグインの output style の本文はすでに output style「エクシア（能天使）」へ写してあり（PR #130）、プラグインで足す物が無い。宣言ファイルに並べると、Codex にも同じ物が入り、一覧が一つで済む。リーダーへの確認は要らないと判断した（入れ方の選択で、依頼の範囲の内側）。
- 状態: 有効

### 2026-11-28 採用: Claude.ai からの同期は設定 `syncClaudeAiSkills: false` で止める
- 出どころ: Claude の判断
- 理由: 依頼は同期されたスキルを全部（Anthropic の docx、pdf、pptx、xlsx、skill-creator、morning、import-memory と、claude.ai に上げた自作のスキル一つ）外すこと。claude.ai の画面では pdf と xlsx を切れない（公式の説明）ので、手元から全部を外せるのはこの設定だけ。止めないと、`synced` を消しても次の同期で戻る。claude.ai の画面での操作は手元を外すのには要らないが、Cowork とクラウドのセッションから自作のスキルを消すにはリーダーが claude.ai で消す必要がある。
- 状態: 有効

### 2026-11-28 採用: REA のスキルは npm のパッケージから写し、版は 6.9.0 のまま宣言する
- 出どころ: Claude の判断
- 理由: いまの claude-private の写しと MCP の登録がどちらも 6.9.0 で、版を上げるのは更新のコマンド（`external-skills update`）の役割。公式の `setup --skill-client` は `~/.claude/skills/` に直接置いて Codex の置き場とずれるので、パッケージの `skills/reverse-engineer-anything` を `~/.agents/skills/` へ写して `~/.claude/skills/` からリンクを張る（設計書が許す代わりの方法）。
- 状態: 有効

## いまの作業

宣言ファイルと `external-skills` のスクリプトをテストから作っている。

## 済んだこと

- 既に着手したワークツリーやセッションが無いことを確かめた（判明した事実の 1 行目）。
- 現状を調べ、設計書に 2026-11-28 の追補を書いた。

## 残っていること

- 宣言ファイル、`external-skills`、`run_onchange_83`、同期フックの直し、`install-cloud.sh` の直し、`settings.json` の `syncClaudeAiSkills`、文書、bats のテスト。
- コードレビュー、PR、リーダーによる main への取り込み。
- 取り込みの後: claude-private から `skills/imozuru`、`skills/tsuzuri`、`skills/referent-first`、`skills/reverse-engineer-anything`、`skills/synced` を `git rm` して push し、手元へ配って `external-skills install` で入れ直す。imozuru の常駐のページが動くことを確かめる。

## 次に Claude がすること

- 設計書の追補の「実装の手順」の順に作る。

## リーダーに決めてほしいこと

なし

## 参照

- issue #90
- 設計書: `docs/superpowers/specs/2026-11-13-external-skills-design.md`（2026-11-28 の追補を含む）
