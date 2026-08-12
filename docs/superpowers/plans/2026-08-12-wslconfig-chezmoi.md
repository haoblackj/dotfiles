# .wslconfig の chezmoi 移行 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `_windows11-dotfiles` にプレーンファイルとして置かれている `.wslconfig` を chezmoi のテンプレート管理へ移し、自宅デスクトップ機だけに `memory=48GB` が乗るようにする。

**Architecture:** chezmoi ソースルートに `dot_wslconfig.tmpl` を置き、`hasPrefix "HIRO-DESKTOP" .chezmoi.hostname` で `memory` 行の有無を切り替える。該当しないマシンでは行ごと消え、WSL2 既定の「物理メモリの 50%」が効く。配布は Windows ネイティブの `chezmoi apply` が担い、WSL/Linux 側では `.chezmoiignore` で除外する。

**Tech Stack:** chezmoi v2.72.0(Go text/template + sprig)、git、WSL2

設計文書: `docs/superpowers/specs/2026-08-12-wslconfig-chezmoi-design.md`

## Global Constraints

- hostname のプレフィックスは `HIRO-DESKTOP`(連番運用のため完全一致にしない)。
- `memory` の値は `48GB`。musubi-tuner 向けに決めた既存値をそのまま移送し、再検討しない。
- `networkingMode=Mirrored` と `[experimental] hostAddressLoopback=true` は全マシン共通で出力する。
- WSL 側 `/home/yagu001/.local/share/chezmoi` と Windows 側 `C:/Users/yagu001/.local/share/chezmoi` は**別々の git クローン**。WSL 側の変更は push しない限り Windows 側に届かない。
- Windows 側のユーザー名はマシンによって異なる。テンプレートやパス指定でユーザー名をハードコードしない(chezmoi がホーム相対で解決する)。
- 作業開始時点で WSL 側 `main` は `origin/main` より 3 コミット先行、Windows 側は `origin/main` と同期・clean。

## File Structure

| ファイル | 役割 | 操作 |
| --- | --- | --- |
| `~/.local/share/chezmoi/dot_wslconfig.tmpl` | `.wslconfig` の唯一の正。hostname で `memory` 行を出し分ける | 新規作成 |
| `~/.local/share/chezmoi/.chezmoiignore` | 配布先 OS の絞り込み。`/.wslconfig` の記述位置を Windows 向けから非 Windows 向けへ移す | 修正 |
| `~/repo/github.com/haoblackj/_windows11-dotfiles/.wslconfig` | 旧管理。二重管理を残さないため削除 | 削除 |

---

### Task 1: chezmoi ソースにテンプレートを置き、除外の向きを直す

テンプレートの追加と `.chezmoiignore` の修正は分割しない。
現状の `.chezmoiignore` は Windows 側で `/.wslconfig` を除外しているため、テンプレートだけ置くと配布が止まったまま「入れたのに効かない」状態になる。
二つで一つの動作単位。

**Files:**
- Create: `/home/yagu001/.local/share/chezmoi/dot_wslconfig.tmpl`
- Modify: `/home/yagu001/.local/share/chezmoi/.chezmoiignore`

**Interfaces:**
- Consumes: `.chezmoi.hostname`(chezmoi 組み込み変数)、`hasPrefix`(sprig 関数)
- Produces: Windows 側 apply 時のターゲット `~/.wslconfig`。Task 2 がこの生成物を検証する

- [ ] **Step 1: 期待する出力を確定させる**

`HIRO-DESKTOP` で始まるホスト名のとき、以下の 6 行がこの順で出ること。

```ini
[wsl2]
memory=48GB
networkingMode=Mirrored

[experimental]
hostAddressLoopback=true
```

`HIRO-DESKTOP` で始まらないホスト名のとき、`memory` 行が消えた 5 行が出ること。

```ini
[wsl2]
networkingMode=Mirrored

[experimental]
hostAddressLoopback=true
```

- [ ] **Step 2: テンプレートを作成する**

`/home/yagu001/.local/share/chezmoi/dot_wslconfig.tmpl` を以下の内容で作成する。

```
[wsl2]
{{- if hasPrefix "HIRO-DESKTOP" .chezmoi.hostname }}
memory=48GB
{{- end }}
networkingMode=Mirrored

[experimental]
hostAddressLoopback=true
```

`{{-` の左トリムは必須。
これが無いと `if` 行そのものが空行として残り、`[wsl2]` の直後に不要な空行が入る。

- [ ] **Step 3: 実ホスト名での出力を検証する**

```bash
cd /home/yagu001/.local/share/chezmoi && chezmoi execute-template < dot_wslconfig.tmpl
```

現在のホスト名は `HIRO-DESKTOP02` なので、Step 1 の 6 行版と完全一致すること。
`[wsl2]` と `networkingMode` の間に `memory=48GB` があり、余分な空行が無いことを目視で確認する。

- [ ] **Step 4: 非該当ホスト名での出力を検証する**

hostname 参照を固定文字列に差し替えて評価する。

```bash
cd /home/yagu001/.local/share/chezmoi && sed 's/\.chezmoi\.hostname/"ESCO-PC-1234"/' dot_wslconfig.tmpl | chezmoi execute-template
```

Step 1 の 5 行版と完全一致すること。
`memory` の文字列がどこにも現れないこと。

- [ ] **Step 5: `.chezmoiignore` の Windows 向けブロックから `/.wslconfig` を削除する**

`{{ if eq .chezmoi.os "windows" -}}` で始まるブロック内の `/.wslconfig` の行を削除する。
このブロックは `.bashrc` や `.zshrc` など Linux 用ファイルを Windows で配布しないためのもので、`.wslconfig` がここにあるのは向きが逆。

削除対象は、コメント行「# Windows マシンのため、下記ファイルは chezmoi apply の対象から外す」の直後にある `/.wslconfig` の 1 行。

- [ ] **Step 6: `.chezmoiignore` の非 Windows 向けブロックに `/.wslconfig` を追加する**

`{{- if ne .chezmoi.os "windows" -}}` で始まるブロック内、コメント行「# Linux マシンのため、下記ファイルは chezmoi apply の対象から外す」の直後に以下を追加する。

```
# .wslconfig は Windows のユーザーホームに置くファイルで、WSL/Linux 側では読まれない
/.wslconfig
```

- [ ] **Step 7: WSL 側で除外されていることを検証する**

```bash
cd /home/yagu001/.local/share/chezmoi && chezmoi ignored | grep -x '.wslconfig'
```

`.wslconfig` が 1 行出力されること(終了コード 0)。
何も出ない場合は Step 6 の追加位置が非 Windows 向けブロックの外にある。

- [ ] **Step 8: WSL 側のホームに配布されないことを検証する**

```bash
cd /home/yagu001/.local/share/chezmoi && chezmoi apply --dry-run --verbose 2>&1 | grep -i wslconfig; echo "終了コード: $?"
```

`grep` が何もマッチせず終了コード 1 になること。
WSL 側のホームディレクトリに `.wslconfig` を作る動きが計画されていないことを意味する。

- [ ] **Step 9: 実ホームに誤って作られていないことを確認する**

```bash
ls -la /home/yagu001/.wslconfig 2>&1
```

「そのようなファイルやディレクトリはありません」と出ること。
存在した場合は Step 5 から 8 のいずれかが誤っているので、先に原因を特定してから進む。

- [ ] **Step 10: コミット**

```bash
cd /home/yagu001/.local/share/chezmoi && git add dot_wslconfig.tmpl .chezmoiignore && git commit -F - <<'EOF'
feat(wslconfig): .wslconfigをchezmoiテンプレート管理下に置く

_windows11-dotfilesのプレーンファイルから移送。hostnameがHIRO-DESKTOPで
始まるマシンにのみmemory=48GBを出力し、それ以外ではmemory行を出さない。
行が無い場合はWSL2既定の物理メモリ50%が効くため、物理48GB未満のマシンに
展開してもページファイル落ちが起きない。

.chezmoiignoreでは/.wslconfigをWindows向けブロックから非Windows向けへ移動。
元の位置はLinux用ファイル群と並んでおり、配布したい向きと逆だった。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01J9KnN4rPfceoE59qtQrVEU
EOF
```

---

### Task 2: Windows 側へ反映し、実環境で検証する

WSL 側と Windows 側は別クローンなので、push を挟む。
Windows 側でしか `.chezmoi.os` が `windows` にならないため、`.chezmoiignore` の分岐が正しいかは実機 apply でしか確認できない。

**Files:**
- 変更なし(既存コミットの配布と検証のみ)

**Interfaces:**
- Consumes: Task 1 が作成した `dot_wslconfig.tmpl` と修正済み `.chezmoiignore`
- Produces: Windows 側 `%USERPROFILE%\.wslconfig`。Task 3 はこれが正しく生成されたことを前提に旧ファイルを削除する

- [ ] **Step 1: WSL 側から push する**

```bash
cd /home/yagu001/.local/share/chezmoi && git push origin main && git log origin/main..HEAD --oneline
```

`git log` が何も出力しないこと。
先行コミットが解消され、Windows 側が pull できる状態になる。

- [ ] **Step 2: Windows 側で除外されていないことを先に確認する**

```bash
powershell.exe -NoProfile -Command "chezmoi ignored" 2>&1 | tr -d '\r' | grep -x '.wslconfig'; echo "終了コード: $?"
```

`grep` が何もマッチせず終了コード 1 になること。
Windows 側では `.wslconfig` が配布対象に含まれることを意味する。

この時点では Windows 側のソースがまだ古く `dot_wslconfig.tmpl` を持たないが、`.chezmoiignore` の評価には影響しない。
ここで `.wslconfig` がマッチした場合、Task 1 の Step 5 が反映されていないので Step 3 に進まない。

- [ ] **Step 3: Windows 側で更新を取り込む**

```bash
powershell.exe -NoProfile -Command "chezmoi update --verbose" 2>&1 | tr -d '\r'
```

`chezmoi update` は git pull の後に apply を実行する。
出力に `.wslconfig` への書き込みが現れること。

Windows 側は作業開始時点で clean なので、pull は fast-forward で通る。
コンフリクトが出た場合は Windows 側に手元の変更があるので、内容を確認するまで先に進まない。

- [ ] **Step 4: 生成された `.wslconfig` を検証する**

```bash
powershell.exe -NoProfile -Command "Get-Content \$env:USERPROFILE\.wslconfig" 2>&1 | tr -d '\r'
```

Task 1 Step 1 の 6 行版と完全一致すること。
メインPCのホスト名は `HIRO-DESKTOP02` なので `memory=48GB` を含む。

- [ ] **Step 5: WSL 側から同じファイルを読んで二重確認する**

```bash
cat /mnt/c/Users/$(powershell.exe -NoProfile -Command '$env:UserName' 2>/dev/null | tr -d '\r')/.wslconfig
```

Step 4 と同じ内容が出ること。
Windows 側パスとの往復で、書き込み先が想定どおりかを確かめる。

- [ ] **Step 6: 反映済みであることを記録する**

`memory=48GB` が実際に WSL2 に効くのは次回の VM 起動時。
`wsl --shutdown` は現在の WSL セッション自身を終了させるため、この計画の中では実行しない。
リーダーが任意のタイミングで Windows 側から `wsl --shutdown` を実行し、WSL を起動し直したあと、以下で確認する。

```bash
free -g | awk '/^Mem:/ {print $2 "GB"}'
```

再起動前の実測値は `30GB`(物理 61.7GB に対する既定の 50%)。
再起動後に 47 前後へ増えていれば反映されている(48GB 指定に対し、カーネル予約分を引いた値になる)。
値が 30 のままなら、`.wslconfig` が読まれていないか VM が再作成されていない。

---

### Task 3: 旧管理を `_windows11-dotfiles` から削除する

Task 2 で chezmoi 経由の配布が実際に動いたことを確認してから実行する。
順序を逆にすると、どちらの管理も効いていない期間が生まれる。

**Files:**
- Delete: `/home/yagu001/repo/github.com/haoblackj/_windows11-dotfiles/.wslconfig`

**Interfaces:**
- Consumes: Task 2 で検証済みの Windows 側 `.wslconfig`
- Produces: なし(最終タスク)

- [ ] **Step 1: 削除前に現在の状態を確認する**

```bash
cd /home/yagu001/repo/github.com/haoblackj/_windows11-dotfiles && git status --short && git log origin/master..HEAD --oneline
```

working tree が clean で、`5d52122` が未 push のまま 1 コミット先行していること。
未 push の変更が他にもある場合は、削除に進む前に内容を確認する。

- [ ] **Step 2: `.wslconfig` を削除する**

```bash
cd /home/yagu001/repo/github.com/haoblackj/_windows11-dotfiles && git rm .wslconfig
```

`5d52122` は revert しない。
`memory=48GB` に至った経緯を履歴に残したまま、削除コミットを重ねる。

- [ ] **Step 3: 他に `.wslconfig` を参照している箇所が無いか確認する**

```bash
cd /home/yagu001/repo/github.com/haoblackj/_windows11-dotfiles && grep -rn "wslconfig" --exclude-dir=.git .; echo "終了コード: $?"
```

何もマッチせず終了コード 1 になること。
2026-08-12 時点の実測では参照は無かったが、削除の直前にもう一度確かめる。
セットアップスクリプトが `.wslconfig` をコピーしている場合はここで見つかるので、その箇所も同じコミットで直す。

- [ ] **Step 4: コミット**

```bash
cd /home/yagu001/repo/github.com/haoblackj/_windows11-dotfiles && git commit -F - <<'EOF'
chore: .wslconfigをchezmoi管理へ移したため削除

haoblackj/dotfiles の dot_wslconfig.tmpl が唯一の正となった。
マシンごとにmemory値を出し分ける必要があり、マシン差分を表現できない
このリポジトリでは扱えないため移送した。

README手順8のchezmoi init --applyが配布を担うため、手順の変更は不要。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01J9KnN4rPfceoE59qtQrVEU
EOF
```

- [ ] **Step 5: push の可否を確認する**

`5d52122`(`memory=48GB` への変更)は push が保留されたままになっている。
削除コミットと合わせて push すると、リモート上では「48GB にした後で削除した」という履歴になり、危険な状態が公開リポジトリに残らない。

push するかどうかはリーダーに確認してから実行する。
保留のままにする判断もあり得るため、この計画では push を既定の動作にしない。

---

## 完了条件

Windows 側 `%USERPROFILE%\.wslconfig` が chezmoi によって生成され、`memory=48GB` を含む 6 行になっている。

`_windows11-dotfiles` に `.wslconfig` が存在しない。

WSL 側のホームに `.wslconfig` が作られていない。

`chezmoi ignored` が WSL 側では `.wslconfig` を含み、Windows 側では含まない。
