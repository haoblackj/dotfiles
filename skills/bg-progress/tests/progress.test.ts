import { expect, test } from 'claude-code/testing'

import type { Job, Sample } from '../types'
import {
  bar,
  formatAmount,
  formatDuration,
  formatJst,
  formatRate,
  formatSize,
  isStalled,
  parseTaskNotifications,
  rateOf,
  rowOf,
  rowsOf,
} from '../hooks/progress'

const job = (over: Partial<Job> = {}): Job => ({
  name: 'a',
  paths: ['/x'],
  unit: 'bytes',
  total: 100,
  startedAt: 0,
  samples: [],
  lastGrowthAt: 0,
  ...over,
})

test('JST の時刻', () => {
  expect(formatJst(Date.UTC(2026, 10, 2, 7, 24))).toBe('16:24')
})

test('日付をまたぐ JST', () => {
  expect(formatJst(Date.UTC(2026, 10, 2, 15, 5))).toBe('00:05')
})

test('残り時間の書式', () => {
  expect(formatDuration(30)).toBe('1分')
  expect(formatDuration(480)).toBe('8分')
  expect(formatDuration(4320)).toBe('1時間12分')
})

test('丸めで 60 分にならない', () => {
  expect(formatDuration(3590)).toBe('1時間0分')
  expect(formatDuration(7190)).toBe('2時間0分')
})

test('量と速さの書式', () => {
  expect(formatAmount('bytes', 7.8e9, 12.6e9)).toBe('7.8/12.6 GB')
  expect(formatAmount('bytes', 329e6, 345e6)).toBe('329/345 MB')
  expect(formatAmount('lines', 143, 260)).toBe('143/260 件')
  expect(formatRate('bytes', 9.8e6)).toBe('9.8 MB/s')
  expect(formatRate('lines', 0.8)).toBe('0.8 件/s')
})

test('トーストに出す全体の量の書式', () => {
  expect(formatSize('bytes', 12.6e9)).toBe('12.6 GB')
  expect(formatSize('bytes', 345e6)).toBe('345 MB')
  expect(formatSize('lines', 260)).toBe('260 件')
})

test('速さは直近 30 秒の増え方', () => {
  const s: Sample[] = [
    { at: 0, amount: 0 },
    { at: 40_000, amount: 100 },
    { at: 60_000, amount: 300 },
  ]
  // 40s→60s の 200 を 20 秒で割る（0s は窓の外）
  expect(rateOf(s, 60_000)).toBe(10)
})

test('標本が一つなら測定中', () => {
  const j = job({ samples: [{ at: 0, amount: 10 }] })
  expect(rowOf(j, 1_000).tail).toBe('測定中')
})

test('60 秒増えなければ停滞中', () => {
  const j = job({
    samples: [
      { at: 30_000, amount: 10 },
      { at: 60_000, amount: 10 },
    ],
    lastGrowthAt: 0,
  })
  expect(isStalled(j, 60_000)).toBe(true)
  expect(isStalled(j, 59_999)).toBe(false)
  expect(rowOf(j, 60_000).tail).toBe('停滞中')
})

test('残りと終了時刻', () => {
  const now = Date.UTC(2026, 10, 2, 7, 16)
  const j = job({
    name: 'gemma',
    total: 12.6e9,
    samples: [
      { at: now - 20_000, amount: 7.6e9 },
      { at: now, amount: 7.8e9 },
    ],
    lastGrowthAt: now,
  })
  const row = rowOf(j, now)
  // 10 MB/s で残り 4.8 GB は 480 秒
  expect(row.tail).toBe(`残り 8分 → ${formatJst(now + 480_000)} JST`)
  expect(row.percent).toBe(61)
  expect(row.bar).toBe('██████    ')
  expect(row.amount).toBe('7.8/12.6 GB')
  expect(row.rate).toBe('10.0 MB/s')
})

test('割合は 0〜100 に収まる', () => {
  expect(rowOf(job({ samples: [{ at: 0, amount: 150 }] }), 0).percent).toBe(100)
  expect(bar(1.5)).toBe('██████████')
  expect(bar(0)).toBe('          ')
})

test('6 本なら 4 本とほか 2 本', () => {
  const six = ['a', 'b', 'c', 'd', 'e', 'f'].map(name => job({ name }))
  expect(rowsOf(six, 0).rows.length).toBe(4)
  expect(rowsOf(six, 0).more).toBe(2)
  expect(rowsOf(six.slice(0, 5), 0).rows.length).toBe(5)
  expect(rowsOf(six.slice(0, 5), 0).more).toBe(0)
})

test('通知からタスク ID と状態を抜く', () => {
  const text =
    '<task-notification>\n<task-id>bq1</task-id>\n<status>failed</status>\n</task-notification>'
  expect(parseTaskNotifications(text)).toEqual([{ taskId: 'bq1', status: 'failed' }])
})

test('通知が二つあれば二つ抜く', () => {
  const text =
    '<task-notification><task-id>a</task-id><status>completed</status></task-notification>\n' +
    '<task-notification><task-id>b</task-id><status>killed</status></task-notification>'
  expect(parseTaskNotifications(text)).toEqual([
    { taskId: 'a', status: 'completed' },
    { taskId: 'b', status: 'killed' },
  ])
})
