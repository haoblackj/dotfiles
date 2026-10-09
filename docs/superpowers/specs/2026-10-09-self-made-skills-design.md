# 自作スキルを dotfiles でブランチと履歴つきで開発する

issue: https://github.com/haoblackj/dotfiles/issues/48

## 目的

自作のグローバルスキルを、ブランチ、PR、履歴つきで開発できるようにする。

今の自作スキルの実体は claude-private の `skills/` にある。
claude-private には同期フック（`claude-private-sync.sh`）が全セッションで pull と memory の自動コミットをかけるので、そのチェックアウトでブランチを切ると、他セッションの同期コミットが載る。
dotfiles の `dot_claude/skills/` に実ディレクトリとして置くと、`migrate_new` が apply の後に claude-private へ吸い込む。
最後にコピーで反映する方式は、スキルの履歴が二つのリポジトリに割れるので退けた。

## 決定済みの前提

- 2026-06-18 のコミット ab0790b で自作スキルを dotfiles から外した理由は、二重管理の解消だった。公開を避けたからではない。
- 自作スキルは原則公開とする。著作権に触れるものや私的な内容のものだけを claude-private に残す。
- 置き場所は dotfiles とし、chezmoi の symlink で配る。専用リポジトリ案と個人マーケットプレイス案は退けた（理由は issue の決定コメント）。
- claude-private にある既存の自作スキルの移行は、この設計の範囲の外とし、別 issue で扱う。

## 設計

### 置き場所

スキルの実体は、リポジトリ直下の `skills/<名前>/SKILL.md` に置く。
`.chezmoiignore` に `skills` を足し、chezmoi がホームの `~/skills` へ写さないようにする。

`linked/claude/skills/` は使わない。
`linked/claude/` には `settings.json` があり、そこを `--plugin-dir` に渡すと、プラグインの設定ファイルとして読まれうるからである。
リポジトリ直下には、プラグインが自動で拾うディレクトリ（`agents/`、`commands/`、`hooks/`、`bin/`、`.mcp.json` など）が無いので、ワークツリーのルートをそのまま `--plugin-dir` に渡せる。
直下にこれらの名前のディレクトリを足すときは、この前提が崩れることに注意する。

### 配り方

スキルごとに `dot_claude/skills/symlink_<名前>.tmpl` を1つ置く。
中身は次の1行で、`dot_claude/symlink_settings.json.tmpl` と同じ型である。

```
{{ .chezmoi.sourceDir }}/skills/<名前>
```

`chezmoi apply` で `~/.claude/skills/<名前>` が本チェックアウト（`~/.local/share/chezmoi`）の `skills/<名前>` への symlink になる。
`~/.claude/skills/<名前>` を別の場所への symlink にする形は、公式ドキュメント（https://code.claude.com/docs/en/skills）が明記している。

同期フックは変えない。
`migrate_new` は symlink を飛ばすので、claude-private への吸い込みは起きない。
`ensure_symlinks` は claude-private の `skills/` にある名前しか触らない。

名前が claude-private のスキルと重なると、`ensure_symlinks` と chezmoi のうち先に張った側が残り、どちらが効くかが決まらない。
新しいスキルの名前は、`~/.claude/skills/` に既にある名前と重ならないものにする。これを README に書く。

### 開発の流れ

1. dotfiles のワークツリーで `skills/<名前>/` と `dot_claude/skills/symlink_<名前>.tmpl` を書く。
2. 別のセッションを `claude --plugin-dir <ワークツリーのルート>` で立てて試す。スキルは `<プラグイン名>:<名前>` の名前空間つきで読まれるので、本番の symlink の版とぶつからない。編集の後は `/reload-plugins` で読み直す。
3. PR を出して main へマージする。
4. 本チェックアウトで `git pull` と `chezmoi apply` を行う。新しい名前のスキルは、起動中のセッションでは `/reload-skills` を打つと読まれる。既存のスキルの編集は、ライブリロードでそのまま効く。
5. 他のマシンは `chezmoi update` で追いつく。

本チェックアウトを main 以外のブランチへ切り替えている間は、全セッションのスキルがそのブランチの版になる。
開発はワークツリーで行い、本チェックアウトは main に置いたままにする（既存の運用と同じ）。

### クラウドセッション

`install-cloud.sh` に、ソースの `skills/*` をクラウドの `~/.claude/skills/` へ写す処理を足す。
写すのは実体のディレクトリで、symlink テンプレートは読まない（クラウドには chezmoi が無い）。
`install-cloud.bats` に、`skills/<名前>/SKILL.md` が `~/.claude/skills/<名前>/SKILL.md` へ写ることのテストを足す。
README の「クラウドで配るもの」の表に行を足す。

公式の skills のページは、personal skills はクラウドのセッションで読まれないと書いている。
これが手元から持ち込まれないことを指すのか、コンテナの `~/.claude/skills/` に置いても読まれないことを指すのかは、文書からは決まらない。
実装の後に、クラウドのセッションでスキルが一覧に出るかを確かめる。
読まれなかった場合は、写す処理を外し、クラウドでは使えないことを README に書く。

### 文書

- `CLAUDE.md` の「スキルは `dot_claude/skills/` には置かない」の段落とファイル構造の図を、新しい置き場所に合わせる。
- README の、スキルの配置と同期フックの説明に、公開の自作スキルの置き場所、開発の流れ、名前の重複の注意を足す。

## テスト

- `install-cloud.bats` の追加分を、pre-push の bats で通す。
- 手元で、最初のスキルを入れた後に `chezmoi apply` を走らせ、`~/.claude/skills/<名前>` が本チェックアウトへの symlink になること、同期フックの push を走らせても claude-private へ吸い込まれないことを確かめる。
- `claude --plugin-dir <ワークツリー>` のセッションで、`<プラグイン名>:<名前>` としてスキルが読まれることを確かめる。
- クラウドのセッションで、写したスキルが読まれるかを確かめる。

## 最初の利用者

penguinEx の調査前にリサーチデザインを組み立てさせるスキル（penguinEx#97、claude-private#2）を、この流れで dotfiles に置く最初のスキルとする。
仕組み（置き場所、symlink、`.chezmoiignore`、クラウドへの写し、文書）は、このスキルの PR とは別の PR で先に入れる。
