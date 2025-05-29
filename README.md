# haoblackj's Dot Files

## Installation

```bash
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
