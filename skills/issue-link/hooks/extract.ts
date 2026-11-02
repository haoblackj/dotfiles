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
// 値を一つ取る gh issue のフラグ。値の中の番号や URL を Issue と読まないよう、値ごと飛ばす
const VALUE_FLAGS = new Set([
  '-b', '--body', '-F', '--body-file', '-t', '--title', '-R', '--repo',
  '-l', '--label', '--add-label', '--remove-label',
  '-a', '--assignee', '--add-assignee', '--remove-assignee',
  '-m', '--milestone', '--remove-milestone', '-p', '--project', '--add-project', '--remove-project',
  '-r', '--reason', '-q', '--jq', '--template', '--json',
])
const TOKEN = /"[^"]*"|'[^']*'|\S+/g
const OSC8 = /\x1b\]8;[^\x07\x1b]*;[^\x07\x1b]*(?:\x07|\x1b\\)/g

type At = { at: number; found: Found }

// 正規表現の必ず埋まる組を読む（noUncheckedIndexedAccess は組を undefined もありうると見る）
const g = (m: RegExpMatchArray, i: number): string => m[i] ?? ''

export const repoOfRemote = (remote: string | null): RepoRef | null => {
  const m = remote?.match(/^(?:https?:\/\/|ssh:\/\/git@|git@)github\.com[:/]([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/)
  return m ? { owner: g(m, 1), repo: g(m, 2) } : null
}

export const keyOf = (r: RepoRef & { number: number }): string =>
  `${r.owner}/${r.repo}#${r.number}`.toLowerCase()

const urlsIn = (text: string, source: Source): At[] =>
  [...text.matchAll(ISSUE_URL)].map(m => ({
    at: m.index,
    found: { owner: g(m, 1), repo: g(m, 2), number: Number(g(m, 3)), source },
  }))

// 文字列の中で後に出たものほど先に並べる（新しいものが左）
const latestFirst = (list: At[]): Found[] => list.sort((a, b) => b.at - a.at).map(a => a.found)

export const fromPrompt = (text: string, here: RepoRef | null): Found[] => {
  const hits = urlsIn(text, 'url')
  if (here) {
    // URL の中の #（コメントの錨など）を番号と読まないよう、URL を同じ長さの空白に置き換えてから探す
    const blanked = text.replace(ANY_URL, s => ' '.repeat(s.length))
    for (const m of blanked.matchAll(BARE)) {
      hits.push({ at: m.index, found: { ...here, number: Number(g(m, 1)), source: 'bare' } })
    }
  }
  return latestFirst(hits)
}

// gh issue の動詞の後の、フラグとその値を飛ばした最初の引数（名指しされた Issue）
const firstPositional = (args: string): string | undefined => {
  const tokens = args.match(TOKEN) ?? []
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i] ?? ''
    if (t.startsWith('-')) {
      if (!t.includes('=') && VALUE_FLAGS.has(t)) i++
      continue
    }
    return t
  }
  return undefined
}

// FORCE_HYPERLINK=1 を受けた CLI の出力のリンクの囲みを外し、見える文字だけ残す
export const stripHyperlinks = (text: string): string => text.replace(OSC8, '')

export const fromBash = (command: string, stdout: string, here: RepoRef | null): Found[] => {
  const hits: At[] = []
  for (const m of command.matchAll(GH_ISSUE)) {
    const verb = g(m, 1)
    const args = g(m, 2)
    if (verb === 'create') {
      hits.push(...urlsIn(stdout, 'command').map(h => ({ ...h, at: m.index })))
      continue
    }
    if (NO_NUMBER_VERBS.has(verb)) continue
    const target = firstPositional(args)
    if (target === undefined) continue
    const asUrl = urlsIn(target, 'command')[0]
    if (asUrl) {
      hits.push({ ...asUrl, at: m.index })
      continue
    }
    const flag = args.match(REPO_FLAG)
    const repo = flag ? { owner: g(flag, 1), repo: g(flag, 2) } : here
    if (repo && /^\d+$/.test(target)) hits.push({ at: m.index, found: { ...repo, number: Number(target), source: 'command' } })
  }
  for (const m of command.matchAll(GH_API_ISSUE)) {
    hits.push({ at: m.index, found: { owner: g(m, 1), repo: g(m, 2), number: Number(g(m, 3)), source: 'command' } })
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
