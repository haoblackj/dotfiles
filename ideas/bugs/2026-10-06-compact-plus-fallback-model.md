# compact-plus のフォールバックが、手元の Codex のモデル一覧に無い gpt-5.4-mini を指している

## 見えたこと

モデルと effort のルーティング設計（haoblackj/dotfiles#34）の調査中に気づいた。
settings の `env.COMPACT_PLUS_FALLBACK_BACKEND` は `codex exec --model gpt-5.4-mini` を使っている。
手元の `~/.codex/models_cache.json`（codex-cli 0.160.0、2026-10-06 取得）のモデル一覧に `gpt-5.4-mini` が無い。
compact-plus のフォールバックが動かない可能性がある。
実行しての確認はしていない。

## 見つけた場所

- `linked/claude/settings.json` の `env.COMPACT_PLUS_FALLBACK_BACKEND`
- `~/.codex/models_cache.json`
