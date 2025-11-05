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
  # User asked for 'reflectors.timer' (typo); try it as well just in case
  enable_service "reflectors.timer"
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

  info "Syncing package databases"
  sudo pacman -Sy --noconfirm
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
    mise zoxide starship eza github-cli vim unzip
    ttf-jetbrains-mono-nerd ttf-zed-mono-nerd otf-geist-mono-nerd
    stremio re2c gd pipes-rs pfetch-rs-bin ghostty
    flatpak fastfetch easyeffects lsp-plugins-lv2 lsp-plugins-vst3
    zam-plugins-lv2 mda.lv2 cachyos-hello cachyos-settings cairo calf
    docker pango lib32-pango lazygit lazydocker ladspa
    jre21-openjdk-headless fmt cachyos-gaming-meta bpftune-git brave-bin
    btop ardour ananicy-cpp adwaita-fonts
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

  bold "All done! Consider restarting your session for shell and group changes to take effect."
}

main "$@"
