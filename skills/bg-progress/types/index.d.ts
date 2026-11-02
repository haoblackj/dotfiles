export type Unit = 'bytes' | 'lines'

// at はエポックミリ秒
export type Sample = { at: number; amount: number }

export type Job = {
  name: string
  paths: string[]
  unit: Unit
  total: number
  taskId?: string
  startedAt: number
  // 直近 60 秒ぶんだけ持つ
  samples: Sample[]
  // 量が最後に増えた時刻
  lastGrowthAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'bg-progress': { jobs: Job[] }
  }
}
