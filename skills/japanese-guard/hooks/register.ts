import type { Register, SessionMessage } from 'claude-code'

import { foreignPassages, head, isForeign, isMidReportForeign } from './detect'

// 一つのターンでツール呼び出しを差し戻す上限。書き直しがまた英語になっても、無限には続けない。
const MAX_TOOL_DENIALS_PER_TURN = 2

const STOP_REASON = (quoted: string) =>
  'このターンの最終回答に、英語か中国語で書いた箇所があります。\n' +
  quoted +
  '\nユーザーは日本語での応答を求めています。上に挙げた箇所だけを、日本語に書き直して出してください。' +
  '日本語で書けていた部分は、すでにユーザーに届いているので再掲しないこと。' +
  '言い訳や原因の説明は書かず、以降の応答もすべて日本語で書くこと。'

const TOOL_REASON = (quoted: string) =>
  'ツールを呼ぶ前の報告に、英語か中国語で書いた箇所があります。\n' +
  quoted +
  '\nユーザーは日本語での応答を求めています。この報告を日本語で書き直してから、同じツールを呼び直してください。' +
  '言い訳や原因の説明は書かないこと。'

const WRAP_UP_REASON =
  '次の一手の箱（recap、ask、ボタンの文言）が英語か中国語です。ユーザーは日本語での応答を求めています。' +
  'すべて日本語で書き直して、もう一度呼んでください。'

const quote = (hits: string[]) => hits.slice(0, 5).map(h => `- ${h}`).join('\n')

/** 最後のツール呼び出しより後の本文。応答のブロックは行に分かれて並ぶので、末尾から集める。 */
export const finalAnswer = (msgs: readonly SessionMessage[]) => {
  const texts: string[] = []
  for (const m of [...msgs].reverse()) {
    if (m.role !== 'assistant' || m.toolUses.length > 0) break
    if (m.text !== '') texts.unshift(m.text)
  }
  return texts.join('\n\n')
}

/** いま呼ばれたツールを含む応答の本文（最後の user の行より後の assistant の行）。 */
export const currentResponse = (msgs: readonly SessionMessage[]) => {
  const texts: string[] = []
  for (const m of [...msgs].reverse()) {
    if (m.role === 'user') break
    if (m.text !== '') texts.unshift(m.text)
  }
  return texts.join('\n\n')
}

/** デスクトップアプリの「次の一手」の箱（MCP の wrap_up ツール）に出る文言。 */
export const wrapUpText = (input: Record<string, unknown>) => {
  const str = (v: unknown) => (typeof v === 'string' ? v : '')
  let actions = input.actions
  if (typeof actions === 'string') {
    try {
      actions = JSON.parse(actions)
    } catch {
      actions = []
    }
  }
  const labels = Array.isArray(actions)
    ? actions.flatMap(a => (a !== null && typeof a === 'object' ? [str((a as Record<string, unknown>).label), str((a as Record<string, unknown>).message)] : []))
    : []
  return [str(input.recap), str(input.ask), ...labels].filter(s => s !== '').join('\n')
}

export const register: Register = on => {
  let denials = 0

  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) denials = 0
    return next(e)
  })

  // 判定が例外で落ちたときは、止めずに通して壊れたことだけを知らせる（.catch）。
  // 止める側に倒すと、判定が直るまで利用者の作業が進まなくなる。

  on('classic.Stop', async ($, e, next) => {
    if (e.stop_hook_active) return next(e)
    const text = finalAnswer(await $.session.messages()) || (e.last_assistant_message ?? '')
    const hits = foreignPassages(text, isForeign)
    if (hits.length === 0) return next(e)
    return { block: STOP_REASON(quote(hits)) }
  }).catch(($, e, next) => {
    $.ui.toast('japanese-guard: 最終回答の判定に失敗したので通した（claude --debug で理由が出る）')
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    if (e.agentId !== undefined || denials >= MAX_TOOL_DENIALS_PER_TURN) return next(e)
    if (String(e.tool).endsWith('wrap_up') && isForeign(wrapUpText(e as unknown as Record<string, unknown>))) {
      denials++
      return { deny: WRAP_UP_REASON }
    }
    const text = currentResponse(await $.session.messages())
    if (!isMidReportForeign(text)) return next(e)
    const passages = foreignPassages(text, isForeign, '（ツールの前の報告）')
    const hits = passages.length > 0 ? passages : [head(text, '（ツールの前の報告）')]
    denials++
    return { deny: TOOL_REASON(quote(hits)) }
  }).catch(($, e, next) => {
    if (!next.called) $.ui.toast('japanese-guard: ツールの前の報告の判定に失敗したので通した（claude --debug で理由が出る）')
    return next(e)
  })
}
