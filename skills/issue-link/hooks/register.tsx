import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Entry, Found, RepoRef } from '../types'
import { fromBash, fromPrompt, keyOf, mergeFound, repoOfRemote } from './extract'

const entries = atom({ plugin: 'issue-link', key: 'entries' } as const, [] as Entry[])

const MAX_LINKS = 3
const TITLE_CHARS = 10
const GH_TIMEOUT_MS = 10_000

// 読み込み直しで消える。消えたら、タイトルの無いものを一度だけ聞き直す
const asked = new Set<string>()
let here: RepoRef | null | undefined

const hereOf = async ($: EngineInterface): Promise<RepoRef | null> => {
  if (here === undefined) {
    try {
      here = repoOfRemote((await $.session.repo())?.remote ?? null)
    } catch {
      here = null
    }
  }
  return here
}

// --resume で戻ったときのために、セッション ID を鍵にしてセッションの外へも写す
const storeKey = async ($: EngineInterface) => `entries:${await $.session.id()}`

const apply = async ($: EngineInterface, fn: (list: Entry[]) => Entry[]) => {
  let after: Entry[] = []
  await update($, entries, list => (after = fn(list)))
  await $.store.set(await storeKey($), after).catch(() => {})
}

type Lookup = { title: string; pr: boolean }

const lookup = async ($: EngineInterface, e: Entry): Promise<Lookup | null> => {
  try {
    const ran = await $.process.run(
      ['gh', 'api', `repos/${e.owner}/${e.repo}/issues/${e.number}`, '--jq', '{title: .title, pr: (.pull_request != null)}'],
      { timeoutMs: GH_TIMEOUT_MS },
    )
    if (ran.exitCode !== 0) return null
    const v = JSON.parse(ran.stdout) as Partial<Lookup>
    return typeof v.title === 'string' && typeof v.pr === 'boolean' ? { title: v.title, pr: v.pr } : null
  } catch {
    return null
  }
}

// PR なら外す。取れなければ、裸の番号で待っているものだけ外し、URL やコマンドから拾ったものは番号だけで残す
const resolveTitles = async ($: EngineInterface) => {
  const todo = (await read($, entries)).filter(
    e => (e.status === 'pending' || e.title === null) && !asked.has(keyOf(e)),
  )
  for (const e of todo) {
    const key = keyOf(e)
    asked.add(key)
    const got = await lookup($, e)
    await apply($, list =>
      list.flatMap(x => {
        if (keyOf(x) !== key) return [x]
        if (got?.pr) return []
        if (got) return [{ ...x, title: got.title, status: 'shown' as const }]
        return x.status === 'pending' ? [] : [x]
      }),
    )
  }
}

const track = async ($: EngineInterface, find: (home: RepoRef | null) => Found[]) => {
  try {
    const found = find(await hereOf($))
    if (found.length === 0) return
    await apply($, list => mergeFound(list, found))
    await resolveTitles($)
  } catch {
    // 拾えなくてもセッションは続ける
  }
}

const labelOf = (e: Entry, here: RepoRef | null) => {
  const same = here !== null && keyOf({ ...here, number: e.number }) === keyOf(e)
  const title = e.title === null ? '' : ` ${[...e.title].slice(0, TITLE_CHARS).join('')}`
  return `${same ? '' : e.repo}#${e.number}${title}`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    if ((await read($, entries)).length === 0) {
      const saved = await $.store.get(await storeKey($)).catch(() => undefined)
      if (Array.isArray(saved) && saved.length > 0) await update($, entries, () => saved as Entry[])
    }
    void resolveTitles($).catch(() => {})
    return started
  })

  // タイトルの問い合わせで送信やツールの結果を待たせないよう、拾う処理は待たずに走らせる
  on('prompt.submit', ($, e, next) => {
    if (!e.command && !e.isMeta) void track($, home => fromPrompt(e.text, home))
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny === undefined) {
      const stdout = (ran.result as { stdout?: unknown } | undefined)?.stdout
      void track($, home => fromBash(e.command, typeof stdout === 'string' ? stdout : '', home))
    }
    return ran
  })

  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const shown = (await read($, entries)).filter(x => x.status === 'shown').slice(0, MAX_LINKS)
    if (shown.length === 0) return next(e)
    const engine = await next(e)
    // JSX が大域の h を使うので、h という名の変数を置かない
    const home = await hereOf($)
    const { Box, Link, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="row">
        {engine}
        {shown.flatMap(x => [
          <Text dimColor> · </Text>,
          <Link href={`https://github.com/${x.owner}/${x.repo}/issues/${x.number}`}>{labelOf(x, home)}</Link>,
        ])}
      </Box>
    )
  })
}
