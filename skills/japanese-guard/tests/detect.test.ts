import { expect, test } from 'claude-code/testing'

import { foreignPassages, isChinese, isEnglish, isForeign, isMidReportForeign } from '../hooks/detect'

const EN = 'I checked the configuration and the hooks are wired correctly, so the next step is to run the tests.'
const JA = '設定を確かめたところ、フックは正しくつながっていたので、次はテストを走らせるね。'
const ZH = '我们现在开始检查这个问题，然后运行所有的测试。'

test('英語の段落は英語、日本語の段落は英語でない', () => {
  expect(isEnglish(EN)).toBe(true)
  expect(isEnglish(JA)).toBe(false)
})

test('コード、インラインコード、URL、リンクの英字は数えない', () => {
  const text = `${JA}\n\n\`\`\`\n${EN}\n${EN}\n\`\`\`\n\`${EN}\` https://example.com/${'a'.repeat(40)} [${EN}](https://example.com)`
  expect(isForeign(text)).toBe(false)
})

test('短い英語の返事は見逃す', () => {
  expect(isEnglish('OK, done.')).toBe(false)
})

test('簡体字の文は中国語とみなす', () => {
  expect(isChinese(ZH)).toBe(true)
  expect(isForeign(ZH)).toBe(true)
})

test('仮名の無い長い文は簡体字が無くても中国語とみなす', () => {
  expect(isChinese('本次變更已經完成並且通過所有測試項目與檢查清單')).toBe(true)
})

test('漢字の多い日本語の文と、仮名の無い短い見出しは中国語とみなさない', () => {
  expect(isChinese('公開非公開境界厳守事項の一覧を作成し、設定変更履歴を確認した。')).toBe(false)
  expect(isChinese('## 設計方針\n| 案 A | 推奨 |\n| 案 B | 不採用 |')).toBe(false)
})

test('日本語の中に混じった中国語の文を拾う', () => {
  expect(isForeign(`${JA}\n${ZH}\n${JA}`)).toBe(true)
})

test('ツールの前の 1 行の前置きは見逃し、複数行の報告は見る', () => {
  expect(isMidReportForeign('Let me check the configuration file first.')).toBe(false)
  expect(isMidReportForeign(`${EN}\n${EN}`)).toBe(true)
  expect(isMidReportForeign(ZH)).toBe(false)
  expect(isMidReportForeign(`${ZH}\n${ZH}`)).toBe(true)
})

test('段落ごとに判定して、掛かった段落の先頭を返す', () => {
  expect(foreignPassages(`${JA}\n\n${EN}\n\n${ZH}`, isForeign)).toEqual([EN.slice(0, 80), ZH])
})
