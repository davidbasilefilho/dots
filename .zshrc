eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
eval "$(starship init zsh)"

alias nv='nvim'
alias ls='eza -lah --color=auto --icons=auto'
alias cmatrix='cmatrix -b'
alias tuxsay="cowsay -f tux 'neovim is the best'"
alias cd='zoxide'
alias ..='zoxide ..'

if ! tmux has-session 2>/dev/null; then
    tmux
else
  tmux attach-session -t 0 || tmux attach
fi

