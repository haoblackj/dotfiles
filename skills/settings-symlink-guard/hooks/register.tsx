import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { Broken } from '../types'

// ~/.claude/settings.json は、ソースの linked/claude/settings.json への symlink である前提
// （Claude Code と Orca が書き戻した中身がそのままソースへ届く）。2026-11-21 に Orca の
// Windows 側のアプリがこれを通常のファイルで置き換えた（dotfiles の docs/work/settings-symlink.md）。
// 外れている間は入力欄の上に出し続け、Claude にも伝える。何も書き換えない。

const broken = atom({ plugin: 'settings-symlink-guard', key: 'broken' } as const, null)

// Orca が書き換えるのはアプリの起動や接続のときで、セッションの途中でも起きうる
const CHECK_MS = 60_000

const WORK_RECORD = 'docs/work/settings-symlink.md'

// 読み込み直しで消える。session.start が張り直す
let timer: Timer | undefined

const check = async ($: EngineInterface): Promise<Broken> => {
  if ((await $.env.get('CLAUDE_CODE_REMOTE')) === 'true') return null
  const home = (await $.env.get('HOME')) ?? ''
  const sourceDir = (await $.env.get('CHEZMOI_SOURCE_DIR')) ?? `${home}/.local/share/chezmoi`
  const target = `${home}/.claude/settings.json`
  const source = `${sourceDir}/linked/claude/settings.json`
  const t = await $.fs.stat(target, { resolve: true }).catch(() => undefined)
  if (t === undefined) return `${target} のファイルが無い`
  if (!t.isLink) return `${target} が通常のファイルになっている`
  if (t.realPath === undefined) return `${target} がリンク先が無い symlink になっている`
  const s = await $.fs.stat(source, { resolve: true }).catch(() => undefined)
  if (s?.realPath === undefined) return `${target} のリンク先と比べるソースが無い（${source}）`
  if (t.realPath !== s.realPath) return `${target} が別の場所への symlink になっている（${t.realPath}）`
  return null
}

const refresh = async ($: EngineInterface) => {
  const next = await check($)
  const prev = await read($, broken)
  if (next === prev) return
  await update($, broken, () => next)
  if (next !== null && prev === null) $.ui.toast(`⚠ ${next}`, { timeoutMs: 10_000 })
}

const contextFor = (state: string) =>
  `${state}。ソースの linked/claude/settings.json への symlink でないので、Claude Code や Orca が書き戻した中身がソースへ届かない。` +
  `リーダーに伝え、dotfiles の作業記録 ${WORK_RECORD} を読んで、ソースとの差（diff）を確かめてから直し方をリーダーに仰ぐこと。` +
  '~/.claude/settings.json も、ソースも、この知らせだけを理由に書き換えない。'

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await refresh($)
    timer?.cancel()
    // 一回の確かめの失敗で止めず、次の回でまた確かめる
    timer = $.clock.every(CHECK_MS, () => void refresh($).catch(() => undefined))
    return result
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    const state = await read($, broken)
    if (state === null) return composed
    return {
      ...composed,
      sections: [...composed.sections, { id: 'settings-symlink-guard:broken', text: contextFor(state), scope: 'session' }],
    }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const state = await read($, broken)
    if (state === null) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box>
        <Text color="red" bold>
          ⚠ {state}。ソースへ書き戻しが届かない（{WORK_RECORD}）
        </Text>
      </Box>
    )
  })
}
