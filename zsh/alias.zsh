alias sudo='sudo '
# alias systemctl='/usr/libexec/nslogin systemctl'
alias gco="git checkout"
alias gcob="git checkout -b"
alias ghprc="gh prc"
alias ghprw="gh prw"
alias ghrw="gh rw"
alias ghauth="gh auth login -h github.com -p https -w"
alias ansible='docker container run --rm -it --mount type=bind,src="$(pwd)",dst=/app ansible ansible'
alias ansible-playbook='docker container run --rm -it --mount type=bind,src="$(pwd)",dst=/app ansible ansible-playbook'