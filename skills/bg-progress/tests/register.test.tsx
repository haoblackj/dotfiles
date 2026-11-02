import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import type { Job } from '../types'
import { parseDu, parseWc } from '../hooks/measure'

const T0 = Date.UTC(2026, 10, 2, 7, 0)

// テストの $ は Mod の $.state を読めないので、書き込みを state.set の hook で写し取る。
let written: Job[] = []
// Mod が一度でも書いたか。書いた後は、空の一覧も Mod の値として扱う
let didWrite = false

// テストの hook はエンジンの代わりに立つ。process.run は du / wc の答えを返す。
const engine = (on: On, measured: { stdout: string; exitCode?: number }) => {
  const toasts: string[] = []
  const runs: string[][] = []
  written = []
  didWrite = false
  const clock = mock.clock(on, { now: T0 })
  on('state.set', (_, e, next) => {
    written = e.value as Job[]
    didWrite = true
    return next(e)
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.register', (_, e) => ({ value: { tool: `mcp__bg-progress__${e.name}` } }))
  on('process.run', (_, e) => {
    runs.push([...e.argv])
    return {
      value: {
        exitCode: measured.exitCode ?? 0,
        stdout: measured.stdout,
        stderr: '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }
  })
  on('ui.toast', (_, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  return { toasts, runs, clock }
}

// session.start と tool.register だけに答える（process.run を自前で答えるテスト用）
const bare = (on: On) => {
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.register', (_, e) => ({ value: { tool: `mcp__bg-progress__${e.name}` } }))
}

const start = ($: Engine) =>
  $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

const watch = ($: Engine, input: Record<string, unknown>) =>
  $.tool.call({ tool: 'mcp__bg-progress__watch', ...input } as never)

const jobsOf = async (_: Engine): Promise<Job[]> => written

test('parseDu は各行を足す', () => {
  expect(parseDu('100\ta\n250\tb\n')).toBe(350)
  expect(parseDu('')).toBe(0)
  expect(parseWc('  42\n')).toBe(42)
  expect(parseWc('')).toBe(0)
})

test('測る場所が無ければ 0 として数える', async ($, on) => {
  engine(on, { stdout: '', exitCode: 1 })
  await start($)
  const ran = await watch($, { name: 'x', paths: ['/none'], unit: 'bytes', total: 1e9 })
  expect(ran.deny).toBeUndefined()
  expect(String(ran.result)).toMatch(/^登録した: x（0\.0\/1\.0 GB）/)
  expect((await jobsOf($)).length).toBe(1)
})

test('paths が空か total が 0 以下なら断る', async ($, on) => {
  engine(on, { stdout: '' })
  await start($)
  expect((await watch($, { name: 'x', paths: [], unit: 'bytes', total: 1 })).deny).toBeDefined()
  expect((await watch($, { name: 'x', paths: ['/d'], unit: 'bytes', total: 0 })).deny).toBeDefined()
  expect((await jobsOf($)).length).toBe(0)
})

test('絶対パスでない paths は断り、何も測らない', async ($, on) => {
  const { runs } = engine(on, { stdout: '' })
  await start($)
  for (const p of ['-delete', 'rel/dir', '(']) {
    expect((await watch($, { name: 'x', paths: [p], unit: 'lines', total: 1 })).deny).toBeDefined()
  }
  expect(runs).toEqual([])
  expect((await jobsOf($)).length).toBe(0)
})

test('登録の時点で全体に届いていれば完了にする', async ($, on) => {
  const { toasts } = engine(on, { stdout: '2000000000\t/d\n' })
  await start($)
  await watch($, { name: 'x', paths: ['/d'], unit: 'bytes', total: 1e9 })
  expect(toasts.filter(t => t.startsWith('✔ x 完了')).length).toBe(1)
  expect((await jobsOf($)).length).toBe(0)
})

test('増え続ければ標本が溜まり、全体に届けば完了', async ($, on) => {
  const measured = { stdout: '0\t/d\n' }
  const { toasts, clock } = engine(on, measured)
  await start($)
  await watch($, { name: 'x', paths: ['/d'], unit: 'bytes', total: 1000 })
  measured.stdout = '400\t/d\n'
  await clock.advance(4000)
  const [job] = await jobsOf($)
  expect(job?.samples.length).toBe(2)
  expect(job?.lastGrowthAt).toBe(T0 + 4000)
  measured.stdout = '1000\t/d\n'
  await clock.advance(4000)
  await clock.advance(4000)
  expect(toasts).toEqual(['✔ x 完了（0 MB、1分）'])
  expect((await jobsOf($)).length).toBe(0)
})

test('60 秒より古い標本は捨てる', async ($, on) => {
  const measured = { stdout: '0\t/d\n' }
  const { clock } = engine(on, measured)
  await start($)
  await watch($, { name: 'x', paths: ['/d'], unit: 'bytes', total: 1e12 })
  for (let i = 1; i <= 20; i++) {
    measured.stdout = `${i}\t/d\n`
    await clock.advance(4000)
  }
  const [job] = await jobsOf($)
  expect(job?.samples.every(s => s.at >= clock.now() - 60_000)).toBe(true)
})

test('同じ名前は置き換える', async ($, on) => {
  engine(on, { stdout: '0\t/d\n' })
  await start($)
  await watch($, { name: 'x', paths: ['/d'], unit: 'bytes', total: 100 })
  await watch($, { name: 'x', paths: ['/d'], unit: 'bytes', total: 200 })
  const jobs = await jobsOf($)
  expect(jobs.length).toBe(1)
  expect(jobs[0]?.total).toBe(200)
})

test('unwatch で外れる', async ($, on) => {
  engine(on, { stdout: '0\t/d\n' })
  await start($)
  await watch($, { name: 'x', paths: ['/d'], unit: 'bytes', total: 100 })
  const ran = await $.tool.call({ tool: 'mcp__bg-progress__unwatch', name: 'x' } as never)
  expect(String(ran.result)).toBe('外した: x')
  expect((await jobsOf($)).length).toBe(0)
  const again = await $.tool.call({ tool: 'mcp__bg-progress__unwatch', name: 'x' } as never)
  expect(String(again.result)).toBe('登録が無い: x')
})

test('行数は sh で数える', async ($, on) => {
  const { runs } = engine(on, { stdout: '3\n' })
  await start($)
  await watch($, { name: 'v', paths: ['/runs/a'], unit: 'lines', total: 10 })
  expect(runs.at(-1)?.[0]).toBe('sh')
  expect(runs.at(-1)?.at(-1)).toBe('/runs/a')
  expect((await jobsOf($))[0]?.samples.at(-1)?.amount).toBe(3)
})

const band = (surface: 'terminal' | 'desktop') =>
  ({
    plugin: 'bg-progress',
    component: 'AbovePrompt',
    surface,
    props: {
      hasSurvey: false,
      isWorking: false,
      maxRows: 20,
      bodyColumns: 120,
      scroll: { offset: 0, bodyRows: 20 },
      view: {},
    },
  }) as const

const seeded = (over: Partial<Job> = {}): Job => ({
  name: 'a',
  paths: ['/d'],
  unit: 'bytes',
  total: 12.6e9,
  taskId: 'bq1',
  startedAt: T0 - 60_000,
  samples: [
    { at: T0 - 20_000, amount: 7.6e9 },
    { at: T0, amount: 7.8e9 },
  ],
  lastGrowthAt: T0,
  ...over,
})

// Mod が書き込むまで、前から在った登録として返す
const seed = (on: On, jobs: Job[]) =>
  on('state.get', (_, e, next) =>
    didWrite ? next(e) : { value: { value: jobs, version: 0 } },
  )

const notify = ($: Engine, body: string) =>
  $.prompt.submit({
    text: `<task-notification>${body}</task-notification>`,
    wait: false,
    origin: { kind: 'task-notification' },
  } as never)

test('帯は一本一行', async ($, on) => {
  seed(on, [seeded({ name: 'a' }), seeded({ name: 'b' })])
  engine(on, { stdout: '' })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount(band(surface) as never)
    const a = await ui.find({ type: 'Text', text: /⬇ a/ })
    const b = await ui.find({ type: 'Text', text: /⬇ b/ })
    expect(a?.text).toContain('61%')
    expect(a?.text).toContain('JST')
    expect(b).toBeDefined()
    await ui.unmount()
  }
})

test('6 本ならほか 2 本と出す', async ($, on) => {
  seed(on, ['a', 'b', 'c', 'd', 'e', 'f'].map(name => seeded({ name })))
  engine(on, { stdout: '' })
  const ui = await $.ui.mount(band('terminal') as never)
  expect((await ui.find({ type: 'Text', text: /ほか 2 本/ }))?.text).toContain('ほか 2 本')
  await ui.unmount()
})

test('登録が無ければ帯を出さない', async ($, on) => {
  engine(on, { stdout: '' })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  const ui = await $.ui.mount(band('terminal') as never)
  expect((await ui.find({ type: 'Text', text: /engine/ }))?.text).toBe('engine')
  await ui.unmount()
})

test('失敗の通知で止まったと出す', async ($, on) => {
  seed(on, [seeded()])
  const { toasts } = engine(on, { stdout: '7800000000\t/d\n' })
  on('prompt.submit', (_, e) => ({ text: e.text }))
  await notify($, '<task-id>bq1</task-id><status>failed</status>')
  expect(toasts).toEqual(['✖ a 止まった（61%）'])
  expect(written).toEqual([])
})

test('通知の時点で全体に届いていれば完了', async ($, on) => {
  seed(on, [seeded()])
  const { toasts } = engine(on, { stdout: '12600000000\t/d\n' })
  on('prompt.submit', (_, e) => ({ text: e.text }))
  await notify($, '<task-id>bq1</task-id><status>completed</status>')
  expect(toasts.length).toBe(1)
  expect(toasts[0]).toMatch(/^✔ a 完了（12\.6 GB、/)
  expect(written).toEqual([])
})

// Claude が TaskStop で止めた背景タスクは、終わりの通知が会話に届かない（2026-11-02 に実機で確かめた）
test('TaskStop で止めたら止まったと出す', async ($, on) => {
  seed(on, [seeded()])
  const { toasts } = engine(on, { stdout: '7800000000\t/d\n' })
  on('tool.call', () => ({ result: { message: 'stopped' } }) as never)
  await $.tool.call({ tool: 'TaskStop', task_id: 'bq1' } as never)
  expect(toasts).toEqual(['✖ a 止まった（61%）'])
  expect(written).toEqual([])
})

test('TaskStop が失敗したら外さない', async ($, on) => {
  seed(on, [seeded()])
  const { toasts, runs } = engine(on, { stdout: '7800000000\t/d\n' })
  on('tool.call', () => ({ deny: 'no such task' }))
  await $.tool.call({ tool: 'TaskStop', task_id: 'bq1' } as never)
  expect(toasts).toEqual([])
  expect(runs).toEqual([])
})

test('成功で終わったが全体に届かなければ、止まったではなく終わったと出す', async ($, on) => {
  seed(on, [seeded()])
  const { toasts } = engine(on, { stdout: '7800000000\t/d\n' })
  on('prompt.submit', (_, e) => ({ text: e.text }))
  await notify($, '<task-id>bq1</task-id><status>completed</status>')
  expect(toasts).toEqual(['✔ a 終わった（61%）'])
  expect(written).toEqual([])
})

test('一本の測定が失敗しても、ほかの登録は測り続ける', async ($, on) => {
  seed(on, [seeded({ name: 'a', paths: ['/a'] }), seeded({ name: 'b', paths: ['/b'] })])
  bare(on)
  const clock = mock.clock(on, { now: T0 })
  on('state.set', (_, e, next) => {
    written = e.value as Job[]
    didWrite = true
    return next(e)
  })
  on('process.run', (_, e) => {
    if (e.argv.includes('/a')) throw new Error('timed out')
    return {
      value: { exitCode: 0, stdout: '8000000000\t/b\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  on('ui.toast', () => ({ value: undefined }))
  written = []
  didWrite = false
  await start($)
  await clock.advance(4000)
  const b = written.find(j => j.name === 'b')
  expect(b?.samples.at(-1)?.amount).toBe(8e9)
  expect(written.find(j => j.name === 'a')?.samples.length).toBe(2)
})

test('watch で測定が失敗したら 0 として登録する', async ($, on) => {
  mock.clock(on, { now: T0 })
  on('state.set', (_, e, next) => {
    written = e.value as Job[]
    didWrite = true
    return next(e)
  })
  bare(on)
  on('process.run', () => {
    throw new Error('timed out')
  })
  written = []
  didWrite = false
  await start($)
  const ran = await watch($, { name: 'x', paths: ['/d'], unit: 'bytes', total: 1e9 })
  expect(String(ran.result)).toMatch(/^登録した: x（0\.0\/1\.0 GB）/)
  expect(written.length).toBe(1)
})

test('全体に届いたのと通知が重なっても、完了の通知は一度だけ', async ($, on) => {
  seed(on, [seeded({ total: 100, samples: [{ at: T0, amount: 10 }] })])
  bare(on)
  const clock = mock.clock(on, { now: T0 })
  on('state.set', (_, e, next) => {
    written = e.value as Job[]
    didWrite = true
    return next(e)
  })
  let release = () => {}
  const gate = new Promise<void>(r => {
    release = r
  })
  on('process.run', async () => {
    await gate
    return { value: { exitCode: 0, stdout: '100\t/d\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  const toasts: string[] = []
  on('ui.toast', (_, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('prompt.submit', (_, e) => ({ text: e.text }))
  written = []
  didWrite = false
  await start($)
  const ticking = clock.advance(4000)
  await clock.settle()
  const notified = notify($, '<task-id>bq1</task-id><status>completed</status>')
  await clock.settle()
  release()
  await ticking
  await notified
  expect(toasts.filter(t => t.startsWith('✔ a')).length).toBe(1)
})

test('ほかのタスクの通知では外さない', async ($, on) => {
  seed(on, [seeded()])
  const { toasts, runs } = engine(on, { stdout: '7800000000\t/d\n' })
  on('prompt.submit', (_, e) => ({ text: e.text }))
  await notify($, '<task-id>other</task-id><status>failed</status>')
  expect(toasts).toEqual([])
  expect(runs).toEqual([])
})

test('人の入力では何もしない', async ($, on) => {
  seed(on, [seeded()])
  const { toasts, runs } = engine(on, { stdout: '' })
  on('prompt.submit', (_, e) => ({ text: e.text }))
  await $.prompt.submit({
    text: '<task-notification><task-id>bq1</task-id><status>failed</status></task-notification>',
    wait: false,
    origin: { kind: 'composer' },
  } as never)
  expect(toasts).toEqual([])
  expect(runs).toEqual([])
})

test('一節を末尾に足す', async ($, on) => {
  engine(on, { stdout: '' })
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'x', scope: 'shared' }] }) as never)
  const { sections } = await $.prompt.compose({
    model: 'm',
    promptModel: 'm',
    surfaces: ['terminal'],
    tools: [],
    outputStyle: null,
    traits: [],
  } as never)
  const last = sections.at(-1)
  expect(last?.id).toBe('bg-progress:guide')
  expect(last?.scope).toBe('session')
  expect(last?.text).toContain('mcp__bg-progress__watch')
})

test('読み込み直しで測定を再開する', async ($, on) => {
  const stored: Job = {
    name: 'x',
    paths: ['/d'],
    unit: 'bytes',
    total: 1000,
    startedAt: T0,
    samples: [{ at: T0, amount: 10 }],
    lastGrowthAt: T0,
  }
  // 前の版が書いた登録を、Mod が書き込むまで返す（以後は kit が持つ）
  on('state.get', (_, e, next) =>
    didWrite ? next(e) : { value: { value: [stored], version: 0 } },
  )
  const { runs, clock } = engine(on, { stdout: '20\t/d\n' })
  await start($)
  expect(runs.length).toBe(0)
  await clock.advance(4000)
  expect(runs.length).toBe(1)
})
