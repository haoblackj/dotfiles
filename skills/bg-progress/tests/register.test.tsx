import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import type { Job } from '../types'
import { parseDu, parseWc } from '../hooks/measure'

const T0 = Date.UTC(2026, 10, 2, 7, 0)

// テストの $ は Mod の $.state を読めないので、書き込みを state.set の hook で写し取る。
let written: Job[] = []

// テストの hook はエンジンの代わりに立つ。process.run は du / wc の答えを返す。
const engine = (on: On, measured: { stdout: string; exitCode?: number }) => {
  const toasts: string[] = []
  const runs: string[][] = []
  written = []
  const clock = mock.clock(on, { now: T0 })
  on('state.set', (_, e, next) => {
    written = e.value as Job[]
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
    written.length > 0 ? next(e) : { value: { value: [stored], version: 0 } },
  )
  const { runs, clock } = engine(on, { stdout: '20\t/d\n' })
  await start($)
  expect(runs.length).toBe(0)
  await clock.advance(4000)
  expect(runs.length).toBe(1)
})
