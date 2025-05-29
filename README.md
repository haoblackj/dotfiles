# haoblackj's Dot Files

## Installation

```bash
CODENAME=$(lsb_release -cs) && \
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak && \
sudo tee /etc/apt/sources.list > /dev/null <<EOF
# Main JAIST mirror
deb http://ftp.jaist.ac.jp/pub/Linux/ubuntu/ $CODENAME main restricted universe multiverse
deb http://ftp.jaist.ac.jp/pub/Linux/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb http://ftp.jaist.ac.jp/pub/Linux/ubuntu/ $CODENAME-backports main restricted universe multiverse

# Security updates - DO NOT REPLACE
deb http://security.ubuntu.com/ubuntu $CODENAME-security main restricted universe multiverse
EOF

sudo mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.disabled

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
