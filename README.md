# haoblackj's Dot Files

## Installation

```bash
CODENAME=$(lsb_release -cs) && \
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak && \
( sudo tee /etc/apt/sources.list > /dev/null <<EOF
# JAIST mirror (primary)
deb http://ftp.jaist.ac.jp/pub/Linux/ubuntu/ $CODENAME main restricted universe multiverse
deb http://ftp.jaist.ac.jp/pub/Linux/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb http://ftp.jaist.ac.jp/pub/Linux/ubuntu/ $CODENAME-backports main restricted universe multiverse

# WIDE mirror (fallback)
deb http://ftp.tsukuba.wide.ad.jp/Linux/ubuntu/ $CODENAME main restricted universe multiverse
deb http://ftp.tsukuba.wide.ad.jp/Linux/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb http://ftp.tsukuba.wide.ad.jp/Linux/ubuntu/ $CODENAME-backports main restricted universe multiverse

# Security (official)
deb http://security.ubuntu.com/ubuntu $CODENAME-security main restricted universe multiverse
EOF
) && \
echo 'Acquire::http::Timeout "5";' | sudo tee /etc/apt/apt.conf.d/99timeout > /dev/null

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
