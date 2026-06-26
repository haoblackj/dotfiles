# グローバル個人ルール

全プロジェクト共通の個人ポリシー。プロジェクト側 CLAUDE.md はこれを継承する。

## コスト制約

- `claude -p` / `claude --print`（非インタラクティブモード）の提案・実行を禁止する。
  追加 API コストが発生し、対話的な確認・操舵もできないため。
  ハード強制はユーザースコープの `permissions.deny`（`Bash(claude -p:*)` / `Bash(claude --print:*)`）で実施しており、auto mode を含む全モードで有効。
