# haoblackj's Dot Files

## Installation

```bash
# メインリポジトリを高速ミラー（例：JAIST）に
deb http://ftp.jaist.ac.jp/pub/Linux/ubuntu/ jammy main restricted universe multiverse
deb http://ftp.jaist.ac.jp/pub/Linux/ubuntu/ jammy-updates main restricted universe multiverse
deb http://ftp.jaist.ac.jp/pub/Linux/ubuntu/ jammy-backports main restricted universe multiverse

# セキュリティ更新だけは公式（ここは変えない）
deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse

sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply haoblackj
```

## Manual
```zsh
nvm install --lts
nvm use --lts
npm install -g yarn
npm install -g git-cz cz-conventional-changelog-ja aicommit2
source ~/.zshrc
aicommit2 config set OPENAI.locale="jp"
aicommit2 config set OPENAI.generate=5
aicommit2 config set OPENAI.key=<key>
```

```
brew install bitwarden-cli
gh repo clone joaojacome/bitwarden-ssh-agent
```
