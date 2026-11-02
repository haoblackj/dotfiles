# セッションの Issue へのリンクを出す Mod の設計

2026-11-02

## 目的と経緯

Claude Code の画面に、いまのセッションが関わっている GitHub の Issue へのリンクを出し、クリック一つでブラウザで開けるようにする。

リーダーは Issue 単位でセッションを立てていて、作業中の Issue をブラウザで開く場面が多い。
これまでの道具は二つあったが、どちらもほぼ働いていなかった。

- ステータスラインの `Issue#N PR#N`（`dot_config/ccstatusline/executable_issue-pr-links.sh`）。番号をブランチ名から拾うが、最近のブランチ名（`worktree-bg-progress-band` など）は番号を含まないので空振りする。ステータスラインのコマンドが出す OSC 8 のリンクは Claude Code の全画面描画が剥がすので、番号の文字だけを出していた。
- Herdr の `prefix+g`（`dot_config/herdr/plugins/local/open-github/`）。同じくブランチ名から番号を拾う。リーダーの判断で「働いていない」。

足りないのは「このセッションの Issue はどれか」という情報と、クリックできるリンクの二つ。
Mod はセッションの中の出来事（プロンプト、ツールの呼び出し）を見られるので前者を拾え、描画の部品 `Link` で後者を出せる。

## 目標

- このセッションに出てきた Issue を、クリックで開けるリンクとして画面に出し続ける。
- リンクの文字は `#73 タイトルの先頭十文字`（リーダーの案）。
- 画面の行を増やさない。
- 全マシンで使えるよう、dotfiles で配る。

## 目標でないもの

- Issue の中身（状態コメントなど）をターミナルに出すこと。リーダーは「サブ的な立ち位置で構わない」とした。
- PR のリンク。リーダーが不要とした。
- 「いまの Issue を一つに決める」こと。セッションは Issue 単位で立てるが、途中で株分けされた Issue が増えることがあるので、関わった Issue を並べる。

## 失敗とみなすもの

- 入力欄の上や下に一行増える（リーダーが「邪魔」とした）。
- エンジンがもともと出している表示（モードの表示など）が消える。リーダーは「入れ替わるのはいいけど、元のものも出してほしい」とした。
- リンクが URL の文字のまま出て、行が長くなる。

## 実機で確かめたこと（使い捨ての試作、2026-11-02）

試作の Mod を Herdr のタブの中の Claude Code（全画面描画）で読み込み、次を確かめた。

1. `ui.render` の `next(e)` が返すエンジンの描画（`{ type: 'engine', ref }`）を、Mod の `Box` の中に置ける。エンジンの表示を残したまま、横に要素を足せる。
2. `PromptHint`（入力欄の下の `(shift+tab to cycle)` の行）に足すと、Mod の要素はその行の右ではなく、モードの表示の下の新しい行に回り込んだ。
3. `SessionMode`（モードの表示の部品）に足すと、要素はステータスラインの行（リーダーの画面では使用量の行、別のタブでは一行目のモデル名の行）の右端に並び、行は増えなかった。リーダーはこの位置で可とした。`props.modes` が空でもこの部品は描かれる。
4. Herdr の中では、Claude Code が端末をリンク非対応と判断し、`Link` を「文字のあとに URL を dim で」という代わりの形で描く。Herdr は文字の URL をクリックで開くので開きはするが、URL のぶん行が長くなる。
5. 環境変数 `FORCE_HYPERLINK=1` を付けて起動すると、`Link` は OSC 8 のリンクになり、`#73` の文字だけが出て、クリックでブラウザが開いた（Herdr 0.9.5）。

## 決まったこと

### 表示

`SessionMode` の `ui.render` に割り込み、`next(e)` の描画を残したまま、その右に Issue のリンクを並べる。

```
<エンジンのモードの表示> · #73 対話セッションの引き · #75 gh の本文に手書き
```

- 区切りは dim の ` · `。
- リンクの文字は `#<番号> <タイトルの先頭十文字>`。タイトルが取れていなければ `#<番号>` だけ。
- 別のリポジトリの Issue は `<repo名>#<番号>` にする（いまのリポジトリと同じなら repo 名を省く）。
- 並びは、最後に出てきた順（新しいものが左）。出す数には上限を置き、収まらない分は省く。
- Issue が一つもなければ `next(e)` をそのまま返し、何も足さない。

### リンクを本物にする

`linked/claude/settings.json` の `env` に `FORCE_HYPERLINK=1` を入れる。
設定の `env` で効くことは実機で確かめた（2026-11-02、Herdr のタブで `--settings` に `{"env":{"FORCE_HYPERLINK":"1"}}` を渡すと `· #73` だけが出て、渡さないと `· #73 https://github.com/...` と URL が文字で出た）。
zsh で `export` する案は、Claude Code 以外のコマンドまで OSC 8 を出すようになるので採らない。
README に、この設定が何のためにあるかを書く。

### 拾う Issue

次の三つから拾う。

1. リーダーのプロンプト（`prompt.submit`）。引き継ぎの指示もプロンプトとして届くので同じ道で拾う。本文の GitHub の Issue の URL（`https://github.com/<owner>/<repo>/issues/<N>`）と、`#<N>` の形の番号。
2. セッション中に立てた Issue。`gh issue create` の出力に出る Issue の URL。
3. 書き込んだか読んだ Issue。`gh issue comment <N>`、`gh issue edit <N>`、`gh issue close <N>`、`gh issue view <N>`、`gh api repos/<owner>/<repo>/issues/<N>/...` のように、Bash のコマンドで Issue を名指ししたもの。読むだけの命令も拾うのは、セッションの始めに状態コメントを読む命令（グローバルの CLAUDE.md の `gh api .../issues/<N>/comments`）がそのセッションの Issue を指すから（計画を書くときのあたしの判断）。

番号だけで repo が書かれていないときは、セッションのいまのリポジトリ（git の `origin` が GitHub を指すもの）の Issue とみなす。
GitHub を指す `origin` が無いリポジトリでは、番号だけのものは拾わない。
`/pull/<N>` の URL と `gh pr` のコマンドは拾わない。

拾った Issue のタイトルは、拾った時点で一度だけ GitHub の API（`repos/<owner>/<repo>/issues/<N>`）から取って覚える。
API の答えに `pull_request` があれば PR なので、一覧から外す（Issue と PR は番号を共有するので、`#<N>` や `/issues/<N>` で PR を拾いうる）。

採用の条件は出どころで分ける（作り手の確認を受けたあたしの判断）。

- URL とコマンドから拾ったもの：タイトルが取れなくても番号だけで出す。取り直しはしない。書かれた形から Issue であることがほぼ確かなので。
- プロンプトの裸の `#<N>`：タイトルが取れて、PR でないと分かったときだけ出す。散文の番号（「手順 #3」など）を誤って拾っても、存在しない番号なら画面に残らない。オフラインや権限のないリポジトリでは出ないことを受け入れる。

同じ Issue がまた出てきたら、並びの先頭（左）へ移す（最後に出てきた順。あたしの判断）。

拾った一覧はセッションをまたいで残す（`--resume` で戻ったときに消えないように）。

### 撤去するもの

- `dot_config/ccstatusline/executable_issue-pr-links.sh` と、`dot_config/ccstatusline/settings.json` の `issue-pr-links` の部品。
- `dot_config/ccstatusline/github-refs.sh`（ブランチ名から番号を拾う関数。使う側は上の二つだけ）。
- `dot_config/herdr/plugins/local/open-github/` と、`dot_config/herdr/config.toml` の `prefix+g` のキー割り当てと、その上のコメント。
- 手元の Herdr に link 済みの `local.open-github` を外す手順。`run_once_84_herdr-plugins.sh.tmpl` には open-github の link が無いので、既存のマシンでは手で外す必要がある。外し方を README に書き、このマシンでは実際に外す。
- README の、これらへの言及。

### 配り方

`bg-progress` と同じ形にする。

- 実体はリポジトリ直下の `skills/issue-link/`（`.claude-plugin/plugin.json`、`hooks/hooks.json`、`hooks/register.tsx` と分けたモジュール、`tests/`、必要なら `types/index.d.ts`）。
- `dot_claude/skills/symlink_issue-link.tmpl` で `~/.claude/skills/issue-link` へ symlink する。
- `SKILL.md` を持たないので `install-cloud.sh` はクラウドへ写さない。クラウドの画面は Herdr の端末ではなく、`FORCE_HYPERLINK` の前提も違う。
- README の「公開の自作スキル」の表に一行足す。

## 作り手に任せること

- Issue を拾う正規表現の細部と、誤って拾う形（コードの中の `#123`、色の `#fff` など）の避け方。プロンプトの `#<N>` は、前が英数字でなく、後ろが数字で終わるものに限るなど。
- 出す数の上限（三つ前後を目安）。
- API の呼び方（`$.process.run` で `gh api`、または `$.http.fetch`）。Mod のプロセスの環境には、Bash に入る bot の `GH_TOKEN` が無いことがある。`gh` が手元の認証で読めればよい（読むだけなので名義は問わない）。
- 状態を `$.state` と `$.store` のどちらに、どの鍵で置くか（セッション ID を鍵に含める）。
- モジュールの分け方。抽出（文字列から Issue を拾う純粋な関数）は描画から分け、単体テストを書く。

## 確かめ方

- 抽出の関数の単体テスト（プロンプトの URL と番号、`gh issue create` の出力、`gh issue comment` などのコマンド、拾ってはいけない形）。
- `claude plugin validate` と `claude plugin test`。
- 実機: Herdr のタブで Claude Code を立て、Issue の URL を含むプロンプトを一つ送り、使用量の行の右に `#<N> <タイトル>` のリンクが出て、クリックでブラウザが開くこと。`FORCE_HYPERLINK` を設定の側で入れたときに効いていること。
