// 応答の本文が英語主体か、中国語の文を含むかを判定する。
// 英語の判定と途中の報告の閾値は minorun365/claude-code-japanese-guard（Apache-2.0、NOTICE を参照）を
// TypeScript へ移したもの。中国語の判定はここで足した。

// 英字がこれ未満の本文は判定しない（「OK」「Done」程度の短い返事は見逃す）
export const MIN_LATIN = 25
// ツール呼び出しの前の報告（複数行）は、英字がこれ以上あるときだけ判定する
export const MIN_LATIN_MID = 60
// 1 行の報告は、英字がこれ以上ある長い段落のときだけ判定する
export const MIN_LATIN_MID_LONG = 250
// 英字の数が日本語の文字数のこの倍を超えたら、英語主体とみなす
export const RATIO = 3

// 仮名の無い文の漢字がこれ以上なら中国語とみなす（日本語の文は、この長さならほぼ必ず仮名を含む）
export const MIN_HAN_NO_KANA = 15
// 仮名の無い文に、日本語で使わない簡体字がこれ以上あれば、短くても中国語とみなす
export const MIN_SIMPLIFIED = 2
// 中国語とみなした文の漢字を合わせてこれ未満なら判定しない（語句の引用を見逃す）
export const MIN_HAN_CHINESE = 10
// 1 行の報告の中国語は、漢字がこれ以上ある長い段落のときだけ判定する
export const MIN_HAN_CHINESE_MID_LONG = 80

const JA = /[ぁ-んァ-ヶ一-龥]/g
const LATIN = /[A-Za-z]/g
const KANA = /[ぁ-んァ-ヶ]/g
const HAN = /[一-鿿]/g
// 日本語の字形と別の符号位置を持つ簡体字のうち、よく出るもの。「的」「是」「来」のように
// 日本語でも使う字は入れない。
const SIMPLIFIED = /[们这说时为还过么吗呢个对发现实问题应该让给进动经样种关开头东车门间见觉记话认读请谢边运选带里]/g
const IGNORE = [/```[\s\S]*?```/g, /`[^`\n]*`/g, /https?:\/\/\S+/g, /[\w.+-]+@[\w-]+\.[\w.-]+/g, /\[[^\]]*\]\([^)]*\)/g]

const count = (text: string, re: RegExp) => text.match(re)?.length ?? 0

/** コード、インラインコード、URL、メールアドレス、Markdown のリンクを除く。英語の例示は正当なため。 */
export const stripIgnored = (text: string) => IGNORE.reduce((t, re) => t.replace(re, ''), text)

export const isEnglish = (text: string, minLatin = MIN_LATIN) => {
  const t = stripIgnored(text)
  const latin = count(t, LATIN)
  return latin >= minLatin && latin > count(t, JA) * RATIO
}

/** 中国語とみなした文の漢字の合計。文は句点、感嘆符、疑問符、改行で区切る。 */
export const chineseHan = (text: string) =>
  stripIgnored(text)
    .split(/[。！？!?\n]/)
    .filter(s => count(s, KANA) === 0)
    .filter(s => count(s, HAN) >= MIN_HAN_NO_KANA || count(s, SIMPLIFIED) >= MIN_SIMPLIFIED)
    .reduce((n, s) => n + count(s, HAN), 0)

export const isChinese = (text: string, minHan = MIN_HAN_CHINESE) => chineseHan(text) >= minHan

/** 最終回答の判定。 */
export const isForeign = (text: string) => isEnglish(text) || isChinese(text)

/** ツール呼び出しの前の報告の判定。1 行の前置きは見逃し、複数行か長い段落だけを見る。 */
export const isMidReportForeign = (text: string) => {
  const lines = text.trim().split('\n').filter(l => l.trim() !== '')
  return lines.length >= 2
    ? isEnglish(text, MIN_LATIN_MID) || isChinese(text)
    : isEnglish(text, MIN_LATIN_MID_LONG) || isChinese(text, MIN_HAN_CHINESE_MID_LONG)
}

/** 差し戻しの理由に引く、段落の先頭 80 文字。 */
export const head = (text: string, label = '') => label + (text.trim().split('\n')[0] ?? '').slice(0, 80)

/** 本文を段落（空行区切り）に分け、判定に掛かった段落の先頭を返す。 */
export const foreignPassages = (text: string, judge: (t: string) => boolean, label = '') =>
  text
    .split(/\n\s*\n/)
    .filter(p => p.trim() !== '' && judge(p))
    .map(p => head(p, label))
