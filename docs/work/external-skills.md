---
title: 外から取ってくるスキルを claude-private から外し、Claude.ai から同期されたスキルを外す
status: done
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
- skills CLI の `update` と `add` は、`~/.claude/skills/<名前>` が実体のディレクトリなら消し、リンクなら外して張り替える（コードレビューが skills CLI 1.9.1 のソースで確かめた）。リンクの先へは書かない。
- `syncClaudeAiSkills: false` が効くと、Claude Code は次の起動で同期済みのスキルを `~/.claude/skills/.trash/` へ移す。`~/.claude/skills/synced` は claude-private へのリンクなので、移し方によっては claude-private の作業ツリーに `skills/synced` の削除が未コミットで残りうる（コードレビューの指摘。まだ確かめていない）。

- 移行の後、本番の設定で新しいセッションを起動すると、Claude Code が `~/.claude/skills/synced/` を実体のディレクトリとして作り直し、Claude.ai から落とした 15 のスキル（依頼の 8 つと、docs、deep-research、computer-use、chrome-browser、google-workspace、built-in-browser、もう一つの作業用の項目）を約 30 秒後に `~/.claude/skills/.trash/` へ移した。二度目の起動では落とし直しも `.trash` の増加も無かった。`synced` には空の `.staging` と `.bucket-*` だけが残り、SKILL.md は 0 件（2026-11-28 20:00 から 20:03 に測った）。同期フックは `synced` も `.trash` も取り込まないので、claude-private は変わっていない。

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

### 2026-11-28 採用: コードレビューの指摘のうち、rea の取り方の `~/.agents/skills/<名前>` の削除は直さない
- 出どころ: Claude の判断
- 理由: 末尾に `/` の無い `rm -rf` は、`~/.agents/skills/<名前>` がリンクならリンクだけを外し、リンクの先（claude-private など）は消さない。ほかの指摘（`update` の置き場の確かめ、MCP の登録の戻し、宣言の読みの標準入力、skills CLI の記録の場所、SKILL.md の権限、版の書き換えの順、brew の環境のテンプレート、先の無いリンクの比べ方）は直した。
- 状態: 有効

### 2026-11-28 採用: PR #134 を main へ取り込み、移行を進める
- 出どころ: 端末からの入力（会話 3eac4129、2026-11-28 19:56、発言 71d94cfd）
- 要旨（Claude の要約）: PR #134 を取り込んだので、設計書の追補の移行の順序の 2 から 5 を進める。
- 状態: 有効

### 2026-11-28 採用: 移行の apply は作業のファイルだけを名指しで配る
- 出どころ: Claude の判断
- 理由: `chezmoi status` に、この作業と関係ない `~/.config/tsuzuri/words.tsv` の違い（配置先の利用者の辞書を上書きしうる）と `pre-commit-config.bats` が出ていた。全体の `chezmoi apply` を避け、`~/.claude/external-skills.txt`、`~/.claude/hooks/claude-private-sync.sh`、`~/.local/bin/external-skills` だけを配り、`run_onchange_83` と同じ環境で `external-skills install` を自分で走らせた。`run_onchange_83` は次の全体の apply で一度走るが、冪等なので何も変えない。
- 状態: 有効

### 2026-11-28 採用: REA のスキルは npm のパッケージから写し、版は 6.9.0 のまま宣言する
- 出どころ: Claude の判断
- 理由: いまの claude-private の写しと MCP の登録がどちらも 6.9.0 で、版を上げるのは更新のコマンド（`external-skills update`）の役割。公式の `setup --skill-client` は `~/.claude/skills/` に直接置いて Codex の置き場とずれるので、パッケージの `skills/reverse-engineer-anything` を `~/.agents/skills/` へ写して `~/.claude/skills/` からリンクを張る（設計書が許す代わりの方法）。
- 状態: 有効

## いまの作業

なし（済み）。

## 済んだこと

- 既に着手したワークツリーやセッションが無いことを確かめた（判明した事実の 1 行目）。
- dotfiles の変更を PR #134 で main へ取り込んだ（6f54936）。設計書の追補、宣言ファイル、`external-skills`、同期フックの除外と掃除、クラウドの配布、`syncClaudeAiSkills: false`、文書、コードレビューとセキュリティの自動レビューの指摘の直しを含む。
- 本番の作業コピー（`~/.local/share/chezmoi`）を 6f54936 へ早送りした。ここで同期が止まった。
- claude-private から `skills/imozuru`、`skills/tsuzuri`、`skills/referent-first`、`skills/reverse-engineer-anything`、`skills/synced` を名指しで `git rm` し、1feb1ae で push した（269 ファイルの削除だけで、ほかの場所は含まない）。外す前の控えは `~/.cache/external-skills-migration/claude-private-skills-before.tgz`（元の HEAD は同じ置き場の `claude-private-HEAD-before`）。
- `~/.claude/skills/synced` のリンクを `trash-put` で外した。
- 3 ファイルを名指しで `chezmoi apply` し、`external-skills install` を走らせた。yomiyasu と herdr は「変わらず」、imozuru、tsuzuri、referent-first は skills CLI で入れ、reverse-engineer-anything は 6.9.0 を入れた（記録は `~/.cache/external-skills-migration/install.log`）。
- 確かめた: `~/.claude/skills/` の 6 つのリンクはどれも `../../.agents/skills/<名前>` を指す。MCP の登録 `rea` は 6.9.0 で、環境変数（`GHIDRA_INSTALL_DIR`、`JAVA_HOME`）が残っている。入れた REA の SKILL.md は claude-private の写しと同じ。`npx skills check -g` は imozuru と herdr を出さず、yomiyasu だけを「更新あり」と出した（上流が進んでいる。`external-skills update` の役割なので触っていない）。
- imozuru の常駐のページは、`systemctl --user restart imozuru-serve` の後、新しい置き場の `~/.claude/skills/imozuru/scripts/dashboard.py` で起動し、合言葉つきの要求に 200 で「imozuru 調査記録」を返した。
- 関係ない所で見つけた `chezmoi status` の 2 件を `ideas/bugs/2026-11-28-pre-commit-config-bats-deployed.md` に書いた。
- その 2 件を直した（端末からの入力（会話 3eac4129、2026-11-28 20:08、発言 971f13b2）の依頼）。`pre-commit-config.bats` は `.chezmoiignore` の直下の `.bats` の名指しから漏れていたので、`*.bats` で外す形にして PR #135 にした。`~/.config/tsuzuri/words.tsv` は PR #133 のソースの版が配られていなかっただけなので、控え（`~/.cache/external-skills-migration/words.tsv.before-apply`）を取って配った。

## 残っていること

- Claude.ai に上げた自作のスキルを Cowork とクラウドのセッションからも消すなら、リーダーが `claude.ai/customize/skills/yours` で消す（手元の Claude Code からはもう消えている）。

## 次に Claude がすること

- なし。

## リーダーに決めてほしいこと

なし

## 参照

- issue #90（2026-11-28 に PR #134 と作業記録へのリンクを添えて閉じた）
- PR #134
- 設計書: `docs/superpowers/specs/2026-11-13-external-skills-design.md`（2026-11-28 の追補を含む）
