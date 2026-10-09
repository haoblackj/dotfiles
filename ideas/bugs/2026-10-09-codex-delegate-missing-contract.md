# codex-delegate.sh が、削除済みの委譲契約を求めて止まる

## 見えたこと

`~/.codex/codex-delegate.sh --repo <worktree> -m gpt-6.1-sol -e medium -o <file> <brief>` を走らせたら、次を出して exit 1 で止まった。

```
NG: 委譲契約が無い: /home/yagu001/.codex/delegation-contract.md (chezmoi apply ~/.codex/delegation-contract.md を実行する)
```

`chezmoi status ~/.codex/delegation-contract.md` は `not managed` を返した。
コミット f5b97e8（2026-09-03）が `dot_codex/delegation-contract.md` を削除している。

## 見つけた場所

- `dot_codex/executable_codex-delegate.sh`（`CONTRACT` の既定値と、無いときに止める判定）
