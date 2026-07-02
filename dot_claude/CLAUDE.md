# グローバル個人ルール

全プロジェクト共通の個人ポリシー。プロジェクト側 CLAUDE.md はこれを継承する。

## プラン実行方式

- 実装プランの実行は**サブエージェント駆動**（superpowers:subagent-driven-development）をデフォルトとする。
  インライン実行（superpowers:executing-plans）にするのは、(1) ユーザーが明示的に指示した場合、
  または (2) 明らかにインラインが適切な場合（タスク1つの極小プラン等）のみ。
  このルールは言語・表記揺れ（subagent-driven / サブエージェント駆動 等）にかかわらず適用する。

## コスト制約

- `claude -p` / `claude --print`（非インタラクティブモード）の提案・実行を禁止する。
  追加 API コストが発生し、対話的な確認・操舵もできないため。
  ハード強制はユーザースコープの `permissions.deny`（`Bash(claude -p:*)` / `Bash(claude --print:*)`）で実施しており、auto mode を含む全モードで有効。
