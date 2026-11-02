import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Job, Unit } from '../types'
import { measure } from './measure'
import {
  amountOf,
  formatAmount,
  formatDuration,
  formatSize,
  parseTaskNotifications,
  rowsOf,
} from './progress'

const jobs = atom({ plugin: 'bg-progress', key: 'jobs' } as const, [] as Job[])

const TICK_MS = 4000
const KEEP_MS = 60_000

const WATCH_DESCRIPTION =
  '背景で始めた長い処理（ダウンロード、一括の推論など）の進捗を、入力欄の上の帯に何％と JST の終了時刻で出す。背景の Bash を起動して結果が返った後に呼び、その結果の backgroundTaskId を taskId に渡す。paths にはこの処理だけが書き込むディレクトリかファイルを絶対パスで渡す（hf download なら --local-dir、curl なら出力先）。unit は、ファイルの大きさで測るなら bytes、行を足していく出力なら lines。total は処理が終わったときに paths が達する量（bytes ならファイルの合計の大きさ、lines なら行数）。同じ name で呼び直すと置き換わる。'

const GUIDE_TEXT = `# 背景の処理の進捗
数分以上かかる処理（モデルのダウンロード、ローカル LLM の一括の推論など）を背景の Bash で始めたら、結果が返った直後に mcp__bg-progress__watch で登録する。進捗と JST の終了時刻が入力欄の上に出て、リーダーが終わりの見当をつけられる。全体の量は起動の前に調べておく（Hugging Face のファイルなら https://huggingface.co/api/models/<repo>/tree/main の size を足す。問いを一つずつ書き出す処理なら問いの数）。処理を途中で止めたら mcp__bg-progress__unwatch で外す。`

type WatchInput ={ name: string; paths: string[]; unit: Unit; total: number; taskId?: string }

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

// 全体に届く前に背景タスクが終わったら外す。届いていれば（照合などで長引いただけ）完了として扱う。
const settleTask = async ($: EngineInterface, taskId: string) => {
  const hit = (await read($, jobs)).filter(j => j.taskId === taskId)
  if (hit.length === 0) return
  const amounts = new Map<string, number>()
  for (const job of hit) amounts.set(job.name, await measure($, job.paths, job.unit))
  await update($, jobs, list => list.filter(j => j.taskId !== taskId))
  for (const job of hit) {
    const amount = amounts.get(job.name) ?? amountOf(job)
    if (amount >= job.total) {
      await toastDone($, job)
    } else {
      const percent = Math.min(100, Math.max(0, Math.floor((100 * amount) / job.total)))
      $.ui.toast(`✖ ${job.name} 止まった（${percent}%）`, { timeoutMs: 8000 })
    }
  }
  await stopTimerIfIdle($)
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
    // find は - や ( で始まる引数を条件式として読む（-delete なら消す）ので、絶対パスだけを通す
    if (!paths.every(p => typeof p === 'string' && p.startsWith('/'))) {
      return { deny: 'paths は絶対パスで渡す' }
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

  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind === 'task-notification') {
      for (const { taskId } of parseTaskNotifications(e.text)) await settleTask($, taskId)
    }
    return next(e)
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    return {
      ...composed,
      sections: [...composed.sections, { id: 'bg-progress:guide', text: GUIDE_TEXT, scope: 'session' }],
    }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, jobs)
    if (e.props.hasSurvey || list.length === 0) return next(e)
    const now = await $.clock.now()
    const { rows, more } = rowsOf(list, now)
    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        {rows.map(row => (
          <Text key={row.name}>
            <Text color="cyan">⬇ {row.name}</Text>
            {'  '}
            <Text bold>{String(row.percent).padStart(3)}%</Text>
            {'  '}[{row.bar}]{'  '}
            <Text dimColor>
              {row.amount}  {row.rate}
            </Text>
            {'  '}
            <Text bold>{row.tail}</Text>
          </Text>
        ))}
        {more > 0 ? <Text dimColor>ほか {more} 本</Text> : null}
      </Box>
    )
  })
}
