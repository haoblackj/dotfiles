import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Job, Unit } from '../types'
import { measure } from './measure'
import { amountOf, formatAmount, formatDuration, formatSize } from './progress'

const jobs = atom({ plugin: 'bg-progress', key: 'jobs' } as const, [] as Job[])

const TICK_MS = 4000
const KEEP_MS = 60_000

const WATCH_DESCRIPTION =
  '背景で始めた長い処理（ダウンロード、一括の推論など）の進捗を、入力欄の上の帯に何％と JST の終了時刻で出す。背景の Bash を起動して結果が返った後に呼び、その結果の backgroundTaskId を taskId に渡す。paths にはこの処理だけが書き込むディレクトリかファイルを渡す（hf download なら --local-dir、curl なら出力先）。unit は、ファイルの大きさで測るなら bytes、行を足していく出力なら lines。total は処理が終わったときに paths が達する量（bytes ならファイルの合計の大きさ、lines なら行数）。同じ name で呼び直すと置き換わる。'

type WatchInput = { name: string; paths: string[]; unit: Unit; total: number; taskId?: string }

// 読み込み直しで消える。session.start が登録の残りを見て張り直す。
let timer: { cancel: () => void } | undefined
let isTicking = false

const stopTimerIfIdle = async ($: EngineInterface) => {
  if ((await read($, jobs)).length === 0) {
    timer?.cancel()
    timer = undefined
  }
}

const toastDone = async ($: EngineInterface, job: Job) => {
  const sec = ((await $.clock.now()) - job.startedAt) / 1000
  $.ui.toast(`✔ ${job.name} 完了（${formatSize(job.unit, job.total)}、${formatDuration(sec)}）`, {
    timeoutMs: 8000,
  })
}

const tick = async ($: EngineInterface) => {
  if (isTicking) return
  isTicking = true
  try {
    const current = await read($, jobs)
    const measured = new Map<string, number>()
    for (const job of current) {
      measured.set(job.name, await measure($, job.paths, job.unit))
    }
    const now = await $.clock.now()
    const finished: Job[] = []
    await update($, jobs, list =>
      list.flatMap(job => {
        const amount = measured.get(job.name)
        if (amount === undefined) return [job]
        const grew = amount > amountOf(job)
        const next: Job = {
          ...job,
          samples: [...job.samples, { at: now, amount }].filter(s => s.at >= now - KEEP_MS),
          lastGrowthAt: grew ? now : job.lastGrowthAt,
        }
        if (amount >= job.total) {
          finished.push(next)
          return []
        }
        return [next]
      }),
    )
    for (const job of finished) await toastDone($, job)
    await stopTimerIfIdle($)
  } finally {
    isTicking = false
  }
}

const ensureTimer = ($: EngineInterface) => {
  timer ??= $.clock.every(TICK_MS, () => void tick($))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.tool.register({
      name: 'watch',
      description: WATCH_DESCRIPTION,
      isDeferred: false,
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: '帯に出す短い名前' },
          paths: { type: 'array', items: { type: 'string' }, description: '測るディレクトリかファイル' },
          unit: { type: 'string', enum: ['bytes', 'lines'] },
          total: { type: 'number', description: '終わったときに paths が達する量' },
          taskId: { type: 'string', description: '背景の Bash の backgroundTaskId' },
        },
        required: ['name', 'paths', 'unit', 'total'],
      },
    })
    await $.tool.register({
      name: 'unwatch',
      description: 'mcp__bg-progress__watch で登録した処理を帯から外す。処理を途中で止めたときに使う。',
      isDeferred: false,
      inputSchema: {
        type: 'object',
        properties: { name: { type: 'string' } },
        required: ['name'],
      },
    })
    if ((await read($, jobs)).length > 0) ensureTimer($)
    return next(e)
  })

  on('tool.call', { tool: 'mcp__bg-progress__watch' }, async ($, e) => {
    const { name, paths, unit, total, taskId } = e as unknown as WatchInput
    if (!name || !Array.isArray(paths) || paths.length === 0) {
      return { deny: 'name と paths（1 つ以上）が要る' }
    }
    if (unit !== 'bytes' && unit !== 'lines') return { deny: 'unit は bytes か lines' }
    if (!(typeof total === 'number' && total > 0)) return { deny: 'total は 0 より大きい数' }

    const amount = await measure($, paths, unit)
    const now = await $.clock.now()
    const job: Job = {
      name,
      paths,
      unit,
      total,
      ...(taskId ? { taskId } : {}),
      startedAt: now,
      samples: [{ at: now, amount }],
      lastGrowthAt: now,
    }
    const isDone = amount >= total
    await update($, jobs, list => [...list.filter(j => j.name !== name), ...(isDone ? [] : [job])])
    if (isDone) {
      await toastDone($, job)
      await stopTimerIfIdle($)
    } else {
      ensureTimer($)
    }
    return { result: `登録した: ${name}（${formatAmount(unit, amount, total)}）` }
  })

  on('tool.call', { tool: 'mcp__bg-progress__unwatch' }, async ($, e) => {
    const { name } = e as unknown as { name: string }
    const had = (await read($, jobs)).some(j => j.name === name)
    if (!had) return { result: `登録が無い: ${name}` }
    await update($, jobs, list => list.filter(j => j.name !== name))
    await stopTimerIfIdle($)
    return { result: `外した: ${name}` }
  })
}
