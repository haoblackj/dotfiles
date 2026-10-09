# 自作スキルを dotfiles で開発する仕組み Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 公開する自作スキルを dotfiles の `skills/<名前>/` に置き、手元では chezmoi の symlink、クラウドでは `install-cloud.sh` の写しで配れるようにする。

**Architecture:** スキルの実体はリポジトリ直下の `skills/` に置き、`.chezmoiignore` でホームへのコピーを止める。手元へはスキルごとの `dot_claude/skills/symlink_<名前>.tmpl` が本チェックアウトへの symlink を張る（このプランではスキル本体を入れないので、テンプレートの型は手順の検証と文書で示す）。クラウドへは `install-cloud.sh` が `skills/*` の実体を `~/.claude/skills/` へ写す。

**Tech Stack:** bash、bats、chezmoi

**Spec:** `docs/superpowers/specs/2026-10-09-self-made-skills-design.md`

## Global Constraints

- 作業は dotfiles のワークツリー（`.worktrees/` の下）で行い、本チェックアウト（`~/.local/share/chezmoi`）は main に置いたままにする。
- コミットはパスを名指しする。既存ファイルは `git commit -- <パス>`、新規ファイルは `git add -N -- <パス>` を1ファイルずつ打ってから `git commit -- <パス>`。`git commit -a` と裸の `git commit` は使わない。
- 同期フック（`dot_claude/hooks/executable_claude-private-sync.sh`）は変えない。
- `~/.local/share/claude-private` のチェックアウトに触れない。`secrets/` と `memory/` は読まない。
- `install-cloud.sh` は失敗しても exit 0 で抜ける既存の方針を保つ。
- コミットメッセージの末尾に次の2行を付ける。
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01KyG9mZd6HTT5hYgqGQTXNB`

## Review Focus

- 手元の本チェックアウトで `chezmoi apply` を走らせたとき、`skills/` が `~/skills` として配られないこと（Task 2 の手順で確かめる）。
- symlink テンプレートが指す先が、ワークツリーではなく本チェックアウトの `skills/<名前>` になること（Task 2 の手順で確かめる）。
- `install-cloud.sh` を二度走らせたとき、ソースから消したファイルがクラウドの `~/.claude/skills/<名前>/` に残らないこと（Task 1 のテスト）。
- `skills/` の下の `SKILL.md` を持たないディレクトリを、スキルとして写さないこと（Task 1 のテスト）。
- クラウドで写したスキルが実際に読まれるか。スキル本体がまだ無いのでこのプランでは確かめられない。最初のスキルの PR で確かめることを dotfiles#48 に書く（Task 3）。

---

### Task 1: `install-cloud.sh` で `skills/` をクラウドへ写す

**Files:**
- Modify: `install-cloud.sh:125`（section 3 の後、`exit 0` の前）
- Modify: `install-cloud.bats`（末尾にテストを足す）
- Modify: `README.md:233-242`（「クラウドで配るもの」の表）

**Interfaces:**
- Consumes: なし
- Produces: ソースの `skills/<名前>/`（`SKILL.md` を持つもの）が、クラウドの `~/.claude/skills/<名前>/` へ写る。

- [ ] **Step 1: 失敗するテストを書く**

`install-cloud.bats` の末尾に足す。

```bash
@test "skills/ のスキルを ~/.claude/skills へ写す" {
    mkdir -p "$SRC/skills/demo/references"
    echo '---' >"$SRC/skills/demo/SKILL.md"
    echo ref >"$SRC/skills/demo/references/a.md"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    diff -r "$SRC/skills/demo" "$HOME/.claude/skills/demo"
}

@test "二度走らせても skills/ から消したファイルが残らない" {
    mkdir -p "$SRC/skills/demo"
    echo '---' >"$SRC/skills/demo/SKILL.md"
    bash "$SCRIPT" 2>/dev/null
    echo stale >"$HOME/.claude/skills/demo/stale.md"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.claude/skills/demo/stale.md" ]
}

@test "SKILL.md の無いディレクトリはスキルとして写さない" {
    mkdir -p "$SRC/skills/notaskill"
    echo x >"$SRC/skills/notaskill/README.md"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.claude/skills/notaskill" ]
}
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `bats install-cloud.bats`
Expected: 追加した1件目と2件目が FAIL（`~/.claude/skills/demo` が無い）。3件目は実装前でも PASS する（写す処理が無いため）。既存のテストは PASS のまま。

- [ ] **Step 3: 実装する**

`install-cloud.sh` の section 3 の `fi`（125行目）と `exit 0` の間に足す。

```bash

# 4. リポジトリ直下の skills/（公開の自作スキル）。手元では chezmoi が
#    dot_claude/skills/symlink_<名前>.tmpl で本チェックアウトへの symlink を張るが、
#    クラウドには chezmoi が無いので実体を写す。SKILL.md を持たないものは写さない。
for sk in "$SRC"/skills/*/; do
  [ -f "${sk}SKILL.md" ] || continue
  name=$(basename "$sk")
  mkdir -p "$HOME/.claude/skills"
  rm -rf "${HOME:?}/.claude/skills/$name"
  cp -R "${sk%/}" "$HOME/.claude/skills/$name"
  log "配置: ~/.claude/skills/$name"
done
```

`skills/` が無いときは glob がそのまま残り、`-f` の判定で飛ばされる。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bats install-cloud.bats`
Expected: 全件 PASS。

Run: `shellcheck install-cloud.sh`
Expected: 警告なし。

- [ ] **Step 5: README の表に行を足す**

`README.md` の「クラウドで配るもの」の表で、`.chezmoiexternal.toml` の git-repo external の行の直後に足す。

```markdown
| リポジトリ直下の `skills/<名前>/`（公開の自作スキル） | 配る | 実体を `~/.claude/skills/<名前>/` へ写す。`SKILL.md` を持たないディレクトリは写さない。クラウドで読まれるかは最初のスキルで確かめる（dotfiles#48） |
```

同じ節の「install-cloud.sh のメンテナンス」の箇条書きに1行足す。

```markdown
- `skills/` に足したスキルは、`install-cloud.sh` が自動で写す。非公開のスキルを `skills/` に置かない（公開リポジトリなので境界を越える）。
```

- [ ] **Step 6: コミットする**

```bash
git commit -m "feat(cloud): 公開の自作スキル（skills/）をクラウドへ写す

Refs #48

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KyG9mZd6HTT5hYgqGQTXNB" -- install-cloud.sh install-cloud.bats README.md
```

---

### Task 2: chezmoi でホームへ配らない設定と、手元の配り方の文書

**Files:**
- Modify: `.chezmoiignore`（`linked` の段落の後）
- Modify: `CLAUDE.md`（公開/非公開の境界の表、ファイル構造の図、スキルの段落）
- Modify: `README.md:166-179`（「公開と非公開の境界」の節）

**Interfaces:**
- Consumes: Task 1 の、クラウドへ写す処理（README で参照する）
- Produces: `skills/` がホームへ配られない。新しいスキルを足す手順が CLAUDE.md と README にある。

- [ ] **Step 1: `.chezmoiignore` に足す**

`linked` の行の直後に足す。

```
# 公開の自作スキルの実体。dot_claude/skills/symlink_<名前>.tmpl が
# ~/.claude/skills/<名前> からここへの symlink を張る。~/skills へは配らない
skills
```

- [ ] **Step 2: 使い捨てのソースで型を確かめる**

本番のホームと本チェックアウトに触れずに、`.chezmoiignore` と symlink テンプレートの組み合わせを確かめる。
`$SP` は scratchpad のディレクトリ（`/tmp/claude-1000/...`）。

```bash
SP=<scratchpad>
mkdir -p "$SP/src/skills/demo" "$SP/src/dot_claude/skills" "$SP/home"
echo '---' >"$SP/src/skills/demo/SKILL.md"
cp .chezmoiignore "$SP/src/.chezmoiignore"
printf '%s' '{{ .chezmoi.sourceDir }}/skills/demo' >"$SP/src/dot_claude/skills/symlink_demo.tmpl"
chezmoi apply --source "$SP/src" --destination "$SP/home" --config /dev/null --persistent-state "$SP/state.boltdb"
readlink "$SP/home/.claude/skills/demo"
ls "$SP/home"
```

Expected: `readlink` が `$SP/src/skills/demo` を出す。`ls` に `skills` が無い（`.claude` だけ）。
`.chezmoiignore` がテンプレートの変数で失敗するなら、`--config` に `$SP/chezmoi.toml`（空ファイル）を渡して試し直す。それでも失敗したら止めて報告する。
確かめ終わったら `trash-put "$SP/src" "$SP/home" "$SP/state.boltdb"`。

- [ ] **Step 3: CLAUDE.md を直す**

「公開/非公開の境界」の表に1行足す（`dot_claude/` の行の直後）。

```markdown
| リポジトリ直下の `skills/` (このrepo) | 公開の自作スキル。`dot_claude/skills/symlink_<名前>.tmpl` で `~/.claude/skills/<名前>` へ symlink する |
```

`~/.local/share/claude-private/` の行の内容を次に替える。

```markdown
| `~/.local/share/claude-private/` | memory 全体 / 機密・自作改変スキル（`idenshi-hakase-diet` / `learning-efficiency-book` / `report-skills` など）/ 移行前の自作スキル（dotfiles#49） |
```

ファイル構造の図で、`dot_claude/` の下に1行、`linked/` の行の後に1行足す。

```
  skills/symlink_<名前>.tmpl          — ~/.claude/skills/<名前> を skills/<名前> への symlink にする
skills/<名前>/SKILL.md                — 公開の自作スキルの実体（.chezmoiignore でホームへは配らない）
```

図の後の段落を次に替える。

```markdown
スキルの実体は `dot_claude/skills/` に実ディレクトリとして置かない（同期フックの `migrate_new` が claude-private へ吸い込む）。
公開の自作スキルはリポジトリ直下の `skills/` に置き、`dot_claude/skills/` には symlink テンプレートだけを置く。
`book-to-skill` は git external で upstream から clone し、機密のものは private repo に置いて sync hook が `~/.claude/skills/` へ symlink する。
開発の流れは README「公開の自作スキル」。
```

- [ ] **Step 4: README を直す**

「公開と非公開の境界」の節の最初の段落の後（`book-to-skill` の行の後）に、小節を足す。

````markdown
#### 公開の自作スキル

自作スキルは原則公開とし、リポジトリ直下の `skills/<名前>/SKILL.md` に置く（dotfiles#48）。
著作権に触れるものや私的な内容のものは claude-private に置く。

スキルごとに `dot_claude/skills/symlink_<名前>.tmpl` を置き、中身を次の1行にする。

```
{{ .chezmoi.sourceDir }}/skills/<名前>
```

`chezmoi apply` で `~/.claude/skills/<名前>` が本チェックアウトの `skills/<名前>` への symlink になる。
symlink なので、同期フックの `migrate_new` は claude-private へ吸い込まない。
名前は `~/.claude/skills/` に既にある名前と重ならないものにする。claude-private のスキルと重なると、同期フックと chezmoi のうち先に張った側が残る。

開発の流れ:

1. ワークツリーで `skills/<名前>/` と `dot_claude/skills/symlink_<名前>.tmpl` を書く。
2. `claude --plugin-dir <ワークツリーのルート>` の別セッションで試す。スキルは `<プラグイン名>:<名前>` で読まれ、本番の版とぶつからない。編集の後は `/reload-plugins`。
3. PR を出して main へマージする。
4. 本チェックアウトで `git pull` と `chezmoi apply`。起動中のセッションでは、新しい名前は `/reload-skills` で読まれ、既存のスキルの編集はそのまま効く。
5. 他のマシンは `chezmoi update`。

リポジトリ直下に、プラグインが自動で拾うディレクトリ（`agents/`、`commands/`、`hooks/`、`bin/`、`.mcp.json` など）を足すと、手順 2 で余計なものまで読まれる。
本チェックアウトを main 以外へ切り替えると、全セッションのスキルがそのブランチの版になる。
````

同じ節の同期の表の Stop の行はそのまま（自作スキルを symlink で配るので、吸い込みの対象にならない）。

- [ ] **Step 5: 全件のテストを走らせる**

Run: `bats install-cloud.bats`
Expected: 全件 PASS。

- [ ] **Step 6: コミットする**

```bash
git commit -m "feat(skills): 公開の自作スキルを skills/ に置き symlink で配る仕組み

Refs #48

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01KyG9mZd6HTT5hYgqGQTXNB" -- .chezmoiignore CLAUDE.md README.md
```

---

### Task 3: PR と issue の更新

**Files:** なし（GitHub の操作だけ）

- [ ] **Step 1: push して PR を出す**

```bash
git push -u origin HEAD
gh pr create --title "公開の自作スキルを dotfiles でブランチと履歴つきで開発する仕組み" --body "Refs #48（仕組みの部分。クラウドでの確認が残るので、マージでは閉じない）。スキル本体（penguinEx#97 のリサーチデザインのスキル）は別の PR。

- skills/ を .chezmoiignore で配らず、dot_claude/skills/symlink_<名前>.tmpl で symlink する形を README と CLAUDE.md に書いた
- install-cloud.sh が skills/ の実体をクラウドの ~/.claude/skills へ写す（bats を追加）

spec: docs/superpowers/specs/2026-10-09-self-made-skills-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01KyG9mZd6HTT5hYgqGQTXNB"
```

- [ ] **Step 2: 状態コメントを書く**

dotfiles#48 に `## 状態` のコメントを書き、一つ前の状態コメントをたたむ。「次の一手」に、最初のスキルの PR でクラウドのセッションに写したスキルが読まれるかを確かめること、読まれなければ Task 1 の写す処理を外すことを書く。
penguinEx#97 に、仕組みの PR のリンクと、マージの後にスキル本体へ進めることをコメントする。
