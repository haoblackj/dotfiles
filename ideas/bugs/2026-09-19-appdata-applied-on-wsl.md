# WSL 側のホームにも `~/AppData/...` が配布される

## 見えたこと

README を実態と突き合わせる作業で `chezmoi managed` を見たら、Windows Terminal 用の
`AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json` が
WSL 側でも管理対象に載っていた。実際に `/home/yagu001/AppData` が存在する。

## 見つけた場所

- ソース: `AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`
- `.chezmoiignore` の Linux 向けブロックには `AppData/Roaming/alacritty` しか無い

同じ `chezmoi managed` の出力で、`AGENTS.md` も WSL 側のターゲット（`~/AGENTS.md`）に載っていた。
`.chezmoiignore` には `/README.md` `/CLAUDE.md` はあるが `/AGENTS.md` が無い。

## 結果（2026-09-20、クローズ）

`.chezmoiignore` の Linux 側に `AppData` を、無条件側に `AGENTS.md` を追加し、
配られていた `~/AppData` と `~/AGENTS.md` はゴミ箱へ移した。
