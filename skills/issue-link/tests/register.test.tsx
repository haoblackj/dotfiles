import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import type { Entry } from '../types'

const SESSION = 's1'
const URL73 = 'https://github.com/haoblackj/dotfiles/issues/73'

type Answer = { exitCode: number; stdout: string }

// テストの hook はエンジンの代わりに立つ。process.run は gh api の答えを返し、argv を記録する。
const engine = (on: On, answer: (argv: readonly string[]) => Answer, stored: Record<string, unknown> = {}) => {
  const runs: string[][] = []
  mock.store(on, stored)
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('session.id', () => ({ value: SESSION }))
  on('session.repo', () => ({
    value: { root: '/r', remote: 'git@github.com:haoblackj/dotfiles.git', internal: false, name: null },
  }))
  on('process.run', (_, e) => {
    runs.push([...e.argv])
    const a = answer(e.argv)
    return { value: { ...a, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>MODE</Text>
  })
  return { runs }
}

const issue = (title: string, pr = false) => (): Answer => ({ exitCode: 0, stdout: JSON.stringify({ title, pr }) })
const fail = (): Answer => ({ exitCode: 1, stdout: '' })

const start = ($: Engine) => $.session.start({ cwd: '/r', surface: 'terminal', isInteractive: true })

const submit = ($: Engine, text: string) => $.prompt.submit({ text, wait: false } as never)

// タイトルの問い合わせは送信を待たせないよう裏で走るので、片付くまで待つ
const settle = async () => {
  for (let i = 0; i < 50; i++) await Promise.resolve()
}

const mode = {
  plugin: 'issue-link',
  component: 'SessionMode',
  surface: 'terminal',
  props: { modes: [] },
} as const

const links = async ($: Engine) => {
  const ui = await $.ui.mount(mode as never)
  const found = await ui.findAll({ type: 'Link' })
  const engineText = (await ui.find({ type: 'Text', text: 'MODE' }))?.text
  await ui.unmount()
  // Link の text には href も入るので、画面に出る文字は子の文字列で見る
  const shown = (l: { children: unknown[] }) => l.children.filter(c => typeof c === 'string').join('')
  return { found: found.map(l => ({ href: l.props.href, text: shown(l) })), engineText }
}

test('Issue の URL のプロンプトでリンクが出て、エンジンの表示も残る', async ($, on) => {
  engine(on, issue('対話セッションの引き継ぎと掃除'))
  await start($)
  await submit($, `${URL73} を続けて`)
  await settle()
  const { found, engineText } = await links($)
  expect(found).toEqual([{ href: URL73, text: '#73 対話セッションの引き' }])
  expect(engineText).toBe('MODE')
})

test('裸の番号は PR なら出ない', async ($, on) => {
  engine(on, issue('PR のタイトル', true))
  await start($)
  await submit($, '#5 を見て')
  await settle()
  expect((await links($)).found).toEqual([])
})

test('裸の番号は gh が失敗したら出ない', async ($, on) => {
  engine(on, fail)
  await start($)
  await submit($, '#5 を見て')
  await settle()
  expect((await links($)).found).toEqual([])
})

test('裸の番号は Issue と分かれば出る', async ($, on) => {
  engine(on, issue('Issue のタイトル'))
  await start($)
  await submit($, '#5 を見て')
  await settle()
  expect((await links($)).found).toEqual([
    { href: 'https://github.com/haoblackj/dotfiles/issues/5', text: '#5 Issue のタイト' },
  ])
})

test('URL は gh が失敗しても番号だけで出る', async ($, on) => {
  engine(on, fail)
  await start($)
  await submit($, URL73)
  await settle()
  expect((await links($)).found).toEqual([{ href: URL73, text: '#73' }])
})

test('別のリポジトリはリポジトリ名を付ける', async ($, on) => {
  engine(on, issue('移築'))
  await start($)
  await submit($, 'https://github.com/haoblackj/penguinEx/issues/12')
  await settle()
  expect((await links($)).found[0]?.text).toBe('penguinEx#12 移築')
})

test('gh issue create の出力で足される', async ($, on) => {
  engine(on, issue('新しい Issue'))
  on('tool.call', () => ({
    result: { stdout: 'https://github.com/haoblackj/dotfiles/issues/80\n', stderr: '', interrupted: false },
  }))
  await start($)
  await $.tool.call({ tool: 'Bash', command: 'gh issue create --title x --body y' } as never)
  await settle()
  expect((await links($)).found.map(l => l.text)).toEqual(['#80 新しい Issue'])
})

test('四つ目は省かれ、新しいものが左', async ($, on) => {
  engine(on, issue('t'))
  await start($)
  for (const n of [1, 2, 3, 4]) await submit($, `https://github.com/haoblackj/dotfiles/issues/${n}`)
  await settle()
  expect((await links($)).found.map(l => l.text)).toEqual(['#4 t', '#3 t', '#2 t'])
})

test('前に残した一覧から戻り、タイトルのあるものは問い合わせない', async ($, on) => {
  const saved: Entry[] = [
    { owner: 'haoblackj', repo: 'dotfiles', number: 73, source: 'url', title: '前のタイトル', status: 'shown' },
  ]
  const { runs } = engine(on, issue('x'), { [`entries:${SESSION}`]: saved })
  await start($)
  await settle()
  expect((await links($)).found).toEqual([{ href: URL73, text: '#73 前のタイトル' }])
  expect(runs).toEqual([])
})

test('同じ Issue は一度だけ問い合わせる', async ($, on) => {
  const { runs } = engine(on, issue('t'))
  await start($)
  await submit($, URL73)
  await settle()
  await submit($, `${URL73} もう一度`)
  await settle()
  expect(runs.length).toBe(1)
})

test('何も無ければエンジンの描画だけ', async ($, on) => {
  engine(on, fail)
  await start($)
  const { found, engineText } = await links($)
  expect(found).toEqual([])
  expect(engineText).toBe('MODE')
})
