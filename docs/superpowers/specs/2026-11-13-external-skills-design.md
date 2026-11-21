# 外から取ってくるスキルの管理の設計

2026-11-13

## 目的と経緯

外から取ってきたスキル（上流のリポジトリや npm のパッケージから入れるもの）を、取得元と版を書いた一つの宣言から入れ、更新し、他の機械でも同じものが入る形にする。

2026-11-13 に、外から取ってきたスキルとプラグインを最新へ上げた。
そのとき、入り方がスキルごとにばらばらで、管理の形として誤っているものがあると分かった。

- imozuru（`MaryCache/imozuru`）は 2026-10-21 に `npx skills add` で入れたが、実体が `~/.claude/skills/imozuru` に直接置かれた。1 分後に claude-private の同期フック（`dot_claude/hooks/executable_claude-private-sync.sh` の `migrate_new`）が「リンクでない実体のスキル」として claude-private へ取り込み、元を claude-private へのリンクに置き換えた。以後、skills CLI の記録（`~/.agents/.skill-lock.json`）は導入時のまま残り、`npx skills check -g` は「更新あり」と出し続ける。
- REA のスキル（`reverse-engineer-anything`、npm の `rea-agents` に同梱）も同じく claude-private の写しになっている。REA の MCP の登録（`~/.claude.json` の `rea`、`npx -y rea-agents@<版> mcp`）は手で書いた版の指定だけで、スキルの版との対応はどこにも書かれていない。上流の main はリリースより先に進む（2026-11-13 に 6.9.0 から 32 コミット先）ので、スキルはリポジトリの先端でなく、MCP と同じ版の npm のパッケージから取る必要がある。
- herdr のスキルは、chezmoi の `run_once_83_herdr-skill.sh.tmpl` が上流の先端から skills CLI で入れる。一方で運用の方針は「入っている herdr 本体の `herdr --skill` の出力を正本にする」（2026-09-07 に、上流の写しが本体の版と食い違って存在しないコマンドを案内していた）。入れ方と方針が食い違っている。
- yomiyasu は手元では skills CLI で入れているが、どこにも宣言されていない。クラウド向けには `cloud-skills.txt` に書いてある。

claude-private は「私的なスキルと著作権に触れるスキル」の置き場で、外から取ってきたスキルの置き場ではない。
取り込まれると上流の更新の手段が使えなくなり、更新のたびに手で写すことになる。

## 目標

- 外から取ってくるスキルを、一つの宣言ファイルに、名前、取り方、取得元、（必要なら）版で並べる。
- 宣言を読んで入れるスクリプトを chezmoi が走らせ、どの機械でも同じものが入る。
- 「最新へ上げる」を一つのコマンドにする。対象は宣言のスキルと、Claude Code のプラグイン（マーケットプレイスの目録の更新と各プラグインの更新）。
- claude-private の同期フックが、宣言に載ったスキルを取り込まない。
- imozuru と REA のスキルを claude-private から外し、宣言の形へ移す。
- クラウド向けの `cloud-skills.txt` を宣言ファイルへまとめ、一覧を一つにする。

## 目標でないもの

- herdr 本体の更新。本体は brew で入っていて、brew の管理に任せる。スキルは入っている本体から作り直すだけ。
- `book-to-skill`。すでに `.chezmoiexternal.toml` の git external で上流を追っていて、外から取ってくるものとしての管理になっている。
- プラグインの宣言。どのプラグインを入れるかは `linked/claude/settings.json` の `enabledPlugins` と `extraKnownMarketplaces` がすでに宣言している。この設計で足すのは更新のコマンドだけ。
- 更新を定期に自動で走らせること。走らせるのはリーダーか Claude が頼まれたときだけ。

## 失敗とみなすもの

- 外から取ってきたスキルが、また claude-private へ取り込まれる。
- REA のスキルと MCP の登録の版が食い違う。
- 宣言に載っていない私的なスキル（新しく作ったもの）が、claude-private へ取り込まれなくなる。今の同期フックの役割は残す。
- 更新のコマンドが、宣言に載っていないスキルや、claude-private のスキルに触る。

## 案

| 案 | 中身 | 利点 | 欠点 |
|---|---|---|---|
| A（採用） | 宣言ファイルを一つ置き、入れるスクリプトと更新のコマンドと同期フックがそれを読む | 取得元と版が一か所に残り、どの機械でも同じものが入る。更新が一本のコマンドで済む | 作る量が三案でいちばん多い |
| B | 同期フックだけを直し、imozuru と REA を公式の手段で入れ直す | 小さい | 他の機械での再現は手作業のまま。herdr の食い違いも残る |
| C | 同期フックの自動取り込みをやめ、私的なスキルは明示的に claude-private へ置く | 巻き込みが原理的に起きない | 新しい私的なスキルを置き忘れるとバックアップされない |

2026-11-13 にリーダーが A を選んだ。

## 設計

### 宣言ファイル

`dot_claude/external-skills.txt`（配置先は `~/.claude/external-skills.txt`）。
ホームへ配るのは、同期フックと更新のコマンドが chezmoi のソースの場所を知らずに読めるようにするため。

1 行に一つのスキルを、空白で区切って書く。`#` で始まる行はコメント。

```
<名前> <取り方> <取得元> [<追加の値>]
```

取り方は次の三つ。

| 取り方 | 取得元 | 追加の値 | 入れ方 | 最新へ上げる方法 |
|---|---|---|---|---|
| `skills` | GitHub の `owner/repo` | クラウドへも配るなら `cloud` | `npx skills add <owner/repo> --skill <名前> -g -y`。実体は `~/.agents/skills/<名前>`、`~/.claude/skills/<名前>` はそこへのリンク | `npx skills update -g <名前>` |
| `herdr` | `herdr`（本体のコマンド名） | なし | `herdr --skill` の出力を `~/.agents/skills/herdr/SKILL.md` へ書き、`~/.claude/skills/herdr` をそこへのリンクにする | 同じことをやり直す（本体が新しくなっていれば内容が変わる） |
| `rea` | npm のパッケージ名 `rea-agents` | 版（例 `6.9.0`） | その版のパッケージのスキルを入れ、MCP の登録 `rea` を `npx -y rea-agents@<版> mcp` にする（環境変数 `GHIDRA_INSTALL_DIR` と `JAVA_HOME` は今の登録の値を保つ） | `npm view rea-agents version` が宣言の版より新しければ、宣言の版を書き換えて入れ直す |

最初の中身は次のとおり。

```
yomiyasu skills nanaism/yomiyasu cloud
imozuru skills MaryCache/imozuru
herdr herdr herdr
reverse-engineer-anything rea rea-agents 6.9.0
```

`rea` の取り方の名前を REA 専用にしているのは、版と MCP の登録の対応という REA 固有の事情を持つからで、汎用の「npm から入れる」取り方は今は作らない。

### スクリプト

`dot_local/bin/executable_external-skills`（配置先は `~/.local/bin/external-skills`、bash）に、二つのサブコマンドを持たせる。

- `external-skills install`：宣言の各行を、宣言どおりの状態にする。入っていなければ入れ、`rea` の版が違えば入れ直す。冪等。
- `external-skills update`：プラグインのマーケットプレイスの目録を更新し（`claude plugin marketplace update`）、入っている各プラグインを更新する（`claude plugin update <名前>`）。続けて宣言の各行を最新へ上げる。`rea` の版を書き換えたときは、chezmoi のソース側の宣言ファイル（`chezmoi source-path ~/.claude/external-skills.txt` で場所を得る）を書き換え、コミットが要ることを最後に表示する。コミットはしない。
- どちらも、最後に何をどの版からどの版へ変えたかを一覧で表示する。

`run_onchange_83_external-skills.sh.tmpl` が `external-skills install` を走らせる。
宣言ファイルの中身のハッシュをテンプレートに埋め、宣言が変わったときに走り直させる。
これで `run_once_83_herdr-skill.sh.tmpl` を置き換え、消す。

### 同期フック

`dot_claude/hooks/executable_claude-private-sync.sh` を二点直す。

- `migrate_new`：`~/.claude/external-skills.txt` に載った名前のスキルは取り込まない。宣言ファイルが無いときは今と同じ動き。
- `ensure_symlinks`：`~/.claude/skills/` の下で、claude-private の中を指していて先が無いリンクを消す。claude-private からスキルを外したとき、他の機械に残るリンクを消すため。

### クラウド

`install-cloud.sh` は `cloud-skills.txt` の代わりに宣言ファイルを読み、取り方が `skills` で追加の値が `cloud` の行だけを、今と同じく浅い clone からの写しで配る。
リポジトリ内のスキルの場所は skills CLI と同じく探す（`skills/<名前>/SKILL.md` を既定とし、無ければ `.agents/skills/<名前>/SKILL.md`）。
`cloud-skills.txt` は消し、`install-cloud.bats` を合わせて直す。

### 移行

1. claude-private から `skills/imozuru` と `skills/reverse-engineer-anything` を `git rm` し、コミットして push する。
2. 手元の `~/.claude/skills/imozuru` と `~/.claude/skills/reverse-engineer-anything`（claude-private へのリンク）を外す。
3. `chezmoi apply` で宣言とスクリプトを配り、`external-skills install` で入れ直す。
4. `npx skills check -g` が imozuru と herdr を「更新あり」と出さないことと、`claude mcp get rea` の版が宣言と同じことを確かめる。

`linked/claude/settings.json` の `skillOverrides` の `"imozuru": "user-invocable-only"` は名前で効くので、そのまま残す。

### 文書

dotfiles の `README.md` の「公開と非公開の境界」と `CLAUDE.md` の置き場の表に、外から取ってくるスキルは宣言ファイルで管理し claude-private に置かないことを書き足す。
別のリポジトリの memory の `reference_herdr_skill_is_generated` は、`external-skills update` を案内する形に書き換える。

## 細部の決定（設計者の判断）

作り手の目での読み直しで出た問いに、設計者（Claude）が次のとおり決めた。
リーダーの決定ではないので、違えば直す。

- **skills CLI の記録の古い項目。**`herdr` の取り方の `install` は、`~/.agents/.skill-lock.json` に `herdr` の項目があれば jq で消す（実体はそのまま `herdr --skill` の出力で上書きする）。skills CLI に上流の先端と比べさせないため。imozuru は移行で `npx skills add` し直すと項目が書き直されるので、別の手当ては要らない。
- **`skills` の取り方の置き方。**`--copy` を付けず、skills CLI の既定のリンクの形で入れる（2026-11-13 の yomiyasu の更新で、`~/.claude/skills/yomiyasu` が `../../.agents/skills/yomiyasu` へのリンクのままであることを見た）。`install` は入れたあと `~/.claude/skills/<名前>` がリンクであることを確かめ、実体なら警告を出す。同期フックの除外は保険として残す。
- **更新するプラグインの一覧。**`claude plugin list --json` から取り、無効のものも含めて入っているもの全部を更新する。無効のものも、有効へ戻したときに古い版のまま動かないようにするため。
- **道具が無い機械と通信の失敗。**`install` は、`npx`、`herdr`、`claude` のうち要るものが無い行を、警告を出して飛ばす（今の `run_once_83` と同じ扱い）。通信の失敗は、その行を失敗として最後の一覧に出し、ほかの行は続ける。終了コードは、失敗した行があれば 1、無ければ 0（道具が無くて飛ばした行は失敗に数えない）。`run_onchange` からは `|| true` を付けずに呼び、失敗した回は chezmoi が次の apply で走り直させる。`update` も同じく、失敗した行を一覧に出して 1 で終える。
- **REA の MCP の登録。**`claude mcp remove rea -s user` と `claude mcp add-json rea '<JSON>' -s user` で作り直す（2026-11-13 にこの手順で 6.7.0 から 6.9.0 へ上げた）。環境変数は `claude mcp get rea` の出力から読んで引き継ぐ。登録が無い機械では、環境変数なしで登録し、Ghidra の場所を足すよう表示する。版の対応を保つことを優先し、登録は飛ばさない。
- **移行の順序。**dotfiles の変更（宣言、スクリプト、同期フック）を main へ入れて手元へ `chezmoi apply` してから、claude-private の `git rm` を push する。他の機械では `chezmoi update` が新しい同期フックと宣言を配り、`install` が走る。リンクの掃除は宣言ファイルの有無に関係なく `ensure_symlinks` が行うので、claude-private の pull と `chezmoi update` の前後どちらでも、次のセッションの開始で先の無いリンクは消える。
- **クラウドの取得元。**`skills` の取り方の取得元は GitHub の `owner/repo` に限り、`https://github.com/<owner>/<repo>.git` を組み立てる。リポジトリ内の場所は `skills/<名前>/SKILL.md`、無ければ `.agents/skills/<名前>/SKILL.md` を探し、どちらも無ければ今と同じく飛ばして記録に出す。場所を明示する書式は、合わないスキルが出てきたときに足す。
- **置き場。**`~/.local/bin` は手元の PATH にある。`run_onchange` からは `$HOME/.local/bin/external-skills` を絶対パスで呼ぶ。

## 作り手に任せること

- `skills` の取り方で、skills CLI に渡すエージェントの指定（`-a`）。今の記録（`lastSelectedAgents`）は 14 のエージェントで、Codex への委譲もあるので、少なくとも `claude-code` と `codex` を含める。
- `rea` のスキルの入れ方。公式の `npx rea-agents@<版> setup --skill-client claude_code -y` が非対話で通るならそれを使う（実体は `~/.claude/skills/reverse-engineer-anything` に直接置かれ、同期フックの除外で守られる）。通らなければ、パッケージの `skills/reverse-engineer-anything` を `~/.agents/skills/` へ写してリンクを張る。公式の `setup` の MCP の登録の部分（`--client`）は使わない。MCP の登録を npx のキャッシュの中の絶対パスへ書き換え、キャッシュが消えると起動しなくなるため（2026-11-13 に dry-run で確かめた）。
- テスト。`external-skills` と同期フックの変更に bats を書き、`npx`、`herdr`、`claude`、`npm` は偽物のコマンドで置き換える。偽物の出力の形は本物に合わせて確かめる。
