# セッションの Issue へのリンクを出す Mod 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** セッションに出てきた GitHub の Issue を、モードの表示の右にクリックできるリンク（`#73 タイトル先頭十文字`）として出す Mod を作り、ブランチ名から番号を拾っていた古い表示を撤去する。

**Architecture:** 文字列から Issue を拾う純粋な関数（`extract.ts`）と、出来事を受けて状態を持ち描画する hooks モジュール（`register.tsx`）に分ける。状態は `$.state` に置き、`$.store` にセッション ID の鍵で写して `--resume` に備える。タイトルと PR かどうかは `gh api` で一度だけ取る。

**Tech Stack:** Claude Code の Mod（TypeScript、`claude-code` と `claude-code/testing`）、chezmoi、ccstatusline、Herdr。

**Spec:** `docs/superpowers/specs/2026-11-02-issue-link-design.md`

## Global Constraints

- 実体は `skills/issue-link/`、配るのは `dot_claude/skills/symlink_issue-link.tmpl`（中身 `{{ .chezmoi.sourceDir }}/skills/issue-link`）。`SKILL.md` は置かない。
- リンクの文字は `#<番号> <タイトルの先頭十文字>`、タイトルが無ければ `#<番号>`。いまのリポジトリ以外は `<repo>#<番号> ...`。
- 区切りは dim の ` · `。
- 並びは最後に出てきた順（新しいものが左）。出す数の上限 `MAX_LINKS = 3`。
- href は `https://github.com/<owner>/<repo>/issues/<番号>`。
- `/pull/<N>` の URL と `gh pr` のコマンドは拾わない。API の答えに `pull_request` があれば外す。
- プロンプトの裸の `#<N>` は、タイトルが取れて PR でないと分かったときだけ出す。URL とコマンドから拾ったものは、取れなくても番号だけで出す。取り直しはしない。
- `linked/claude/settings.json` の `env` に `"FORCE_HYPERLINK": "1"`。
- chezmoi リポジトリのコミットはパスを名指しする（`git commit -- <パス>`、新規は `git add -N -- <パス>` を一つずつ）。
- 削除は `trash-put`（追跡済みのソースは `git rm`）。

## Review Focus

- コードや色を含むプロンプト（`` `#fff` ``、`&#123;`、`issue#12` のような語の中、`#issuecomment-123`）：誤って拾わない。`extract.test.ts` の「拾わない形」で押さえる。
- GitHub を指す `origin` が無い cwd（`no git`、GitLab の remote）：裸の番号は拾わず、URL だけ拾う。`extract.test.ts` で押さえる。
- `gh` が失敗する（オフライン、未認証、30 秒の打ち切り）：例外で hook を落とさず、出どころの規則どおりに扱う。`register.test.tsx` で押さえる。
- 同じ Issue が URL と番号の両方で出る：一つにまとめ、先頭へ移す。`extract.test.ts` の `mergeFound` で押さえる。
- 読み込み直し（hot reload）と `--resume`：一覧が消えない。`register.test.tsx` で `store.get` に前の値を置いて押さえる。

---

### Task 1: 文字列から Issue を拾う関数

**Files:**
- Create: `skills/issue-link/hooks/extract.ts`
- Create: `skills/issue-link/types/index.d.ts`
- Test: `skills/issue-link/tests/extract.test.ts`

**Interfaces:**
- Produces（`types/index.d.ts`）:
  - `type RepoRef = { owner: string; repo: string }`
  - `type Source = 'url' | 'command' | 'bare'`
  - `type Found = RepoRef & { number: number; source: Source }`
  - `type Entry = RepoRef & { number: number; source: Source; title: string | null; status: 'pending' | 'shown' }`（`pending` は API の答え待ちで描かない）
  - `PluginState` に `'issue-link': { entries: Entry[] }`
- Produces（`extract.ts`）:
  - `repoOfRemote(remote: string | null): RepoRef | null` — `git@github.com:o/r(.git)`、`https://github.com/o/r(.git)`、`ssh://git@github.com/o/r(.git)` を読む。GitHub 以外と null は null。
  - `fromPrompt(text: string, here: RepoRef | null): Found[]`
  - `fromBash(command: string, stdout: string, here: RepoRef | null): Found[]`
  - `mergeFound(entries: Entry[], found: Found[]): Entry[]` — 同じ owner/repo/number は一つにまとめて先頭へ。新しいものは `status` を `bare` なら `pending`、それ以外は `shown`、`title: null` で足す。既存の `shown` は `pending` に戻さない。`bare` で既にあるものの `source` は強い方（url/command）へ上げ、`pending` なら `shown` にする。found の中の順は、文字列の中で後に出たものほど左。
  - `keyOf(r: RepoRef & { number: number }): string` — `owner/repo#number`（大文字小文字は小文字にそろえる）。

- [ ] **Step 1: 失敗するテストを書く**（`claude-code/testing` の `test`, `expect`）

  - `repoOfRemote`：上の三形式が `{ owner: 'haoblackj', repo: 'dotfiles' }`、`https://gitlab.com/a/b` と `null` が `null`。
  - `fromPrompt('https://github.com/haoblackj/dotfiles/issues/73 を見て', null)` → `[{ owner:'haoblackj', repo:'dotfiles', number:73, source:'url' }]`。
  - `fromPrompt('#73 と #75 の続き', here)` → 75 と 73 が `bare`、75 が先。
  - `fromPrompt('#73', null)` → `[]`。
  - 拾わない形：`'色は #fff'`、`'&#123;'`、`'issue#12'`、`'https://github.com/o/r/pull/5'`、`'https://github.com/o/r/issues/5#issuecomment-99'` は 5 だけ（url）で 99 は拾わない。
  - `fromBash('gh issue create --title x --body y', 'https://github.com/haoblackj/dotfiles/issues/80\n', here)` → 80 が `command`。
  - `fromBash('gh issue comment 73 --body-file f', '', here)` → 73 が `command`。`-R other/repo` と `--repo other/repo` が付けばその repo。
  - `fromBash('gh issue view 73', '', here)` と `fromBash("gh api repos/haoblackj/dotfiles/issues/73/comments --paginate | jq ...", '', null)` → 73 が `command`（状態コメントを読む命令もこのセッションの Issue を指すので拾う）。
  - `fromBash('gh pr view 5', 'https://github.com/o/r/pull/5', here)` → `[]`。
  - `fromBash('echo hi', 'https://github.com/o/r/issues/9', here)` → `[]`（`gh issue create` 以外の出力の URL は拾わない）。
  - `mergeFound`：既存 `[73 shown]` に `[75 bare, 73 url]` → `[75 pending, 73 shown]`；既存 `[73 pending bare]` に `[73 url]` → `[73 shown url]`。

- [ ] **Step 2: 走らせて失敗を見る**

  Run: `claude plugin test skills/issue-link`
  Expected: `extract` が無くて FAIL

- [ ] **Step 3: `extract.ts` を書く**

  裸の番号の正規表現は、前が英数字、`/`、`&`、`#` でなく、`#` の後が数字だけで、その後が英数字や `-` で続かないもの（`(?<![\w/&#])#(\d+)(?![\w-])`）。URL の部分（`https://...` の範囲）を先に取り除いてから裸の番号を探す。

- [ ] **Step 4: 走らせて通るのを見る**

  Run: `claude plugin test skills/issue-link`
  Expected: PASS

- [ ] **Step 5: コミット**（`git add -N -- <各新規ファイル>` の後 `git commit -- <パス…>`、見出し `feat: 文字列から Issue を拾う関数を足す（issue-link）`）

### Task 2: 出来事を受けて一覧を持ち、モードの表示の右に描く

**Files:**
- Create: `skills/issue-link/.claude-plugin/plugin.json`（`{ "name": "issue-link", "version": "0.1.0", "description": "セッションに出てきた GitHub の Issue へのリンクをモードの表示の右に出す", "types": "./types/index.d.ts" }`）
- Create: `skills/issue-link/hooks/hooks.json`（`{ "modules": ["./register.tsx"] }`）
- Create: `skills/issue-link/hooks/register.tsx`
- Test: `skills/issue-link/tests/register.test.tsx`

**Interfaces:**
- Consumes: Task 1 の全部。
- Produces: `export const register: Register`。

hooks の中身：

- `prompt.submit`：`e.command` が無く `e.isMeta` でもないとき、`fromPrompt(e.text, here)` を `mergeFound` で足す。`next(e)` は必ず呼ぶ（拾う処理の失敗で送信を止めない）。
- `tool.call`（`{ tool: 'Bash' }`）：`const ran = await next(e)` の後、`ran.deny` が無ければ `fromBash(e.command, ran.result?.stdout ?? '', here)` を足す。`ran` をそのまま返す。
- 足した後、`pending` か `title === null` のうち、まだ問い合わせていない鍵ごとに一度だけ `gh api repos/<o>/<r>/issues/<n> --jq '{title: .title, pr: (.pull_request != null)}'` を `$.process.run`（`timeoutMs: 10000`）で走らせる。問い合わせ済みの鍵はモジュールの `Set` に持つ（読み込み直しで消えてよい：消えたら一度だけ聞き直す）。
  - 成功して `pr: false`：`title` を入れ、`pending` を `shown` に。
  - 成功して `pr: true`：一覧から外す。
  - 失敗（終了コード非零、例外、JSON にならない）：`bare` の `pending` は外す。ほかはそのまま。
- `here` は `$.session.repo()` の `remote` を `repoOfRemote` に通したもの。
- 一覧は `atom({ plugin: 'issue-link', key: 'entries' }, [])`。書くたびに `$.store.set('entries:' + await $.session.id(), list)` へも写す。`session.start` で atom が空なら store から戻す。
- `ui.render`（`{ component: 'SessionMode' }`）：`shown` を先頭から `MAX_LINKS` 件。無ければ `next(e)` を返す。あれば `<Box flexDirection="row">{await next(e)}<Text dimColor> · </Text><Link href=...>ラベル</Link>...</Box>`（リンク同士も ` · ` で区切る）。ラベルは Global Constraints の形、タイトルは `[...title].slice(0, 10).join('')`（サロゲートを割らない）。

- [ ] **Step 1: 失敗するテストを書く**（`skills/bg-progress/tests/register.test.tsx` の、hook でエンジンの代わりを立てる型に倣う。`process.run` は argv を記録して決めた答えを返す。`session.repo` は `{ value: { root: '/r', remote: 'git@github.com:haoblackj/dotfiles.git', internal: false, ownerRepo: null } }` を返す。描画は `$.ui.mount({ component: 'SessionMode', props: { modes: [] }, ... })` で、エンジンの代わりの `ui.render` hook が `<Text>MODE</Text>` を返す）
  - `issue URL のプロンプトでリンクが出る`：URL のプロンプト → `gh api` が `{"title":"対話セッションの引き継ぎと掃除","pr":false}` → `Link` の href が `https://github.com/haoblackj/dotfiles/issues/73`、文字が `#73 対話セッションの引き継ぎ`、`MODE` も残る。
  - `裸の番号は PR なら出ない`：`#5` → `pr: true` → `Link` が無い、`MODE` だけ。
  - `裸の番号は gh が失敗したら出ない`：exitCode 1 → `Link` が無い。
  - `URL は gh が失敗しても番号だけで出る`：exitCode 1 → 文字が `#73`。
  - `別のリポジトリはリポジトリ名を付ける`：`https://github.com/haoblackj/penguinEx/issues/12` → 文字が `penguinEx#12 ...`。
  - `gh issue create の出力で足される`：`$.tool.call({ tool: 'Bash', command: 'gh issue create ...' })` に、エンジンの代わりの `tool.call` hook が stdout に URL を返す → リンクが出る。
  - `四つ目は省かれ、新しいものが左`：#1〜#4 の URL を順に送る → リンクは #4、#3、#2 の順で三つ。
  - `store の前の値から戻る`：`store.get` が `[Entry 73 shown]` を返す → `session.start` 後にリンクが出て、`gh api` は呼ばれない（タイトルがあるもの）。
  - `何も無ければエンジンの描画だけ`：`Link` が無く `MODE` がある。

- [ ] **Step 2: 走らせて失敗を見る**

  Run: `claude plugin test skills/issue-link`
  Expected: register の各テストが FAIL

- [ ] **Step 3: `register.tsx` と `plugin.json`、`hooks.json` を書く**

- [ ] **Step 4: 走らせて通るのを見る、検査も通す**

  Run: `claude plugin test skills/issue-link && claude plugin validate skills/issue-link`
  Expected: 全部 PASS、validate は README と LICENSE と icon の警告だけ（bg-progress と同じ）

  型の検査：Mod が一度読み込まれて `skills/issue-link/.claude-plugin/types/` ができていれば `tsc -p skills/issue-link`。無ければ bg-progress と同じ扱いでよい（`.claude-plugin/types/` が gitignore されているかを `git check-ignore` で確かめ、されていなければ bg-progress に倣う）。

- [ ] **Step 5: コミット**（見出し `feat: セッションの Issue のリンクをモードの表示の右に出す（issue-link）`）

### Task 3: 配る、リンクを本物にする、README

**Files:**
- Create: `dot_claude/skills/symlink_issue-link.tmpl`
- Modify: `linked/claude/settings.json`（`env` に `"FORCE_HYPERLINK": "1"`）
- Modify: `README.md`（「公開の自作スキル」の表に `issue-link` の一行。設定の `env` の説明があればそこに `FORCE_HYPERLINK` の理由を一行。クラウドに配らない表に一行）

- [ ] **Step 1: 三つを書き換える**

  README の `issue-link` の行：何を出すか、拾う三つの出どころ、`FORCE_HYPERLINK` が無いと Herdr の中では URL が文字で並ぶこと、設計書へのパス。

- [ ] **Step 2: 確かめる**

  Run: `bats dot_claude/hooks/tests/settings-wiring.bats`（settings.json を検査するテストがあれば通ること）、`jq . linked/claude/settings.json >/dev/null`
  Expected: PASS、JSON として読める

- [ ] **Step 3: コミット**（見出し `feat: issue-link を配り、Claude Code に FORCE_HYPERLINK を渡す`）

### Task 4: ブランチ名から番号を拾う古い表示を撤去する

**Files:**
- Delete（`git rm`）: `dot_config/ccstatusline/executable_issue-pr-links.sh`、`dot_config/ccstatusline/github-refs.sh`、`dot_config/herdr/plugins/local/open-github/`（三ファイル）
- Modify: `dot_config/ccstatusline/settings.json`（`id: "issue-pr-links"` の部品を外す）
- Modify: `dot_config/herdr/config.toml`（`prefix+g` の `[[keys.command]]` とその上の二行のコメントを外す）
- Create: `.chezmoiremove`（ほかのマシンのターゲットから消す。`.config/ccstatusline/issue-pr-links.sh`、`.config/ccstatusline/github-refs.sh`、`.config/herdr/plugins/local/open-github`。先頭の `/` は付けない、`.chezmoiignore` の注意書きと同じ理由）
- Modify: `README.md`（これらへの言及を外し、Herdr に link 済みの `local.open-github` を `herdr plugin unlink local.open-github` で外す手順を書く）

- [ ] **Step 1: 書き換えと削除**

- [ ] **Step 2: 残りの参照が無いことを確かめる**

  Run: `git grep -n -e issue-pr-links -e github-refs -e open-github -e 'prefix+g' -- ':!docs/superpowers'`
  Expected: README の撤去の手順と `.chezmoiremove` だけ

  Run: `chezmoi --source . diff ~/.config/ccstatusline ~/.config/herdr 2>&1 | head -80`（本チェックアウトでなくワークツリーをソースにして、ターゲットへの差分を見るだけ。apply はしない）
  Expected: 部品の行、キー割り当て、三つのファイルの削除だけ

- [ ] **Step 3: コミット**（見出し `refactor: ブランチ名から Issue 番号を拾う表示と Herdr の prefix+g を撤去する`）

### Task 5: 実機で確かめる（マージ前）

- [ ] **Step 1:** Herdr のこのワークスペースに新しいタブを scratchpad の作業ディレクトリ（git の `origin` が `haoblackj/dotfiles` を指すよう、このワークツリーを cwd にしてもよい）で立て、`claude --plugin-dir skills/issue-link --settings <FORCE_HYPERLINK だけの settings>` で起動する。
- [ ] **Step 2:** プロンプトを一つ送る：`https://github.com/haoblackj/dotfiles/issues/73 のタイトルだけ答えて`（往復は一回）。
- [ ] **Step 3:** `herdr pane read <pane> --source visible` で、ステータスラインの行の右に `· #73 <タイトル先頭十文字>` が URL 無しで出ていることを見る。
- [ ] **Step 4:** タブを閉じる。結果を PR の説明に書く。
