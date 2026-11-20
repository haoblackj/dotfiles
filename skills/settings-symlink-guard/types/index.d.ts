// 外れているときの状態の文。正しい symlink なら null
export type Broken = string | null

declare module 'claude-code' {
  interface PluginState {
    'settings-symlink-guard': { broken: Broken }
  }
}
