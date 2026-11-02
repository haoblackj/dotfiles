import type { EngineInterface, Register } from 'claude-code'

// 使い捨ての試作（dotfiles#79）。合言葉を含む応答にだけ作用し、ほかは素通りする。
// クラウドのコンテナで確かめるための写し。記録はコンテナの /tmp に置く。
const LOG = '/tmp/stop-guard-probe.jsonl'
const BLOCK_WORD = 'PROBE-BLOCK-' + '7Q'
const REWRITE_WORD = 'PROBE-REWRITE-' + '7Q'

const lines: string[] = []
const record = async ($: EngineInterface, entry: object) => {
  lines.push(JSON.stringify({ at: new Date().toISOString(), ...entry }))
  await $.fs.write(LOG, lines.join('\n') + '\n')
}
const tail = (s: string | undefined) => (s === undefined ? null : s.slice(-120))

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await record($, { ev: 'session.start', root: $.plugin.root })
    return started
  })

  on('classic.Stop', async ($, e, next) => {
    const msgs = await $.session.messages()
    const assistants = msgs.filter(m => m.role === 'assistant').slice(-4).map(m => tail(m.text))
    const hit = (e.last_assistant_message ?? '').includes(BLOCK_WORD)
    await record($, {
      ev: 'classic.Stop',
      keys: Object.keys(e),
      stop_hook_active: e.stop_hook_active,
      last_assistant_message: tail(e.last_assistant_message),
      messageCount: msgs.length,
      lastAssistantTexts: assistants,
      willBlock: hit && !e.stop_hook_active,
    })
    if (hit && !e.stop_hook_active) {
      return { block: 'stop-guard-probe: block を受けた。PROBE-CONTINUED とだけ書いて終えて。' }
    }
    return next(e)
  })

  on('session.append', async ($, e, next) => {
    if (e.door !== 'response') return next(e)
    const has = e.message.content.some(b => b.type === 'text' && b.text.includes(REWRITE_WORD))
    if (!has) return next(e)
    const content = e.message.content.map(b =>
      b.type === 'text' ? { ...b, text: b.text.split(REWRITE_WORD).join('PROBE-REWRITTEN') } : b,
    )
    const stored = await next({ ...e, message: { ...e.message, content } })
    await record($, { ev: 'session.append', uuid: stored.uuid, agentId: e.agentId ?? null })
    return stored
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      await record($, { ev: 'turn.complete', reason: e.reason, answer: tail(e.answer) })
    }
    return next(e)
  })
}
