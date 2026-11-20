---
title: Herdr 時代の仕掛けを戻せる形で外し、Orca で Zenn の記事と同じ運用を組む
status: waiting
---

## 目的

Herdr で組んでいた仕掛けを、戻せる形で外す。
そのうえで、Zenn の記事「毎月6,000 AI Agentsを捌くためにキーボードを捨てた話」（andoshin11、2026-11-17）と同じことを Orca でできるようにする。
記事の三つの柱は、エージェントのタスクの進捗をサイドバーに出す、エージェントの質問と次の作業の候補をサイドバーに出す、候補を押すだけで指示を送る、の三つ。
ウォッチやスマートフォンへの通知は要らない（リーダーは Android を使っている）。

- 出どころ: 未確認（Orca のチャット画面からの入力。prts は端末の入力の形でないと判定した。この会話の依頼として従う）
- 要旨（Claude の要約）: 記事の内容が良かったので Orca を入れた。Herdr 時代の物を一度、手戻りできる形で断捨離し、Orca で記事と同じことができるようにセットアップしてほしい。ウォッチの通知は要らない。

## いまの方針

- 記事の筆者が公開している Orca のプラグイン orca-milestone（MIT）を土台にし、Windows の Orca と WSL の Claude Code の組み合わせで動くように手元で直して、Windows の Orca に開発フォルダとして読み込ませる。直した複製は手元の git（ブランチ `wsl-host`）に置き、GitHub へは上げていない。
- Herdr の断捨離は、Claude 側で Orca が置き換える物（CLAUDE.md の Herdr の決まり、Herdr で引き継ぐスキルとスクリプト、フックの文面）に絞り、`main` から切ったブランチ `feat/orca-from-herdr` の PR にする。戻すときは、タグ `herdr-era-final`（移す前の `main`）か PR の revert で戻す。
- Herdr の本体、常駐の設定、Claude Code への組み込みフック、Herdr の設定とプラグイン、タブ名の同期は、それを使う手元の別の道具（prts）を Orca へ移すまで残す。その移し替えは、別のセッションに渡した。
- 別の作業が承認待ちで載せている本番の作業コピー（`~/.local/share/chezmoi`）のブランチには触らない。この PR の変更は、`main` に入り、本番の作業コピーが `main` に移ってから `chezmoi apply` で配られる。

## 判明した事実

- Orca のデスクトップは Windows、Claude Code は WSL の中で動いている（根拠: 端末からの入力（会話 3c33ee18、2026-11-21 01:37、発言 32f6cf50）と、`ps` に出る `~/.orca-remote/orcad-*/orcad.js`）。
- プラグインのワーカーは Windows の Orca 本体の子プロセスとして動き、`HOME` は Windows のホームになる。WSL の中の orcad にはプラグインのサービスが無く、WSL の `orca plugin list` は「Plugin service is not available on this runtime」を返す（根拠: stablyai/orca の `docs/site/content/docs/settings.mdx` の「Plugin workers always run on this computer」、`src/main/plugins/workers/parent-process/plugin-host-process.ts` の `fork`、`src/main/runtime/rpc/methods/plugins/plugins.ts` の `requirePluginService`）。
- プラグイン API に、WSL や SSH の先のファイルを読む口は無い（根拠: `docs/reference/plugin-host-api.md` の一覧）。
- Windows の Orca の CLI（`%LOCALAPPDATA%\Programs\orca\resources\bin\orca.cmd`）で `worktree ps --environment "Ubuntu (WSL)" --json` を打つと、WSL のワークツリーとエージェント（状態、`lastAssistantMessage`、`toolName` など）が Linux のパスのまま返る。ただしこの経路では、どのワークスペースにも `isActive` が付かない（2026-11-21 に実測）。
- `--environment` を付けない `worktree ps` は、ワークツリーを 0 件返し、`hostScope.omittedHostSelectors` で `--environment Ubuntu (WSL)` を案内する（2026-11-21 に実測）。
- orca-milestone（コミット 637620c8、v0.9.0）のうち、Windows で動くと壊れる箇所: `~/.claude` の読み先（`homedir()`）、セッションの生死の判定（`process.kill(pid, 0)`）、同梱 CLI の探し方（macOS のパス）、起動時に足す許可のフックと Codex の MCP（Windows の `Orca.exe` のパスを WSL のエージェントへ渡す）、「最新の指示で再開」（`ps` を叩く）。
- Orca の組み込みでも、チャット画面は AskUserQuestion をカードで出す。「次の作業の候補」を押して送る機能は組み込みに見つからない（根拠: `docs/site/content/docs/agents/native-chat.mdx`）。
- prts は Herdr の本体と、Herdr の Claude Code への組み込みフックを使っている。消した引き継ぎのスクリプトは呼んでいない（根拠: 入っている prts のソース）。
- Windows から WSL の `/proc/<pid>` と `~/.claude/sessions` が `\\wsl.localhost\Ubuntu\...` で読める（2026-11-21 に実測）。
- `orca plugin dev load` の承認は、Claude Code の自動の判定に止められた。プラグインに権限を与える承認はリーダーが行う。
- Windows の Node で `\\wsl.localhost` のフォルダに `fs.watch` を掛けると、`EISDIR` が同期で投げられる（2026-11-21 に実測）。元のプラグインのままだと、ワーカーの起動が失敗したまま固まり、サイドバーに何も出ない。
- Windows の Node で、直したワーカーを偽の Orca の口と偽のホームにつないで起動すると、同梱の CLI に `resources\bin\orca.exe` が選ばれ、フォーカスの補いと本物の CLI の状態で、ゴールとタスク（1 / 3）が描かれた。1 回の更新は CLI 込みで 460 ミリ秒（2026-11-21 に実測）。
- 本物のホームでは、ファイルだけの更新が 1 回 550 ミリ秒かかる。`~/.claude/sessions` の 162 個のファイルを読み、それぞれの pid を `/proc` で確かめるため。タスクの一覧のフォルダ（28 個）の名前と更新時刻を見るだけなら 11 ミリ秒で、rename で書き換えたタスクにも 0.1 秒ほどで気づく（2026-11-21 に実測）。
- 本物の Windows の Orca では、ワーカーに `APPDATA` が渡らず、同梱の CLI が `runtime_unavailable`（Orca のランタイムの置き場を引けない）で失敗する。補って渡すと通る（2026-11-21 に実測）。
- 本物の Orca では、プラグイン API の `workspace.list` が WSL のワークスペースを一件も返さない。`workspace.readContext` の `workspaceId` は `orca worktree ps` の `worktreeId` と同じ形（`<リポジトリの id>::<パス>`）で返る。`workspace.open` は WSL のワークスペースを開けず、`orca worktree activate --environment` も Windows の画面のフォーカスを動かさない。パネルの行を押して WSL のワークスペースへ移る機能は、いまの Orca では作れない（2026-11-21 に実測）。
- デスクトップの起動フック（`agent.launch.before`）は、CLI から `--environment` で WSL のランタイムへ頼んだ起動には効かない。起動した Claude の引数に指示が無く、`CLAUDE_CODE_ENABLE_TODO_TOOLS` も無かった（2026-11-21 に実測）。Orca の画面から起動したときに効くかは未確認。
- 指示を付けて起動した Sonnet（エフォート low）は、道具を 10 回使う作業でもタスクを作らず、`next` のブロックだけを書いた。「タスクに分けて進めて」と頼むとタスクを作り、パネルの「ほかのワークスペース」に進捗（1 / 3 から 3 / 3）が出た（2026-11-21 に実測）。
- Herdr に依存する物: 本体（`run_once_80` の Brewfile）、systemd の override、`dot_config/herdr/`（設定とローカルのプラグイン 2 つ）、`run_once_83`（agent skill）、`run_once_84`（プラグイン 7 つ）、`run_once_86`（Claude Code の組み込みフック `herdr-agent-state.sh`）、`run_onchange_after_90`、タブ名の同期のフック、引き継ぎのスクリプト 3 本（`session-handoff.sh`、`loop-handoff.sh`、`herdr-closable.sh`）と `herdr-start-claude.sh`、スキル `session-handoff`、`loop-guard.sh` と `chat-context-guard.sh` の文面、`statusline-context-window.sh` からのタブ名の同期の呼び出し、CLAUDE.md の「Herdr でのセッションの立て方」の節と関連の行、README の節、`docs/herdr-cheatsheet.html`、earlyoom の除外の一覧。Herdr の常駐（`homebrew.herdr.service`）はいま動いていない。

## 判断の経緯

### 2026-11-21 採用: PR #98 の取り込みは、戻せる操作ならリーダーの承認があるとして、別のセッションで進める
- 出どころ: 端末からの入力（会話 3c33ee18、2026-11-21 03:22、発言 406c4255）
- 要旨（Claude の要約）: 戻せる物なら承認してよい。本番のブランチに載っている試しの 2 コミットは、担当のセッションに扱わせる。
- 理由: 理由の提示なし。Claude の判断として、試しの 2 コミットは「dotfiles 用語言い換え防止」のセッションに伝え、#98 の取り込みは本番の作業コピーに新しく立てたセッションに渡した。新しく公開する物（消しても戻せない）と、リーダー本人の名義の approve や dismiss は、この承認に入らないと読んで、そのセッションに確かめさせる。
- 状態: 有効

### 2026-11-21 採用: 全体の設定の `CLAUDE_CODE_ENABLE_TODO_TOOLS` だけは、取り込みを待たずに手元へ効かせる
- 出どころ: 端末からの入力（会話 3c33ee18、2026-11-21 02:32、発言 742aebd4）
- 要旨（Claude の要約）: settings.json だけは先に適用してよい。ほかは取り込みまで待つ。
- 理由: 理由の提示なし。Claude の判断として、`~/.claude/settings.json`（いまは symlink でなく実体のファイル）に一行足すだけにし、本番の作業コピーには書かず、`chezmoi re-add` もしない。控えは `~/.cache/orca-from-herdr/settings.json.before-todo-tools`。PR #99 の取り込みの前に `chezmoi apply` を走らせると、この一行は消える。
- 状態: 有効

### 2026-11-21 採用: 記事と同じく、全体の設定と CLAUDE.md にもタスクの道具と指示を入れる
- 出どころ: Claude の判断
- 理由: 起動フックは CLI からの起動に効かず、画面からの起動に効くかも未確認。記事の筆者も `~/.claude/CLAUDE.md` と `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` で入れている。全体に入れれば起動のしかたによらず効く。フックと二重になっても害は無い。
- 状態: 有効

### 2026-11-21 採用: WSL ではタスクの一覧を 3 秒おきに見て、変わったときだけ更新する
- 出どころ: Claude の判断（審査の指摘を受けて）
- 理由: Windows は WSL の共有の変更通知を受けられず、`fs.watch` が例外を投げる。毎回まるごと更新すると 1 回 550 ミリ秒かかるが、一覧の更新時刻だけなら 11 ミリ秒で済む。エージェントの状態は Orca のイベントで、セッションの終わりは 30 秒おきの同期で拾える。
- 状態: 有効

### 2026-11-21 採用: prts は仕組みとして残し、Herdr のうち prts が使う物は外さない
- 出どころ: 端末からの入力（会話 3c33ee18、2026-11-21 01:50、発言 75071a0d）
- 要旨（Claude の要約）: prts は別の作業で要るので、仕組みとして残したい。
- 理由: prts は Herdr の本体と組み込みフックを使っている（判明した事実）。
- 状態: 有効

### 2026-11-21 採用: prts を Orca で動くようにする仕事を、Orca の道具で別のセッションに分ける
- 出どころ: 端末からの入力（会話 3c33ee18、2026-11-21 01:51、発言 e399603b）
- 要旨（Claude の要約）: 必要に応じて Orca の道具を使って分業してよい。
- 理由: prts の移し方はそのリポジトリの設計で、リーダーとの対話が要る。Claude の判断として、`orca worktree create --agent claude` で prts のリポジトリに新しいワークツリーを切って渡した。進み具合はそのリポジトリの作業記録にある。
- 状態: 有効

### 2026-11-21 採用: 本番の作業コピーが載っている別の作業のブランチには触らず、使える物は読んで取り込む
- 出どころ: 端末からの入力（会話 3c33ee18、2026-11-21 01:40、発言 7c2ada73）
- 要旨（Claude の要約）: 別の作業のブランチには触れない。再利用できる物は再利用してよい。
- 理由: 理由の提示なし
- 状態: 有効

### 2026-11-21 採用: 記事のプラグイン orca-milestone を手元で WSL 向けに直して使う
- 出どころ: Claude の判断
- 理由: 記事の三つの柱をそのまま実装した既製品で、MIT。ただしワーカーが Windows で動くため、そのままでは WSL の `~/.claude` を読めない。直す箇所は読み先、CLI の呼び方、フォーカスの補い、生死の判定、Windows のパスを渡す二つの機能の停止に限られる。
- 状態: 有効

### 2026-11-21 棄却: Orca の組み込みの機能だけで済ませる
- 理由: 質問のカードは組み込みにあるが、タスクの進捗のサイドバーと、次の作業の候補を押して送る機能が無く、記事の三つの柱のうち二つが欠ける。
- 状態: 有効

## いまの作業

PR #99 は審査の指摘を直し終え、取り込みの判断を待っている。

## 済んだこと

- 記事の原文の取得と、Orca のプラグインと WSL の関係の調査。
- orca-milestone の WSL 向けの直し（手元の複製の 3d40e8c から 86ab9f8。テスト 97 件が通る）。リーダーの承認で Windows の Orca に読み込まれ、`running` になった。
- 実機で確かめたこと: フォーカス中のワークスペースの表示、ほかのワークスペースのタスクの進捗、エラーの無いログ、次の作業のカードを押すと依頼文がそのまま WSL の Claude に届くこと（2026-11-21、リーダーが押した）。試しのターミナルは閉じた。
- 断捨離の PR #99。フックのテスト 293 件が通る。タグ `herdr-era-final` を移す前の `main`（5f91b0e）に打った。審査（With fixes）の指摘を直した。
- PR #98 が main に入った（275dd27）ので、origin/main をこのブランチへマージし（14ffd55）、衝突は main の版にこの PR の直しを当て直して解いた。CLAUDE.md は 199 行。
- 載せ直した差分の審査（With fixes）を受け、`--prompt` と `orca terminal send` で渡す文をスラッシュコマンドと試しの検証に限り、引き継ぎの文面は SendMessage で送る決まりに直した（984259a）。`--prompt` で立てた三つのセッションには、初めのプロンプトは Claude の文でリーダーの入力ではないと伝えた。
- Orca が手元に書いたフックの設定（`~/.claude/settings.json` の agent-hooks の 16 か所）とキーの割り当て（`ctrl+alt+g`）をソースへ取り込んだ（d51515c）。設定のつながりの試験は、Orca の PostCompact のフックを許すように直した。フックの試験 294 件、pytest 203 件が通る。
- 全体の設定の `CLAUDE_CODE_ENABLE_TODO_TOOLS` を手元の `~/.claude/settings.json` に効かせた。
- 全体の設定に `CLAUDE_CODE_ENABLE_TODO_TOOLS`、CLAUDE.md に記事の指示（タスクの記録と `next` のブロック）を足した（PR #99）。CLAUDE.md は 199 行。
- prts を Orca へ移す仕事を、別のセッションに渡した。

## 残っていること

- Orca の画面から起動した Claude に起動フックが効くかの確かめ（効かなくても、PR #99 の取り込みのあとは CLAUDE.md の指示で補われる）。
- PR #98 の取り込み（本番の作業コピーに立てた別のセッションが進めている）。入ったら、PR #99 を新しい `main` に載せ直し、衝突を解いて、テストと審査をやり直す。
- 断捨離の PR の取り込み（リーダー）。本番の作業コピーが載っている別の作業のブランチも、CLAUDE.md の同じ行（ループの引き継ぎ、対話セッションの引き継ぎ、Herdr の節、決定論的処理の節）を書き換えている。後から取り込む側で衝突を解き、取り込んだあとに `git grep -E "loop-handoff|session-handoff|herdr-closable|herdr-start-claude"` が昔の計画書と作業記録の外で 0 件になることを確かめる。
- 本番の作業コピーが `main` に移ったあとの `chezmoi apply`（`.chezmoiremove` が配布先のスクリプトとスキルを消し、CLAUDE.md の追加が効く）。
- `~/.claude/settings.json` が symlink でなくなった件は、別のセッション（chezmoi のワークツリー `settings-symlink`）が調べている。
- prts が Orca へ移ったあと（別のセッションが進めている）、Herdr の残り（本体、常駐の設定、組み込みフック、設定とプラグイン、タブ名の同期）を外す。

## 次に Claude がすること

- 載せ直した差分の審査の指摘を受けて直し、リーダーに PR #99 の取り込みを頼む。取り込まれたら、本番の作業コピーで試しの未コミットの変更（`dot_claude/CLAUDE.md`、`dot_claude/output-styles/exusiai.md`）を持ち越したまま main の先端へ移し、`chezmoi apply` の結果を確かめる。

## リーダーに決めてほしいこと

- PR #99 を main に取り込むか。Claude の案: 取り込む（審査の指摘は直し、試験は通っている）。取り込んだら、本番の作業コピーで試しの未コミットの変更を持ち越したまま main の先端へ移し、`chezmoi apply` の結果を確かめる。
- 直したプラグインを GitHub に上げるか。Claude の案: 上げない（手元の git だけ）。上げると別のマシンでも使えるが、自分のアカウントに他人のコードの改変を公開することになる。答えで何が変わるか: 上げるなら、フォークを作って `wsl-host` を push する。

## 参照

- 記事: https://zenn.dev/andoshin11/articles/ba68b39ef9a8ce
- プラグイン: https://github.com/andoshin11/orca-milestone
- タグ: `herdr-era-final`（移す前の `main`）
