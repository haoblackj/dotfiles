import type { Entry, Found, RepoRef, Source } from '../types'

const ISSUE_URL = /https?:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/issues\/(\d+)/g
const ANY_URL = /https?:\/\/\S+/g
// 語の中（issue#12）、パスの中、HTML の実体参照（&#123;）、## 見出しは番号とみなさない
const BARE = /(?<![\w/&#])#(\d+)(?![\w-])/g
const GH_ISSUE = /\bgh\s+issue\s+([a-z-]+)\b([^|;&\n]*)/g
const GH_API_ISSUE = /\bgh\s+api\b[^|;&\n]*?\brepos\/([\w.-]+)\/([\w.-]+)\/issues\/(\d+)\b/g
const REPO_FLAG = /(?:^|\s)(?:-R|--repo)[\s=]+([\w.-]+)\/([\w.-]+)/
// 番号を取らない gh issue の動詞
const NO_NUMBER_VERBS = new Set(['create', 'list', 'status'])

type At = { at: number; found: Found }

export const repoOfRemote = (remote: string | null): RepoRef | null => {
  const m = remote?.match(/^(?:https?:\/\/|ssh:\/\/git@|git@)github\.com[:/]([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/)
  return m ? { owner: m[1], repo: m[2] } : null
}

export const keyOf = (r: RepoRef & { number: number }): string =>
  `${r.owner}/${r.repo}#${r.number}`.toLowerCase()

const urlsIn = (text: string, source: Source): At[] =>
  [...text.matchAll(ISSUE_URL)].map(m => ({
    at: m.index,
    found: { owner: m[1], repo: m[2], number: Number(m[3]), source },
  }))

// 文字列の中で後に出たものほど先に並べる（新しいものが左）
const latestFirst = (list: At[]): Found[] => list.sort((a, b) => b.at - a.at).map(a => a.found)

export const fromPrompt = (text: string, here: RepoRef | null): Found[] => {
  const hits = urlsIn(text, 'url')
  if (here) {
    // URL の中の #（コメントの錨など）を番号と読まないよう、URL を同じ長さの空白に置き換えてから探す
    const blanked = text.replace(ANY_URL, s => ' '.repeat(s.length))
    for (const m of blanked.matchAll(BARE)) {
      hits.push({ at: m.index, found: { ...here, number: Number(m[1]), source: 'bare' } })
    }
  }
  return latestFirst(hits)
}

export const fromBash = (command: string, stdout: string, here: RepoRef | null): Found[] => {
  const hits: At[] = []
  for (const m of command.matchAll(GH_ISSUE)) {
    const [, verb, args] = m
    if (verb === 'create') {
      hits.push(...urlsIn(stdout, 'command').map(h => ({ ...h, at: m.index })))
      continue
    }
    if (NO_NUMBER_VERBS.has(verb)) continue
    const inArgs = urlsIn(args, 'command')
    if (inArgs.length > 0) {
      hits.push(...inArgs.map(h => ({ ...h, at: m.index + h.at })))
      continue
    }
    const flag = args.match(REPO_FLAG)
    const repo = flag ? { owner: flag[1], repo: flag[2] } : here
    const number = args.split(/\s+/).find(t => /^\d+$/.test(t))
    if (repo && number) hits.push({ at: m.index, found: { ...repo, number: Number(number), source: 'command' } })
  }
  for (const m of command.matchAll(GH_API_ISSUE)) {
    hits.push({ at: m.index, found: { owner: m[1], repo: m[2], number: Number(m[3]), source: 'command' } })
  }
  return latestFirst(hits)
}

export const mergeFound = (entries: Entry[], found: Found[]): Entry[] => {
  let list = entries
  // found の先頭が最後に左へ来るよう、後ろから一つずつ先頭へ入れる
  for (const f of [...found].reverse()) {
    const key = keyOf(f)
    const old = list.find(e => keyOf(e) === key)
    let next: Entry
    if (!old) {
      const { source } = f
      next = { owner: f.owner, repo: f.repo, number: f.number, source, title: null, status: source === 'bare' ? 'pending' : 'shown' }
    } else if (old.source === 'bare' && f.source !== 'bare') {
      next = { ...old, source: f.source, status: 'shown' }
    } else {
      next = old
    }
    list = [next, ...list.filter(e => keyOf(e) !== key)]
  }
  return list
}
