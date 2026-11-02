import type { EngineInterface } from 'claude-code'

import type { Unit } from '../types'

export const parseDu = (stdout: string): number =>
  stdout
    .split('\n')
    .map(line => Number.parseInt(line, 10))
    .filter(n => Number.isFinite(n))
    .reduce((a, b) => a + b, 0)

export const parseWc = (stdout: string): number => {
  const n = Number.parseInt(stdout.trim(), 10)
  return Number.isFinite(n) ? n : 0
}

// 無いパスがあると du / find は 0 以外で終わるが、在るパスの分は stdout に出るので読む。
// du -sb は見かけの大きさを数え、隠しディレクトリ（hf download の .incomplete）も含む。
// エンジンは import 先へ $ を渡すとき function 宣言しか辿らないので、矢印関数にしない。
export async function measure($: EngineInterface, paths: string[], unit: Unit): Promise<number> {
  const argv =
    unit === 'bytes'
      ? ['du', '-sb', '--', ...paths]
      : ['sh', '-c', 'find "$@" -type f -exec cat -- {} + 2>/dev/null | wc -l', 'sh', ...paths]
  const { stdout } = await $.process.run(argv)
  return unit === 'bytes' ? parseDu(stdout) : parseWc(stdout)
}
