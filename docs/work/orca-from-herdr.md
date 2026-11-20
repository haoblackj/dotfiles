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
- Herdr に依存する物: 本体（`run_once_80` の Brewfile）、systemd の override、`dot_config/herdr/`（設定とローカルのプラグイン 2 つ）、`run_once_83`（agent skill）、`run_once_84`（プラグイン 7 つ）、`run_once_86`（Claude Code の組み込みフック `herdr-agent-state.sh`）、`run_onchange_after_90`、タブ名の同期のフック、引き継ぎのスクリプト 3 本（`session-handoff.sh`、`loop-handoff.sh`、`herdr-closable.sh`）と `herdr-start-claude.sh`、スキル `session-handoff`、`loop-guard.sh` と `chat-context-guard.sh` の文面、`statusline-context-window.sh` からのタブ名の同期の呼び出し、CLAUDE.md の「Herdr でのセッションの立て方」の節と関連の行、README の節、`docs/herdr-cheatsheet.html`、earlyoom の除外の一覧。Herdr の常駐（`homebrew.herdr.service`）はいま動いていない。

## 判断の経緯

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

プラグインの読み込みの承認をリーダーに頼み、断捨離の PR を出している。

## 済んだこと

- 記事の原文の取得と、Orca のプラグインと WSL の関係の調査。
- orca-milestone の WSL 向けの直し（手元の複製のコミット 3d40e8c。テスト 95 件が通る）。
- 断捨離のコミット（81ea792）。フックのテスト 293 件が通る。タグ `herdr-era-final` を移す前の `main`（5f91b0e）に打った。
- prts を Orca へ移す仕事を、別のセッションに渡した。

## 残っていること

- プラグインの読み込みの承認（リーダー）と、実機での確かめ（サイドバーにタスクの進捗、質問のカード、次の作業のカードが出て、押すと送られるか）。
- 断捨離の PR の取り込み（リーダー）と、本番の作業コピーが `main` に移ったあとの `chezmoi apply`（`.chezmoiremove` が配布先のスクリプトとスキルを消す）。
- Orca のチャット画面で起動したセッションにも起動フックが効くかの確かめ。効かなければ、`CLAUDE_CODE_ENABLE_TODO_TOOLS` と記事の指示を設定と CLAUDE.md に足す。
- prts が Orca へ移ったあと、Herdr の残り（本体、常駐の設定、組み込みフック、設定とプラグイン、タブ名の同期）を外す。

## 次に Claude がすること

- リーダーが承認したら、Windows の `orca.exe plugin list` で Milestone が有効なことを確かめ、新しい Claude Code のターミナルを立てて、サイドバーの表示と次の作業のカードの送信を試す。

## リーダーに決めてほしいこと

- プラグインの読み込みの承認。Claude の案: 承認する。権限は記事のプラグインの README と同じ範囲（ワーカーの実行、ワークスペースとエージェントの読み取り、ワークスペースを開く操作、起動直前のフック）。答えで何が変わるか: 承認まで、プラグインは読み込まれたまま何も動かない。
- 直したプラグインを GitHub に上げるか。Claude の案: 上げない（手元の git だけ）。上げると別のマシンでも使えるが、自分のアカウントに他人のコードの改変を公開することになる。答えで何が変わるか: 上げるなら、フォークを作って `wsl-host` を push する。

## 参照

- 記事: https://zenn.dev/andoshin11/articles/ba68b39ef9a8ce
- プラグイン: https://github.com/andoshin11/orca-milestone
- タグ: `herdr-era-final`（移す前の `main`）
