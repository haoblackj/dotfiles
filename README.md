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
aicommit2 config set OPENAI.locale="jp"
aicommit2 config set OPENAI.generate=5
```
