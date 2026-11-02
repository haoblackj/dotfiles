import { expect, test } from 'claude-code/testing'
import type { On, SessionMessage } from 'claude-code'

const EN = 'I checked the configuration and the hooks are wired correctly, so the next step is to run the tests.'
const JA = '設定を確かめたところ、フックは正しくつながっていたので、次はテストを走らせるね。'

const user = (text: string): SessionMessage => ({ role: 'user', text, toolUses: [] })
const said = (text: string): SessionMessage => ({ role: 'assistant', text, toolUses: [] })
const called = (text = ''): SessionMessage => ({
  role: 'assistant',
  text,
  toolUses: [{ tool_use_id: 't1', tool: 'Bash', input: { command: 'ls' } }],
})
const result = (): SessionMessage => ({
  role: 'user',
  text: '',
  toolUses: [],
  toolResults: [{ tool_use_id: 't1', text: 'ok', isError: false, result: {} }],
} as unknown as SessionMessage)

// テストの hook はエンジンの代わりに立つ。セッションの行は rows.value を返す。
const engine = (on: On, rows: { value: SessionMessage[] }) => {
  const toasts: string[] = []
  on('session.messages', () => ({ value: rows.value }))
  on('classic.Stop', () => ({}))
  on('tool.call', () => ({ result: {} }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('ui.toast', (_, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  return { toasts }
}

const STOP = { stop_hook_active: false, last_assistant_message: '', background_tasks: [], session_crons: [] }

test('最終回答が英語なら Stop を block し、その箇所を理由に引く', async ($, on) => {
  engine(on, { value: [user('やって'), called(JA), result(), said(EN)] })
  const r = await $.classic.Stop(STOP)
  expect(r.block).toContain(EN.slice(0, 80))
})

test('ツールより前の本文は最終回答に含めない', async ($, on) => {
  engine(on, { value: [user('やって'), called(`${EN}\n${EN}`), result(), said(JA)] })
  const r = await $.classic.Stop(STOP)
  expect(r.block).toBeUndefined()
})

test('再入（stop_hook_active）では block しない', async ($, on) => {
  engine(on, { value: [user('やって'), said(EN)] })
  const r = await $.classic.Stop({ ...STOP, stop_hook_active: true })
  expect(r.block).toBeUndefined()
})

test('分かれた応答の前半の英語も見る', async ($, on) => {
  engine(on, { value: [user('やって'), said(EN), said(JA)] })
  const r = await $.classic.Stop(STOP)
  expect(r.block).toContain(EN.slice(0, 80))
})

test('セッションの行が空なら last_assistant_message を見る', async ($, on) => {
  engine(on, { value: [] })
  const r = await $.classic.Stop({ ...STOP, last_assistant_message: EN })
  expect(r.block).toContain(EN.slice(0, 80))
})

test('ツールの前の複数行の報告が英語なら、ツールを差し戻す', async ($, on) => {
  engine(on, { value: [user('やって'), called(`${EN}\n${EN}`)] })
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(String((r as { deny?: string }).deny)).toContain('ツールを呼ぶ前の報告')
})

test('ツールの前の 1 行の英語の前置きも差し戻す', async ($, on) => {
  engine(on, { value: [user('やって'), called('Let me check the configuration file first.')] })
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(String((r as { deny?: string }).deny)).toContain('Let me check the configuration file first.')
})

test('ツールの前の 1 行の日本語の前置きは差し戻さない', async ($, on) => {
  engine(on, { value: [user('やって'), called(JA)] })
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect((r as { deny?: string }).deny).toBeUndefined()
})

test('書き直さずに呼び直したツールは、前の応答の本文で止めない', async ($, on) => {
  engine(on, { value: [user('やって'), called(`${EN}\n${EN}`), result(), called('')] })
  const r = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect((r as { deny?: string }).deny).toBeUndefined()
})

test('差し戻しは 1 ターンに 2 回までで、次のターンで数え直す', async ($, on) => {
  engine(on, { value: [user('やって'), called(`${EN}\n${EN}`)] })
  const deny = async () => (await $.tool.call({ tool: 'Bash', command: 'ls' }) as { deny?: string }).deny
  await $.turn.start({ text: 'やって', turnId: 'a' })
  expect(await deny()).toBeDefined()
  expect(await deny()).toBeDefined()
  expect(await deny()).toBeUndefined()
  await $.turn.start({ text: 'もう一度', turnId: 'b' })
  expect(await deny()).toBeDefined()
})

test('次の一手の箱が英語なら差し戻す', async ($, on) => {
  engine(on, { value: [user('やって'), called('')] })
  const r = await $.tool.call({ tool: 'mcp__ccd__wrap_up', recap: EN, ask: 'What should I do next?' } as never)
  expect(String((r as { deny?: string }).deny)).toContain('次の一手の箱')
})

test('判定が落ちたら止めずに通し、知らせる', async ($, on) => {
  const { toasts } = engine(on, { value: null as unknown as SessionMessage[] })
  const r = await $.classic.Stop(STOP)
  expect(r.block).toBeUndefined()
  expect(toasts.join('\n')).toContain('japanese-guard')
})
