export type RepoRef = { owner: string; repo: string }

// url: Issue の URL から、command: gh のコマンドかその出力から、bare: プロンプトの裸の #N から
export type Source = 'url' | 'command' | 'bare'

export type Found = RepoRef & { number: number; source: Source }

export type Entry = RepoRef & {
  number: number
  source: Source
  title: string | null
  // pending は GitHub の答え待ちで、まだ描かない（裸の #N だけがこの状態で入る）
  status: 'pending' | 'shown'
}

declare module 'claude-code' {
  interface PluginState {
    'issue-link': { entries: Entry[] }
  }
}
