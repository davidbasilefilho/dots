# install.sh — quick reference

## Requirements

- Arch-based system (checks `/etc/arch-release`)
- `sudo` configured for your user
- Network access

## Run (no clone)

### curl

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/davidbasilefilho/dots/refs/heads/main/install.sh)"
```

### wget

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/davidbasilefilho/dots/refs/heads/main/install.sh)"
```

## Safer: download and inspect first

```bash
curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/davidbasilefilho/dots/refs/heads/main/install.sh
less /tmp/install.sh
bash /tmp/install.sh
```

## Overview

- Updates system and installs base tools (neovim, zsh, git, rsync, etc.)
- Adds CachyOS and Chaotic AUR repos (if missing)
- Installs `yay`, Oh My Zsh, requested packages
- Deploys repo dotfiles to `~/.config/` and `~/.zshrc` (if present)
- Clones `basile.nvim` to `~/.config/nvim` (removes existing dir) and optionally to `/root/.config/nvim`
- Offers to change login shell for the invoking user (prefers `SUDO_USER`) and root to `zsh`
- Prompts to replace foreign (AUR) packages with repo binaries and to prefer CachyOS builds
- Offers an optional reboot at the end

## Behavior notes

- Prompts default to "no" in non-interactive runs (script won't block if no TTY)
- `basile.nvim` install removes `~/.config/nvim`; root install removes `/root/.config/nvim` when confirmed
- Review the script before running remote installs (`curl | bash` has inherent risk)

If you want a short flag to auto-accept prompts (e.g. `--yes`) or an explicit skip for `basile.nvim`, tell me and I’ll add it.
