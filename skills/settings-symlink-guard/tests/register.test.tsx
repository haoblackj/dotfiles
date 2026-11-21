import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { FsStat, On } from 'claude-code'

import type { Broken } from '../types'

const HOME = '/h'
const TARGET = '/h/.claude/settings.json'
const SOURCE = '/h/.local/share/chezmoi/linked/claude/settings.json'

const file = (over: Partial<FsStat> = {}): FsStat => ({
  kind: 'file',
  size: 10,
  mtimeMs: 0,
  isLink: false,
  ...over,
})

// テストの $ は Mod の $.state を読めないので、書き込みを state.set で写し取る
let written: Broken = null

type Files = Record<string, FsStat | undefined>

// テストの hook はエンジンの代わりに立つ。fs.stat はパスごとに files の値を返し、無ければ ENOENT
const engine = (on: On, files: Files, env: Record<string, string | undefined> = {}) => {
  const toasts: string[] = []
  written = null
  const clock = mock.clock(on, { now: 0 })
  on('state.set', (_, e, next) => {
    written = e.value as Broken
    return next(e)
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('env.get', (_, e) => {
    if (env.FAIL_ONCE === e.name) {
      delete env.FAIL_ONCE
      throw new Error('env.get failed')
    }
    return { value: { HOME, ...env }[e.name] }
  })
  // resolve を頼まれなければ realPath を返さない（本物の $.fs.stat と同じ）
  on('fs.stat', (_, e) => {
    const s = files[e.path]
    if (s === undefined) throw Object.assign(new Error(`ENOENT: ${e.path}`), { code: 'ENOENT' })
    if (e.resolve) return { value: s }
    const { realPath: _r, ...rest } = s
    return { value: rest }
  })
  on('ui.toast', (_, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  return { toasts, clock }
}

const start = ($: Engine) => $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

const band = {
  plugin: 'settings-symlink-guard',
  component: 'AbovePrompt',
  surface: 'terminal',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 20,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const

const compose = ($: Engine) =>
  $.prompt.compose({
    model: 'm',
    promptModel: 'm',
    surfaces: ['terminal'],
    tools: [],
    outputStyle: null,
    traits: [],
  } as never)

const linked: Files = {
  [TARGET]: file({ isLink: true, realPath: SOURCE }),
  [SOURCE]: file({ realPath: SOURCE }),
}

test('正しい symlink なら何も書かず、帯も出さない', async ($, on) => {
  const { toasts } = engine(on, linked)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  await start($)
  expect(written).toBe(null)
  expect(toasts).toEqual([])
  const ui = await $.ui.mount(band as never)
  expect((await ui.find({ type: 'Text', text: /engine/ }))?.text).toBe('engine')
  await ui.unmount()
})

test('通常のファイルなら帯に出し続け、トーストを一度出す', async ($, on) => {
  const { toasts } = engine(on, { [TARGET]: file({ realPath: TARGET }), [SOURCE]: file({ realPath: SOURCE }) })
  await start($)
  expect(written).toContain('通常のファイル')
  expect(toasts.length).toBe(1)
  const ui = await $.ui.mount(band as never)
  const row = await ui.find({ type: 'Text', text: /settings\.json/ })
  expect(row?.text).toContain('通常のファイル')
  await ui.unmount()
})

test('別の場所への symlink なら知らせる', async ($, on) => {
  engine(on, { [TARGET]: file({ isLink: true, realPath: '/elsewhere.json' }), [SOURCE]: file({ realPath: SOURCE }) })
  await start($)
  expect(written).toContain('別の場所')
})

test('リンク先が無い symlink なら知らせる', async ($, on) => {
  engine(on, { [TARGET]: file({ isLink: true, kind: 'other' }), [SOURCE]: file({ realPath: SOURCE }) })
  await start($)
  expect(written).toContain('リンク先が無い')
})

test('ファイルが無ければ知らせる', async ($, on) => {
  engine(on, { [SOURCE]: file({ realPath: SOURCE }) })
  await start($)
  expect(written).toContain('ファイルが無い')
})

test('ソースが無ければ、symlink が在っても正しいとは言わない', async ($, on) => {
  engine(on, { [TARGET]: file({ isLink: true, realPath: SOURCE }) })
  await start($)
  expect(written).toContain('ソースが無い')
})

test('CHEZMOI_SOURCE_DIR があれば、その下のソースと比べる', async ($, on) => {
  const other = '/src/linked/claude/settings.json'
  engine(on, { [TARGET]: file({ isLink: true, realPath: other }), [other]: file({ realPath: other }) }, { CHEZMOI_SOURCE_DIR: '/src' })
  await start($)
  expect(written).toBe(null)
})

test('クラウドのセッションでは調べずに黙る', async ($, on) => {
  const { toasts } = engine(on, {}, { CLAUDE_CODE_REMOTE: 'true' })
  await start($)
  expect(written).toBe(null)
  expect(toasts).toEqual([])
})

test('外れていれば、Claude への一節を末尾に足す', async ($, on) => {
  engine(on, { [TARGET]: file({ realPath: TARGET }), [SOURCE]: file({ realPath: SOURCE }) })
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'x', scope: 'shared' }] }) as never)
  await start($)
  const { sections } = await compose($)
  const last = sections.at(-1)
  expect(last?.id).toBe('settings-symlink-guard:broken')
  expect(last?.scope).toBe('session')
  expect(last?.text).toContain('docs/work/settings-symlink.md')
})

test('正しければ、Claude への一節を足さない', async ($, on) => {
  engine(on, linked)
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'x', scope: 'shared' }] }) as never)
  await start($)
  const { sections } = await compose($)
  expect(sections.map(s => s.id)).toEqual(['intro'])
})

test('セッションの途中で外れたら、一分ごとの確かめで気づく', async ($, on) => {
  const files: Files = { ...linked }
  const { toasts, clock } = engine(on, files)
  await start($)
  expect(written).toBe(null)
  files[TARGET] = file({ realPath: TARGET })
  await clock.advance(60_000)
  expect(written).toContain('通常のファイル')
  expect(toasts.length).toBe(1)
  await clock.advance(60_000)
  expect(toasts.length).toBe(1)
})

test('直れば帯を消す', async ($, on) => {
  const files: Files = { [TARGET]: file({ realPath: TARGET }), [SOURCE]: file({ realPath: SOURCE }) }
  const { clock } = engine(on, files)
  await start($)
  expect(written).toContain('通常のファイル')
  files[TARGET] = file({ isLink: true, realPath: SOURCE })
  await clock.advance(60_000)
  expect(written).toBe(null)
})

// 読み込み直しでは session.start が来ず、前の $.clock.every は止まる（plugin-authoring の reference.md）
test('session.start を経ずに帯が描かれても、一分ごとの確かめを始める', async ($, on) => {
  const { clock } = engine(on, { [TARGET]: file({ realPath: TARGET }), [SOURCE]: file({ realPath: SOURCE }) })
  const ui = await $.ui.mount(band as never)
  await clock.advance(60_000)
  expect(written).toContain('通常のファイル')
  await ui.unmount()
})

test('session.start が二度来ても、トーストは一度', async ($, on) => {
  const { toasts, clock } = engine(on, { [TARGET]: file({ realPath: TARGET }), [SOURCE]: file({ realPath: SOURCE }) })
  await start($)
  await start($)
  await clock.advance(60_000)
  expect(toasts.length).toBe(1)
})

test('外れ方が変わったら文だけ直し、トーストは重ねない', async ($, on) => {
  const files: Files = { [TARGET]: file({ realPath: TARGET }), [SOURCE]: file({ realPath: SOURCE }) }
  const { toasts, clock } = engine(on, files)
  await start($)
  delete files[TARGET]
  await clock.advance(60_000)
  expect(written).toContain('ファイルが無い')
  expect(toasts.length).toBe(1)
})

test('開始時の確かめが失敗しても、一分ごとの確かめは続ける', async ($, on) => {
  const { clock } = engine(on, { [TARGET]: file({ realPath: TARGET }), [SOURCE]: file({ realPath: SOURCE }) }, { FAIL_ONCE: 'CLAUDE_CODE_REMOTE' })
  await start($)
  await clock.advance(60_000)
  expect(written).toContain('通常のファイル')
})

test('HOME が読めなければ、正しいとは言わずにそう知らせる', async ($, on) => {
  engine(on, linked, { HOME: undefined })
  await start($)
  expect(written).toContain('HOME')
})
