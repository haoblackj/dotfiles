# 背景の処理の進捗の帯 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude が背景で始めた長い処理（ダウンロード、一括の推論）を道具で登録すると、入力欄の上の帯に何％と JST の終了時刻を出す Mod `bg-progress` を作り、dotfiles で配る。

**Architecture:** 計算と書式は副作用の無い `progress.ts` に集め、`register.tsx` が道具の登録、数秒おきの測定（`du` と `wc` を `$.process.run` で呼ぶ）、帯の描画、通知の検知、システムプロンプトの一節をつなぐ。登録は `$.state` の atom に持ち、測定のたびに書き換えて帯を描き直す。

**Tech Stack:** Claude Code の Mod（TypeScript の hooks module、`claude plugin validate` / `claude plugin test`）、chezmoi。

**Spec:** `docs/superpowers/specs/2026-11-02-bg-progress-band-design.md`

## Global Constraints

- Mod の名前は `bg-progress`。実体はリポジトリ直下の `skills/bg-progress/`。
- dotfiles は公開リポジトリ。Mod のコードと文面に、cbr の中身や個人の情報を入れない。
- 時刻はマシンのタイムゾーンに関係なく JST（UTC+9）で出す。
- 帯の一行の形: `⬇ <名前>  <割合>%  [<バー10桁>]  <済んだ量>/<全体>  <速さ>  残り <残り時間> → <HH:MM> JST`。名前は cyan、割合と終了時刻は bold、量と速さは dimColor。
- 帯は 5 本まで。超えたら 5 行目を `ほか N 本` にする。登録が無ければ `next(e)` を返して帯を出さない。
- 停滞の判定は 60 秒。速さは直近 30 秒の増え方から出す。測定の間隔は 4 秒。
- 完了のトースト: `✔ <名前> 完了（<全体>、<所要時間>）`。止まったときのトースト: `✖ <名前> 止まった（<割合>%）`。
- 一時ファイルは `/tmp` に置かない（scratchpad を使う）。
- コミットはパスを名指しする（既存ファイルは `git commit -- <パス>`、新規は `git add -N -- <パス>` を 1 ファイルずつしてから `git commit -- <パス>`）。`git commit -a` と裸の `git commit` は使わない。
- Mod の API は `/home/yagu001/.cache/cc-tmp/claude-1000/bundled-skills/2.1.312/31deb94f470d1e4b65226a1c52023b3e/plugin-authoring/` の `reference.md`、`types/claude-code.d.ts`、`examples/` を正とする（パスはセッションごとに変わる。無ければ `plugin-authoring` スキルを読み込み直して出たパスを使う）。

## Review Focus

- 測る場所がまだ無い（ダウンロードの開始前、`run_vlm.py` が出力を作る前）: 0 として扱い、帯は 0% で出る。測定の失敗で帯が消えたり Mod が落ちたりしない。→ Task 2 のテスト `測る場所が無ければ 0 として数える`
- 全体の量を少なく渡した、または既に全体以上ある場所を登録した: 登録の直後の測定で完了のトーストが出て帯から外れる（誤登録はすぐ見える）。→ Task 2 のテスト `登録の時点で全体に届いていれば完了にする`
- 登録の直後で測定が 1 回しかない: 速さが出せないので、終了時刻の代わりに `測定中` と出す（0 除算で `Infinity` や `NaN` を出さない）。→ Task 1 のテスト `標本が一つなら測定中`
- 同じ背景タスクの通知が届いたが、量は全体に届いていた（照合などで処理が長引いた）: 止まったではなく完了として扱う。→ Task 3 のテスト `通知の時点で全体に届いていれば完了`
- Mod を読み込み直した（編集や再起動）: 登録は `$.state` に残るので、`session.start` で測定のタイマーを張り直す。→ Task 2 のテスト `読み込み直しで測定を再開する`

---

### Task 1: 計算と書式（`progress.ts`）と Mod の骨組み

**Files:**
- Create: `skills/bg-progress/.claude-plugin/plugin.json`
- Create: `skills/bg-progress/hooks/hooks.json`
- Create: `skills/bg-progress/types/index.d.ts`
- Create: `skills/bg-progress/hooks/progress.ts`
- Create: `skills/bg-progress/hooks/register.tsx`（この Task では `export const register: Register = () => {}` だけ）
- Test: `skills/bg-progress/tests/progress.test.ts`

**Interfaces:**
- Produces（`types/index.d.ts`）:
  ```ts
  export type Unit = 'bytes' | 'lines'
  export type Sample = { at: number; amount: number }   // at はエポックミリ秒
  export type Job = {
    name: string
    paths: string[]
    unit: Unit
    total: number
    taskId?: string
    startedAt: number
    samples: Sample[]        // 直近 60 秒ぶんだけ持つ
    lastGrowthAt: number     // 量が最後に増えた時刻
  }
  declare module 'claude-code' { interface PluginState { 'bg-progress': { jobs: Job[] } } }
  ```
- Produces（`hooks/progress.ts`、すべて純粋な関数）:
  - `amountOf(job: Job): number` 最後の標本の量（標本が無ければ 0）
  - `rateOf(samples: Sample[], now: number, windowMs = 30_000): number` 窓の中の最古と最新の標本の差を秒で割った単位/秒。窓の中に標本が 2 つ未満なら 0。
  - `isStalled(job: Job, now: number, stallMs = 60_000): boolean`
  - `formatJst(ms: number): string` `HH:MM`
  - `formatDuration(sec: number): string` 3600 秒以上は `1時間12分`、未満は `8分`（最小 `1分`）
  - `formatAmount(unit: Unit, done: number, total: number): string` bytes で全体が 1e9 以上なら `7.8/12.6 GB`（1e9 で割って小数 1 桁）、未満なら `329/345 MB`（1e6 で割って整数）。lines は `143/260 件`。
  - `formatRate(unit: Unit, perSec: number): string` bytes は `9.8 MB/s`（1e6、小数 1 桁）、lines は `0.8 件/s`（小数 1 桁）
  - `bar(ratio: number, width = 10): string` `█` を `floor(ratio*width)` 個、残りを空白
  - `type Row = { name: string; percent: number; bar: string; amount: string; rate: string; tail: string }`
  - `rowOf(job: Job, now: number): Row` `percent` は `floor(100*amount/total)` を 0〜100 に丸める。`tail` は停滞中なら `停滞中`、速さが 0 なら `測定中`、それ以外は `残り <formatDuration> → <formatJst> JST`。
  - `rowsOf(jobs: Job[], now: number, max = 5): { rows: Row[]; more: number }` `jobs.length > max` なら先頭 `max - 1` 本と `more = jobs.length - (max - 1)`。
  - `parseTaskNotifications(text: string): { taskId: string; status: string }[]` `<task-notification>` の塊ごとに `<task-id>` と `<status>` を抜く。

- [ ] **Step 1: 骨組みの 4 ファイルを書く**

`plugin.json` は `{ "name": "bg-progress", "version": "0.1.0", "description": "背景の処理の進捗と JST の終了時刻を入力欄の上に出す", "types": "./types/index.d.ts" }`。`hooks.json` は `{ "modules": ["./register.tsx"] }`。

- [ ] **Step 2: 失敗するテストを書く**（`claude-code/testing` の `test` と `expect`）

```ts
test('JST の時刻', () => { expect(formatJst(Date.UTC(2026, 10, 2, 7, 24))).toBe('16:24') })
test('日付をまたぐ JST', () => { expect(formatJst(Date.UTC(2026, 10, 2, 15, 5))).toBe('00:05') })
test('残り時間の書式', () => {
  expect(formatDuration(30)).toBe('1分'); expect(formatDuration(480)).toBe('8分')
  expect(formatDuration(4320)).toBe('1時間12分')
})
test('量と速さの書式', () => {
  expect(formatAmount('bytes', 7.8e9, 12.6e9)).toBe('7.8/12.6 GB')
  expect(formatAmount('bytes', 329e6, 345e6)).toBe('329/345 MB')
  expect(formatAmount('lines', 143, 260)).toBe('143/260 件')
  expect(formatRate('bytes', 9.8e6)).toBe('9.8 MB/s'); expect(formatRate('lines', 0.8)).toBe('0.8 件/s')
})
test('速さは直近 30 秒の増え方', () => {
  const s = [{ at: 0, amount: 0 }, { at: 40_000, amount: 100 }, { at: 60_000, amount: 300 }]
  expect(rateOf(s, 60_000)).toBe(10)        // 40s→60s の 200 を 20 秒で割る（0s は窓の外）
})
test('標本が一つなら測定中', () => {
  const job = { /* total 100、samples [{at:0,amount:10}]、lastGrowthAt 0 */ }
  expect(rowOf(job, 1_000).tail).toBe('測定中')
})
test('60 秒増えなければ停滞中', () => { /* lastGrowthAt 0、now 60_000 で isStalled が true、rowOf の tail が '停滞中' */ })
test('残りと終了時刻', () => {
  // total 12.6e9、標本 {at:now-20_000, amount:7.6e9} と {at:now, amount:7.8e9}（10 MB/s）→ 残り 480 秒
  // tail は `残り 8分 → ${formatJst(now + 480_000)} JST`、percent は 61、bar は '██████    '
})
test('6 本なら 4 本とほか 2 本', () => { expect(rowsOf(six, 0).rows.length).toBe(4); expect(rowsOf(six, 0).more).toBe(2) })
test('通知からタスク ID と状態を抜く', () => {
  const text = '<task-notification>\n<task-id>bq1</task-id>\n<status>failed</status>\n</task-notification>'
  expect(parseTaskNotifications(text)).toEqual([{ taskId: 'bq1', status: 'failed' }])
})
```

- [ ] **Step 3: テストが落ちることを確かめる**

Run: `claude plugin test skills/bg-progress`
Expected: FAIL（`progress.ts` の関数が無い）

- [ ] **Step 4: `progress.ts` の関数を Interfaces のとおり実装する**

`formatJst` は `new Date(ms + 9*3600*1000)` の `getUTCHours` と `getUTCMinutes` を 2 桁に埋める（`Intl` に頼らない）。

- [ ] **Step 5: テストと検証と型の検査を通す**

Run: `claude plugin test skills/bg-progress && claude plugin validate skills/bg-progress && tsc -p skills/bg-progress`
Expected: テストがすべて PASS、validate が `✔ Validation passed`（README と LICENSE と icon の警告は残ってよい）、tsc がエラー無し。`tsc -p` が `.claude-plugin/types/` の無さで通らないときは、`plugin-authoring` の types の冒頭にある tsconfig を scratchpad に置いて検査する。

- [ ] **Step 6: コミット**（新規ファイルは 1 つずつ `git add -N -- <パス>`、`git commit -- <パス…>`）

`feat: 背景の処理の進捗の帯の計算と書式を足す`

---

### Task 2: 登録の道具と測定（`register.tsx`、`measure.ts`）

**Files:**
- Create: `skills/bg-progress/hooks/measure.ts`
- Modify: `skills/bg-progress/hooks/register.tsx`
- Test: `skills/bg-progress/tests/register.test.tsx`

**Interfaces:**
- Consumes: Task 1 の `Job`、`Sample`、`amountOf`、`formatAmount`、`formatDuration`。
- Produces（`measure.ts`）:
  - `parseDu(stdout: string): number` `du -sb` の各行の先頭の数を足す。
  - `parseWc(stdout: string): number` 先頭の数。空なら 0。
  - `measure($: EngineInterface, paths: string[], unit: Unit): Promise<number>` bytes は `$.process.run(['du', '-sb', '--', ...paths])`、lines は `$.process.run(['sh', '-c', 'find "$@" -type f -exec cat -- {} + 2>/dev/null | wc -l', 'sh', ...paths])`。終了コードが 0 でなくても stdout を読む（無いパスは数えないだけ）。`du -sb` は隠しディレクトリ（`hf download` の `.cache/huggingface/download/*.incomplete`）も数える。
- Produces（`register.tsx`）:
  - atom `jobs = atom({ plugin: 'bg-progress', key: 'jobs' } as const, [] as Job[])`
  - 道具 `mcp__bg-progress__watch`（`isDeferred: false`）。入力 `{ name: string; paths: string[]; unit: 'bytes' | 'lines'; total: number; taskId?: string }`、`required: ['name', 'paths', 'unit', 'total']`。`paths` が空か `total <= 0` なら `isError` の結果で断る。同じ `name` は置き換える。登録の直後に 1 回測り、答えは `登録した: <name>（<今の量>/<全体>）`。
  - 道具 `mcp__bg-progress__unwatch`（`isDeferred: false`）。入力 `{ name: string }`。帯から外して `外した: <name>`。無ければ `登録が無い: <name>`。
  - `tick($)`: 全登録を測って標本を足し（60 秒より古い標本は捨てる）、量が増えていれば `lastGrowthAt` を更新し、全体に届いた登録を外して完了のトーストを出す（`$.ui.toast(text, { timeoutMs: 8000 })`）。登録が空になったらタイマーを止める。
  - タイマーは `$.clock.every(4000, ...)` を一つだけ持つ（モジュールの変数）。`watch` と `session.start`（登録が残っていれば）で張る。

道具の説明文（`watch` の `description`、そのまま使う）:

```
背景で始めた長い処理（ダウンロード、一括の推論など）の進捗を、入力欄の上の帯に何％と JST の終了時刻で出す。背景の Bash を起動して結果が返った後に呼び、その結果の backgroundTaskId を taskId に渡す。paths にはこの処理だけが書き込むディレクトリかファイルを渡す（hf download なら --local-dir、curl なら出力先）。unit は、ファイルの大きさで測るなら bytes、行を足していく出力なら lines。total は処理が終わったときに paths が達する量（bytes ならファイルの合計の大きさ、lines なら行数）。同じ name で呼び直すと置き換わる。
```

- [ ] **Step 1: 失敗するテストを書く**

エンジンの代わりに、テストで `process.run`（`{ value: { exitCode: 0, stdout, stderr: '' } }` を返す）、`tool.register`、`ui.toast`、時計（`mock.clock`）に答える。テスト名と確かめること:
- `parseDu は各行を足す`: `'100\ta\n250\tb\n'` → 350
- `測る場所が無ければ 0 として数える`: `process.run` が `{ exitCode: 1, stdout: '', stderr: 'No such file' }` を返すとき、`watch` が断らずに登録し、答えが `登録した: x（0.0/1.0 GB）` で始まる（`total` 1e9）
- `登録の時点で全体に届いていれば完了にする`: `du` が全体以上を返すと、`watch` の直後に `✔ x 完了` で始まるトーストが出て、`jobs` が空
- `増え続ければ標本が溜まり、全体に届けば完了`: 時計を 4 秒ずつ進め、`du` の答えを増やしていくと、届いた回で完了のトーストが一度だけ出る
- `同じ名前は置き換える`: 同じ `name` で二度 `watch` すると `jobs` は 1 件で、`total` が二度目の値
- `unwatch で外れる`
- `読み込み直しで測定を再開する`: `state.get` で登録を 1 件返し、`session.start` の後に時計を進めると `process.run` が呼ばれる

- [ ] **Step 2: テストが落ちることを確かめる**（`claude plugin test skills/bg-progress`、FAIL）

- [ ] **Step 3: `measure.ts` と `register.tsx` を Interfaces のとおり実装する**

- [ ] **Step 4: テスト、validate、tsc を通す**（Task 1 の Step 5 と同じコマンド、同じ合格の印）

- [ ] **Step 5: コミット** `feat: 背景の処理を登録して数秒おきに測る道具を足す`

---

### Task 3: 帯の描画、途中終了の検知、システムプロンプトの一節

**Files:**
- Modify: `skills/bg-progress/hooks/register.tsx`
- Test: `skills/bg-progress/tests/register.test.tsx`

**Interfaces:**
- Consumes: Task 1 の `rowsOf`、`parseTaskNotifications`、`formatAmount`。Task 2 の `jobs`、`measure`。
- Produces:
  - `on('ui.render', { component: 'AbovePrompt' }, ...)`: `e.props.hasSurvey` か登録が空なら `next(e)`。それ以外は `rowsOf(jobs, now)` を縦の `Box` に一行ずつ `Text` で並べ（Global Constraints の形と色）、`more > 0` なら `ほか N 本` を dimColor で足す。
  - `on('prompt.submit', ...)`: `e.origin.kind === 'task-notification'` のときだけ `parseTaskNotifications(e.text)` を読み、`taskId` が合う登録ごとに 1 回測る。全体に届いていれば完了のトースト、届いていなければ `✖ <名前> 止まった（<割合>%）` のトーストを出し、どちらでも帯から外す。いつも `next(e)` を返す（会話には手を出さない）。
  - `on('prompt.compose', ...)`: `next(e)` の `sections` の末尾に `{ id: 'bg-progress:guide', scope: 'session', text }` を足す。

一節の文面（そのまま使う）:

```
# 背景の処理の進捗
数分以上かかる処理（モデルのダウンロード、ローカル LLM の一括の推論など）を背景の Bash で始めたら、結果が返った直後に mcp__bg-progress__watch で登録する。進捗と JST の終了時刻が入力欄の上に出て、リーダーが終わりの見当をつけられる。全体の量は起動の前に調べておく（Hugging Face のファイルなら https://huggingface.co/api/models/<repo>/tree/main の size を足す。問いを一つずつ書き出す処理なら問いの数）。処理を途中で止めたら mcp__bg-progress__unwatch で外す。
```

- [ ] **Step 1: 失敗するテストを書く**
- `帯は一本一行`: 登録 2 件を `state.get` で与え、`terminal` と `desktop` で `AbovePrompt` を mount すると、`⬇ a` と `⬇ b` の Text があり、`62%` と `JST` を含む
- `登録が無ければ帯を出さない`: 下で答えるテストの `ui.render` の Text（`engine`）が描かれる
- `失敗の通知で止まったと出す`: `taskId: 'bq1'` の登録がある状態で、`origin.kind: 'task-notification'`、`<task-id>bq1</task-id><status>failed</status>` の `prompt.submit` を流すと `✖ a 止まった（` で始まるトーストが出て、`jobs` が空
- `通知の時点で全体に届いていれば完了`: 同じ流れで `du` が全体を返すと `✔ a 完了` のトースト
- `ほかのタスクの通知では外さない`: `<task-id>other</task-id>` では `jobs` が残る
- `一節を末尾に足す`: `prompt.compose` の結果の最後の section の `id` が `bg-progress:guide`

- [ ] **Step 2: テストが落ちることを確かめる**

- [ ] **Step 3: 三つのフックを Interfaces のとおり実装する**

- [ ] **Step 4: テスト、validate、tsc を通す**

- [ ] **Step 5: コミット** `feat: 進捗の帯を描き、背景タスクの途中終了で外す`

---

### Task 4: 配り方（symlink、読み込みの確認、README、クラウド）

**Files:**
- Create: `dot_claude/skills/symlink_bg-progress.tmpl`（中身は `{{ .chezmoi.sourceDir }}/skills/bg-progress`、既存の `symlink_bug-note.tmpl` と同じ形）
- Modify: `README.md` の「公開の自作スキル」の節（172 行目付近）と、クラウドの表（403 行目付近）
- 必要なら Modify: `linked/claude/settings.json`（`env` の `CLAUDE_CODE_PLUGIN_DIRS`）

- [ ] **Step 1: symlink のテンプレートを書いてコミット** `feat: bg-progress を ~/.claude/skills へ配る`

- [ ] **Step 2: `~/.claude/skills/` からの自動の読み込みを確かめる**

グローバルの CLAUDE.md の「対話セッションでの実機検証」に従い、Herdr の検証用タブで確かめる。scratchpad に作業ディレクトリを作り、`~/.claude/skills/bg-progress` をワークツリーの `skills/bg-progress` への symlink として一時的に置いてから、タブで `claude` を起動し、`/mcp` か道具の一覧に `mcp__bg-progress__watch` が出るかを見る。
出なければ `SKILL.md` の有無を変えて試し、それでも出なければ `linked/claude/settings.json` の `env` に `CLAUDE_CODE_PLUGIN_DIRS`（`~/.claude/skills/bg-progress`）を足す方式に切り替える。
終わったら一時の symlink を `trash-put` で外し、タブを閉じる。どちらの方式になったかを README に書く。

- [ ] **Step 3: クラウドでの扱いを確かめる**

`install-cloud.sh` は `SKILL.md` を持つ `skills/*/` だけを写す。Step 2 で `SKILL.md` を置いた場合はクラウドにも写る。置かなかった場合は、クラウドで要るかを判断材料（クラウドではモデルを落とす処理をほぼ回さない）とともに報告に書き、`install-cloud.sh` は変えない。`install-cloud.bats` を回して壊していないことを確かめる（`bats install-cloud.bats`、全件 ok）。

- [ ] **Step 4: README を書いてコミット** `docs: bg-progress の配り方と使い方を README に書く`

---

### Task 5: 実物での確認

Mod を読み込んだセッション（Task 4 の検証用タブ、または dev-mods の読み込み）で、実物の処理を登録して帯を見る。

- [ ] **Step 1: バイト数**: scratchpad の新しい空のディレクトリへ、数百 MB の公開ファイルを背景の Bash で `curl -L -o` で落とし、`watch`（unit `bytes`、全体は `curl -sIL` の `content-length`）で登録する。帯に割合、速さ、JST の終了時刻が出て、落ち終えたら完了のトーストが出て帯が消えることを見る。
- [ ] **Step 2: 行数**: 背景の Bash で 2 秒に 1 行ずつ 60 行を書くループを回し、`watch`（unit `lines`、全体 60）で登録する。途中で背景タスクを止め（`TaskStop`）、`✖ … 止まった` のトーストが出て帯が消えることを見る。
- [ ] **Step 3: 停滞**: 行数のループを `sleep 90` を挟む形で回し、60 秒後に `停滞中` が出ることを見る。
- [ ] **Step 4: 結果を報告に書く**（見えた帯の一行をそのまま写す）。落としたファイルは scratchpad に置いたまま、消すかはリーダーに確かめる。
