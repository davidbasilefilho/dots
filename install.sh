#!/usr/bin/env bash
# install.sh - Post-installation script for Arch-based distros
# - Adds CachyOS and Chaotic AUR repositories
# - Installs base tools, yay, oh-my-zsh, and requested packages
# - Enables services
# - Deploys dotfiles from repo: config/* -> ~/.config, .zshrc -> ~/.zshrc

set -Eeuo pipefail

# --------------- utilities ---------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d -t arch-postinstall-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*" >&2; }
err() { printf "[ERROR] %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_arch() {
  if ! [ -f /etc/arch-release ]; then
    die "This script targets Arch-based distros only."
  fi
}

require_sudo() {
  if ! have_cmd sudo; then
    die "sudo is required. Install and configure sudo, then re-run."
  fi
  if ! sudo -n true 2>/dev/null; then
    bold "Elevated privileges are required. You may be prompted by sudo."
    sudo -v
    # Keep-alive: update existing sudo time stamp until script ends.
    while true; do sleep 60; sudo -n true; kill -0 "$$" || exit; done 2>/dev/null &
  fi
}

enable_service() {
  local unit="$1"
  if systemctl list-unit-files | grep -q "^${unit}\b"; then
    info "Enabling and starting ${unit}"
    sudo systemctl enable --now "$unit" || warn "Failed to enable ${unit} (continuing)"
  else
    warn "Systemd unit ${unit} not found; skipping"
  fi
}

append_once() {
  # Append block to file if the block's header (first non-empty line) isn't already present.
  local file="$1"
  shift
  local content="$*"
  local header
  header="$(printf "%s" "$content" | sed -n '/[^[:space:]]/p' | head -n1)"
  if sudo test -f "$file" && sudo grep -qF "$header" "$file"; then
    info "Block already present in $file: $header"
  else
    info "Appending block to $file: $header"
    printf "%s\n" "$content" | sudo tee -a "$file" >/dev/null
  fi
}

ask_yes_no() {
  # ask_yes_no "Question?" default_answer
  # returns 0 for yes, 1 for no
  local prompt default reply
  prompt="$1"
  default="${2:-n}"

  # If stdin is not a terminal, treat as "no" to avoid blocking in non-interactive runs
  if [ ! -t 0 ]; then
    info "Non-interactive shell detected; answering 'no' to: $prompt"
    return 1
  fi

  while true; do
    # Show default in prompt
    if [ "$default" = "y" ] || [ "$default" = "Y" ]; then
      read -r -p "$prompt [Y/n]: " reply || return 1
      reply="${reply:-y}"
    else
      read -r -p "$prompt [y/N]: " reply || return 1
      reply="${reply:-n}"
    fi

    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# --------------- shell / replacement functions ---------------

change_shells_to_zsh() {
  bold "Changing default shells to zsh"

  local zsh_path invoking_user
  # Prefer an explicit zsh path if available
  if have_cmd zsh; then
    zsh_path="$(command -v zsh)"
  else
    zsh_path="/usr/bin/zsh"
  fi

  if [ ! -x "$zsh_path" ]; then
    warn "zsh not found at $zsh_path. Skipping shell changes."
    return
  fi

  # Ensure path is listed in /etc/shells
  if ! sudo grep -qFx "$zsh_path" /etc/shells 2>/dev/null; then
    info "Adding $zsh_path to /etc/shells"
    printf "%s\n" "$zsh_path" | sudo tee -a /etc/shells >/dev/null
  fi

  # If the script was invoked with sudo, prefer SUDO_USER as the "real" user
  invoking_user="${SUDO_USER:-${USER:-}}"
  if [ -z "$invoking_user" ]; then
    warn "Could not determine non-root user to change shell for; skipping user shell change."
  else
    info "Setting shell for user '$invoking_user' to $zsh_path"
    if sudo chsh -s "$zsh_path" "$invoking_user"; then
      info "User shell changed for $invoking_user"
    else
      warn "Failed to change shell for $invoking_user (you may need to run chsh manually)"
    fi
  fi

  info "Setting shell for root to $zsh_path"
  if sudo chsh -s "$zsh_path" root; then
    info "Root shell changed to $zsh_path"
  else
    warn "Failed to change root shell (you may need to update /etc/passwd manually)"
  fi

  bold "Shell changes complete. Note: you may need to log out and back in for changes to take effect."
}

replace_foreign_with_repo_bins() {
  # Attempt to replace "foreign" (AUR/locally-built) packages with repository-provided packages
  bold "Option: replace foreign (AUR) packages with repo binaries (e.g. Chaotic if available)"

  # Gather foreign packages (those not found in sync DBs)
  local foreign
  foreign="$(pacman -Qmq || true)"
  if [ -z "$foreign" ]; then
    info "No foreign packages detected (pacman -Qm returned nothing)."
    return
  fi

  info "Foreign packages detected:"
  printf "  %s\n" $foreign

  if ask_yes_no "Attempt to reinstall/replace these packages from repos if available?" "n"; then
    info "Attempting to install/replace foreign packages from repos (if available)."
    # Allow pacman to fail on packages that are not in any repo; don't let the script exit due to set -e
    set +e
    sudo pacman -S --needed --noconfirm $foreign
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      warn "Some foreign packages could not be installed from repos. Check pacman output above for details."
    else
      info "Attempted replacement of foreign packages completed."
    fi
  else
    info "Skipping replacement of foreign packages."
  fi
}

replace_installed_with_cachyos() {
  # If cachyos repo exists, optionally reinstall packages present in cachyos to prefer their builds
  if ! sudo grep -qi "^\[cachyos" /etc/pacman.conf 2>/dev/null; then
    info "CachyOS repo not configured; skipping CachyOS replacements."
    return
  fi

  bold "Option: prefer CachyOS versions of packages when available"

  # Build lists to compute intersection of installed packages and what's available in cachyos
  local installed_file cachy_file intersect_file packages_to_replace

  installed_file="$WORKDIR/installed.txt"
  cachy_file="$WORKDIR/cachy.txt"
  intersect_file="$WORKDIR/intersect.txt"

  pacman -Qq | sort > "$installed_file"
  # pacman -Sl may require sudo for some setups; run it and ignore errors
  sudo pacman -Sl cachyos 2>/dev/null | awk '{print $2}' | sort > "$cachy_file" || true

  if [ ! -s "$cachy_file" ]; then
    warn "No packages listed in CachyOS mirror index or unable to query cachyos repo; skipping."
    return
  fi

  comm -12 "$installed_file" "$cachy_file" > "$intersect_file" || true

  if [ ! -s "$intersect_file" ]; then
    info "No installed packages are available in the CachyOS repo (intersection empty)."
    return
  fi

  packages_to_replace="$(tr '\n' ' ' < "$intersect_file" | sed -e 's/[[:space:]]*$//')"
  info "Packages that could be replaced with CachyOS builds:"
  printf "  %s\n" $(cat "$intersect_file")

  if ask_yes_no "Reinstall the above packages to prefer CachyOS builds? This may replace your current packages." "n"; then
    info "Reinstalling packages from CachyOS where available."
    set +e
    # Use pacman to reinstall; packages present in cachyos will be taken from that repo according to pacman order
    sudo pacman -S --needed --noconfirm $packages_to_replace
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      warn "Some CachyOS replacements failed; inspect pacman output for details."
    else
      info "CachyOS replacements attempted."
    fi
  else
    info "Skipping CachyOS replacements."
  fi
}

# --------------- basile.nvim install function ---------------

install_basile_nvim() {
  bold "Installing basile.nvim configuration for Neovim"

  local repo_url="https://github.com/davidbasilefilho/basile.nvim.git"
  local user_dest="$HOME/.config/nvim"

  if ! have_cmd git; then
    warn "git not found. Installing basile.nvim requires git. Skipping basile.nvim installation."
    return
  fi

  # Remove existing user nvim config and clone
  if [ -d "$user_dest" ]; then
    info "Removing existing $user_dest"
    rm -rf "$user_dest"
  fi

  info "Cloning $repo_url -> $user_dest"
  if git clone --depth 1 "$repo_url" "$user_dest"; then
    info "Successfully cloned basile.nvim to $user_dest"
  else
    warn "Failed to clone basile.nvim to $user_dest"
  fi

  # Optionally install for root
  if ask_yes_no "Would you like to apply the same basile.nvim config to root (/root/.config/nvim) as well?" "n"; then
    info "Installing basile.nvim for root"
    # Ensure parent directory exists, remove previous config, and clone as root
    sudo mkdir -p /root/.config
    sudo rm -rf /root/.config/nvim
    # Use sudo git clone to ensure ownership and permissions are correct for root
    if sudo git clone --depth 1 "$repo_url" /root/.config/nvim; then
      info "Successfully cloned basile.nvim to /root/.config/nvim"
    else
      warn "Failed to clone basile.nvim for root"
    fi
  else
    info "Skipping root neovim config install"
  fi
}

# --------------- steps ---------------

step_1_system_update_and_base_tools() {
  bold "Step 1: Update system and install base tools"
  # Base tools per request
  local base_pkgs=(neovim ripgrep fd fzf zsh curl rsync reflector)
  info "Refreshing package databases and updating system"
  sudo pacman -Syu --noconfirm

  info "Installing base packages: ${base_pkgs[*]}"
  sudo pacman -S --needed --noconfirm "${base_pkgs[@]}"

  # Enable reflector units (try common variants)
  enable_service "reflector.service"
  enable_service "reflector.timer"
}

step_2_add_cachyos_repo() {
  bold "Step 2: Add CachyOS repository"
  if sudo grep -qi "^\[cachyos" /etc/pacman.conf; then
    info "CachyOS repository already configured; skipping"
    return
  fi

  info "Downloading CachyOS repo helper"
  (
    cd "$WORKDIR"
    curl -fsSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
    tar xvf cachyos-repo.tar.xz >/dev/null
    cd cachyos-repo
    info "Running cachyos-repo.sh"
    sudo ./cachyos-repo.sh
  )
}

step_3_add_chaotic_aur_repo() {
  bold "Step 3: Add Chaotic AUR repository"
  if sudo grep -qi "^\[chaotic-aur" /etc/pacman.conf; then
    info "Chaotic AUR already configured; ensuring keyring and mirrorlist are installed"
  else
    info "Importing Chaotic AUR keys"
    sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
    sudo pacman-key --lsign-key 3056513887B78AEB

    info "Installing chaotic-aur keyring and mirrorlist"
    sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
    sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

    append_once /etc/pacman.conf "
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
"
  fi

  info "Syncing package databases and upgrading system (will take a while)"
  sudo pacman -Syu --noconfirm
}

step_4_install_yay() {
  bold "Step 4: Install yay (AUR helper)"
  if have_cmd yay; then
    info "yay already installed; skipping"
    return
  fi

  info "Installing prerequisites for building AUR packages"
  sudo pacman -S --needed --noconfirm git base-devel

  info "Cloning yay-bin and building"
  (
    cd "$WORKDIR"
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm
  )
}

step_5_install_oh_my_zsh() {
  bold "Step 5: Install Oh My Zsh"
  if [ -d "$HOME/.oh-my-zsh" ]; then
    info "Oh My Zsh already present; skipping installation"
    return
  fi

  # Run non-interactively to avoid shell changing mid-script
  info "Running Oh My Zsh installer (non-interactive)"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
}

step_6_install_packages() {
  bold "Step 6: Install requested packages via yay"
  if ! have_cmd yay; then
    die "yay not found; Step 4 should have installed it."
  fi

  # Packages requested by the user
  local pkgs=(
    zsh-syntax-highlighting zsh-autosuggestions zsh-completions
    mise zoxide starship eza github-cli vim unzip zed opencode-bin
    ttf-jetbrains-mono-nerd ttf-zed-mono-nerd otf-geist-mono-nerd
    stremio re2c gd pipes-rs pfetch-rs-bin ghostty brave-bin
    flatpak fastfetch easyeffects lsp-plugins-lv2 lsp-plugins-vst3
    zam-plugins-lv2 mda.lv2 cachyos-hello cachyos-settings cairo calf
    docker pango lib32-pango lazygit lazydocker ladspa gemini-cli
    jre21-openjdk-headless fmt cachyos-gaming-meta bpftune-git brave-bin
    btop ardour ananicy-cpp adwaita-fonts openai-codex
  )

  info "Installing packages: ${pkgs[*]}"
  yay -S --needed --noconfirm "${pkgs[@]}"

  # Enable docker service as requested
  enable_service "docker.service"
}

step_7_deploy_dotfiles() {
  bold "Step 7: Deploy dotfiles"

  # Copy everything inside config -> ~/.config
  local src_config="${SCRIPT_DIR}/config"
  if [ -d "$src_config" ]; then
    mkdir -p "$HOME/.config"
    info "Syncing ${src_config}/ -> $HOME/.config/"
    # Ensure rsync is installed from Step 1
    rsync -avh "${src_config}/" "$HOME/.config/"
  else
    warn "No config directory found at ${src_config}; skipping"
  fi

  # Copy .zshrc -> ~/.zshrc
  local src_zshrc="${SCRIPT_DIR}/.zshrc"
  if [ -f "$src_zshrc" ]; then
    info "Installing ${src_zshrc} -> $HOME/.zshrc"
    install -m 0644 "$src_zshrc" "$HOME/.zshrc"
  else
    warn "No .zshrc found at ${src_zshrc}; skipping"
  fi
}

# --------------- main ---------------

main() {
  require_arch
  require_sudo

  step_1_system_update_and_base_tools
  step_2_add_cachyos_repo
  step_3_add_chaotic_aur_repo
  step_4_install_yay
  step_5_install_oh_my_zsh
  step_6_install_packages
  step_7_deploy_dotfiles

  # After deploying dotfiles, install basile.nvim for the user and optionally root
  install_basile_nvim

  # After basile.nvim, change shells to zsh for root and the invoking user
  change_shells_to_zsh

  # Ask user about replacing foreign packages with repo-provided binaries (Chaotic)
  if ask_yes_no "Would you like to attempt to replace foreign (AUR/local) packages with repository-provided binaries (e.g. from Chaotic) where available?" "n"; then
    replace_foreign_with_repo_bins
  else
    info "Skipping replacement of foreign packages."
  fi

  # Ask about preferring CachyOS builds (if repo present)
  if ask_yes_no "Would you like to attempt to reinstall installed packages available from CachyOS to prefer CachyOS builds? This may replace existing packages." "n"; then
    replace_installed_with_cachyos
  else
    info "Skipping CachyOS preference step."
  fi

  # Ask about reboot
  if ask_yes_no "Would you like to reboot now to apply breaking changes (kernel updates, shell changes, etc.)?" "n"; then
    bold "Rebooting now..."
    sudo reboot
  else
    bold "All done! Consider restarting your session or rebooting later for all changes to take effect."
  fi
}

main "$@"
