# Claude Code 設定の管理・移行ガイド

chezmoi で管理している Claude Code 設定（settings / keybindings / skills / memory）の  
セットアップ・移行・メモリマージ手順をまとめたドキュメント。

## 構成概要

```
公開 repo (github.com/haoblackj/dotfiles)  ← chezmoi source: ~/.local/share/chezmoi
  ~/.claude/settings.json            — hook 設定（sync script の呼び出し元）
  ~/.claude/keybindings.json         — キーバインド
  ~/.claude/CLAUDE.md / rules/ / output-styles/ / agents/
  ~/.claude/hooks/claude-private-sync.sh — 同期スクリプト本体
  ~/.claude/skills/book-to-skill/    — 公開外部スキル（.chezmoiexternal.toml の git-repo external）

private repo (github.com/haoblackj/claude-private)  ← clone 先: ~/.local/share/claude-private
  memory/<proj>/*.md   — プロジェクトごとのメモリ（セッション終了時に自動 push）
  skills/<name>/       — 機密・自作改変スキル（learning-efficiency-book、report-skills、dig など）
  secrets/             — memory_recall.py が使う Cloudflare のトークン
```

スキルの置き場所の境界は README「Claude Code」の節が正で、ここには写さない。
`dot_claude/skills/` にはスキルを置かない。公開スキルは external、それ以外は private repo に置く。

**ライブ上のシンボリックリンク**（sync script が自動生成）：
- `~/.claude/projects/<proj>/memory` → `~/.local/share/claude-private/memory/<proj>`
- `~/.claude/skills/<name>` → `~/.local/share/claude-private/skills/<name>`（private repo の `skills/` 配下すべて）

---

## 1. 新マシンへの初期セットアップ

手順は README「導入手順」が正で、ここには写さない。
Claude Code に関わる要点だけ書く。

- `~/.local/share/claude-private` の clone は `chezmoi apply` の external が行う。GitHub の認証（`gh auth login`、`repo` スコープ）が要るので、README のとおり初回は `--exclude=externals` でスクリプトを先に走らせる。
- symlink の生成は chezmoi でなく hook が行う。Claude Code の SessionStart で `claude-private-sync.sh pull` が走る。

hook が動く前に symlink を確認したいときは、hook を直接叩く。

```sh
~/.claude/hooks/claude-private-sync.sh pull
# 実行後に確認:
ls -la ~/.claude/projects/*/memory
ls -la ~/.claude/skills
```

---

## 2. 他マシンの既存コンテンツを取り込む

### 2-A. メモリを取り込む

#### 状況: 他マシンで memory の symlink がまだ設定されておらず、実ディレクトリとして存在する場合

sync script の `migrate_new()` 関数が**セッション終了時（Stop hook）に自動で移行**する。

1. 他マシン上でそのまま Claude Code セッションを終了する
2. Stop hook が実ディレクトリの `.md` ファイルを `claude-private` へコピー → commit/push → symlink に置換
3. このマシンで Claude Code を起動すると SessionStart hook が pull + symlink 生成して完了

#### 状況: 他マシンのメモリを手動で取り込みたい場合

```sh
# このマシンで:
STAGE=~/.local/share/claude-private
PROJ="<他マシンのプロジェクトディレクトリ名>"   # 例: -home-alice-repo-xxx

# 1. 他マシンから取得（例: rsync / scp / wsl コピー等）
#    他マシンの ~/.claude/projects/<PROJ>/memory/ の中身を
mkdir -p "$STAGE/memory/$PROJ"
cp -a /path/to/other/machine/memory/. "$STAGE/memory/$PROJ/"

# 2. commit/push
git -C "$STAGE" add -A
git -C "$STAGE" commit -m "import: memory from <machine-name>"
git -C "$STAGE" push

# 3. シンボリックリンクを生成
~/.claude/hooks/claude-private-sync.sh pull
```

### 2-B. スキルを取り込む

```sh
STAGE=~/.local/share/claude-private

# スキルファイルをステージングに配置
cp -a /path/to/skill "$STAGE/skills/"

git -C "$STAGE" add -A
git -C "$STAGE" commit -m "add: skill from other machine"
git -C "$STAGE" push

# シンボリックリンクが必要なら手動（または次の Claude Code 起動で hook が自動生成）
ln -sf "$STAGE/skills/new-skill" ~/.claude/skills/new-skill
```

### 2-C. git pull 時の merge conflict 解消

`claude-private` で複数マシンが並行してコミットしてコンフリクトした場合：

```sh
cd ~/.local/share/claude-private
git pull --ff-only   # 失敗 → rebase/merge が必要
git fetch origin
git merge origin/main   # コンフリクトがあれば次のセクション(3)を参照
```

---

## 3. メモリ内容のマージを Claude Code に指示する

別セッションの Claude Code（または別プロジェクト）でメモリのマージ・整理を行いたい場合、  
下記プロンプトをコピーして Claude Code に貼り付ける。

---

### 3-A. 複数マシン由来の重複メモリをマージするプロンプト

```
以下のタスクをお願いします。

## コンテキスト
~/.local/share/claude-private/memory/ 以下に複数マシン由来のメモリディレクトリがあります。
同じプロジェクトの別バージョン、または重複した内容のメモリファイルが存在する可能性があります。

## やること
1. `find ~/.local/share/claude-private/memory -name "*.md" | sort` で全メモリファイルを一覧表示
2. 内容が重複または矛盾するファイルを特定（特に feedback_*.md と user_*.md）
3. 重複エントリを統合：
   - より新しい・詳細な方を残す
   - 矛盾する場合は両方を残してコメントで注記
   - 完全に同一な内容は削除
4. 整理後、git -C ~/.local/share/claude-private add -A && git -C ~/.local/share/claude-private commit -m "chore: merge duplicate memories"
5. 変更内容の要約を報告

注意: ~/.claude/projects/*/memory/ のシンボリックリンク先は ~/.local/share/claude-private/memory/ なので、
直接 claude-private 側を編集してください。
```

---

### 3-B. git merge conflict になったメモリファイルを解消するプロンプト

```
以下のタスクをお願いします。

## コンテキスト
~/.local/share/claude-private で git merge conflict が発生しました。
複数マシンからの同期によりメモリ(*.md)ファイルにコンフリクトマーカーが入っています。

## やること
1. `git -C ~/.local/share/claude-private diff --name-only --diff-filter=U` でコンフリクトファイルを確認
2. 各コンフリクトファイルを読み、<<<<<<< / ======= / >>>>>>> マーカーを解消:
   - メモリファイルは append-only な性質なので、基本的に両方の内容を残してマージ
   - 全く同一の記述は1つに統合
   - ファイルの frontmatter (name, description, type) は新しい方を採用
3. 解消後: git -C ~/.local/share/claude-private add -A && git -C ~/.local/share/claude-private commit -m "fix: resolve memory merge conflicts"
4. git push -C ~/.local/share/claude-private push
5. `~/.claude/hooks/claude-private-sync.sh pull` でシンボリックリンクを再整備
6. 解消した内容の要約を報告
```

---

### 3-C. 現在のメモリを棚卸しして整理するプロンプト

```
以下のタスクをお願いします。

## コンテキスト
~/.local/share/claude-private/memory/ 以下に蓄積されたメモリを棚卸ししてください。

## やること
1. 全メモリファイルを読む（find + Read ツール）
2. 以下を確認・修正:
   a. type フィールドが正しいか（user / feedback / project / reference）
   b. 内容が stale になっていないか（古いプロジェクト、解消済みの課題）
   c. description が一行で要点を掴めるか
   d. Why / How to apply 行が feedback/project タイプに揃っているか
3. MEMORY.md インデックスを最新状態に更新（各エントリ 150 字以内）
4. 整理後 commit/push:
   git -C ~/.local/share/claude-private add -A
   git -C ~/.local/share/claude-private commit -m "chore: tidy memory index and stale entries"
   git -C ~/.local/share/claude-private push
5. 変更のサマリーを報告
```

---

## 4. 同期の仕組み（参考）

| タイミング | 何が起きるか |
|---|---|
| `chezmoi apply` | `claude-private` repo を `~/.local/share/claude-private` に clone/pull |
| Claude Code セッション開始 | `claude-private-sync.sh pull` — ff-pull + symlink 確認 |
| Claude Code セッション終了 | `claude-private-sync.sh push` — 未取り込みの実 memory を migration → commit/push |
| `chezmoi apply`（weekly） | book-to-skill も `refreshPeriod: 168h` で更新 |

### 新プロジェクトの memory が自動で取り込まれる流れ

1. Claude Code が新プロジェクトで memory に書き込む  
   → `~/.claude/projects/<new-proj>/memory/*.md` が実ディレクトリに作られる
2. セッション終了時 Stop hook が `migrate_new()` を実行  
   → 実ディレクトリを `claude-private/memory/<new-proj>/` にコピー → commit/push  
   → 元の実ディレクトリを symlink に置換
3. 他マシンの次回セッション開始時に SessionStart hook が pull → symlink 生成

---

## 5. トラブルシューティング

### push が失敗する（token 権限）

```sh
gh auth status   # scopes に 'repo' があるか確認
gh auth refresh -s repo
```

### ff-pull が失敗する（diverge）

```sh
cd ~/.local/share/claude-private
git fetch origin
git log --oneline HEAD..origin/main   # リモートの差分確認
git merge origin/main                 # または git rebase origin/main
```

### symlink が壊れている

```sh
~/.claude/hooks/claude-private-sync.sh pull   # 再生成
```

### chezmoi external の再取得

```sh
chezmoi apply --exclude=scripts
# または特定の external だけ:
chezmoi apply ~/.local/share/claude-private
chezmoi apply ~/.claude/skills/book-to-skill
```
