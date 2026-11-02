import type { Job, Sample, Unit } from '../types'

const GB = 1e9
const MB = 1e6

export const amountOf = (job: Job): number => job.samples.at(-1)?.amount ?? 0

export const rateOf = (samples: Sample[], now: number, windowMs = 30_000): number => {
  const recent = samples.filter(s => s.at >= now - windowMs)
  const first = recent[0]
  const last = recent.at(-1)
  if (!first || !last || recent.length < 2 || last.at === first.at) return 0
  return (last.amount - first.amount) / ((last.at - first.at) / 1000)
}

export const isStalled = (job: Job, now: number, stallMs = 60_000): boolean =>
  now - job.lastGrowthAt >= stallMs

// Intl のタイムゾーンに頼らず、マシンの設定と関係なく UTC+9 で出す
export const formatJst = (ms: number): string => {
  const d = new Date(ms + 9 * 3600 * 1000)
  const hh = String(d.getUTCHours()).padStart(2, '0')
  const mm = String(d.getUTCMinutes()).padStart(2, '0')
  return `${hh}:${mm}`
}

// 先に分へ丸めてから時間と分に割る（3590 秒を「60分」、7190 秒を「1時間60分」にしない）
export const formatDuration = (sec: number): string => {
  const mins = Math.round(sec / 60)
  return mins >= 60 ? `${Math.floor(mins / 60)}時間${mins % 60}分` : `${Math.max(1, mins)}分`
}

export const formatAmount = (unit: Unit, done: number, total: number): string => {
  if (unit === 'lines') return `${done}/${total} 件`
  if (total >= GB) return `${(done / GB).toFixed(1)}/${(total / GB).toFixed(1)} GB`
  return `${Math.round(done / MB)}/${Math.round(total / MB)} MB`
}

export const formatSize = (unit: Unit, n: number): string => {
  if (unit === 'lines') return `${n} 件`
  if (n >= GB) return `${(n / GB).toFixed(1)} GB`
  return `${Math.round(n / MB)} MB`
}

export const formatRate =(unit: Unit, perSec: number): string =>
  unit === 'lines' ? `${perSec.toFixed(1)} 件/s` : `${(perSec / MB).toFixed(1)} MB/s`

export const bar = (ratio: number, width = 10): string => {
  const filled = Math.min(width, Math.max(0, Math.floor(ratio * width)))
  return '█'.repeat(filled) + ' '.repeat(width - filled)
}

export type Row = {
  name: string
  percent: number
  bar: string
  amount: string
  rate: string
  tail: string
}

export const rowOf = (job: Job, now: number): Row => {
  const amount = amountOf(job)
  const ratio = amount / job.total
  const rate = rateOf(job.samples, now)
  const tail = isStalled(job, now)
    ? '停滞中'
    : rate <= 0
      ? '測定中'
      : (() => {
          const left = Math.max(0, job.total - amount) / rate
          return `残り ${formatDuration(left)} → ${formatJst(now + left * 1000)} JST`
        })()
  return {
    name: job.name,
    percent: Math.min(100, Math.max(0, Math.floor(ratio * 100))),
    bar: bar(ratio),
    amount: formatAmount(job.unit, amount, job.total),
    rate: formatRate(job.unit, rate),
    tail,
  }
}

export const rowsOf = (jobs: Job[], now: number, max = 5): { rows: Row[]; more: number } => {
  const shown = jobs.length > max ? jobs.slice(0, max - 1) : jobs
  return { rows: shown.map(job => rowOf(job, now)), more: jobs.length - shown.length }
}

export const parseTaskNotifications = (text: string): { taskId: string; status: string }[] =>
  [...text.matchAll(/<task-notification>([\s\S]*?)<\/task-notification>/g)].flatMap(m => {
    const body = m[1] ?? ''
    const taskId = body.match(/<task-id>([^<]*)<\/task-id>/)?.[1]?.trim()
    const status = body.match(/<status>([^<]*)<\/status>/)?.[1]?.trim()
    return taskId && status ? [{ taskId, status }] : []
  })
