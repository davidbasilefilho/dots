#!/usr/bin/env bash
# install.sh - Post-installation script for Arch-based distros
# - Adds CachyOS and Chaotic AUR repositories (optional)
# - Installs base tools, yay, oh-my-zsh, and requested packages
# - Enables services
# - Deploys dotfiles from repo: config/* -> ~/.config, .zshconf -> ~/.zshconf (and appends 'source $HOME/.zshconf' to ~/.zshrc)
# - Optionally offers to install the CachyOS kernel and a matching NVIDIA package
#
# Notes:
# - NVIDIA generation detection is heuristic and uses PCI vendor strings and numeric
#   model extraction to classify GPUs relative to the Turing generation.
# - This script assumes an interactive terminal for prompts.

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

# Source package helper if present (provides functions like packages_base/packages_extra)
if [ -f "$SCRIPT_DIR/package-lists/packages.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/package-lists/packages.sh"
else
  warn "Package helper not found: $SCRIPT_DIR/package-lists/packages.sh"
fi

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
  local user="${2:-}"

  # Treat common truthy indicators ("--user", "true", "user") as a request to
  # enable the unit for the current user without using sudo.
  if [ "$user" = "--user" ] || [ "$user" = "true" ] || [ "$user" = "user" ]; then
    if systemctl --user list-unit-files | grep -q "^${unit}\\b"; then
      info "Enabling and starting ${unit} for the current user"
      systemctl --user enable --now "$unit" || warn "Failed to enable ${unit} (continuing)"
    else
      warn "User systemd unit ${unit} not found; skipping"
    fi
  else
    if systemctl list-unit-files | grep -q "^${unit}\\b"; then
      info "Enabling and starting ${unit}"
      sudo systemctl enable --now "$unit" || warn "Failed to enable ${unit} (continuing)"
    else
      warn "Systemd unit ${unit} not found; skipping"
    fi
  fi
}

append_once() {
  # Append block to file if the block's header (first non-empty line) isn't already present.
  # This variant uses sudo because it is intended for system files (e.g. /etc files).
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

# Non-privileged append helper for user files (appends the block only once)
append_once_user() {
  # append_once_user <file> <content...>
  # Appends content to file if the first non-empty line of content isn't present yet.
  local file="$1"
  shift
  local content="$*"
  local header
  header="$(printf "%s" "$content" | sed -n '/[^[:space:]]/p' | head -n1)"
  if [ -f "$file" ] && grep -qF -- "$header" "$file"; then
    info "Block already present in $file: $header"
  else
    info "Appending block to $file: $header"
    printf "%s\n" "$content" >> "$file"
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

# --------------- shell helpers ---------------

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

# --------------- repository setup functions ---------------

setup_cachyos() {
  bold "Setup: CachyOS repository"
  if sudo grep -qi "^\[cachyos" /etc/pacman.conf 2>/dev/null; then
    info "CachyOS repository already configured; skipping"
    return 0
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

  info "CachyOS setup completed (if no errors reported above)."
}

setup_chaotic_aur() {
  bold "Setup: Chaotic AUR repository"
  if sudo grep -qi "^\[chaotic-aur" /etc/pacman.conf 2>/dev/null; then
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

# --------------- NVIDIA detection (improved) ---------------

# detect_nvidia_generation
# Returns one line "<status>|<model_string>"
# status:
#   - none: no lspci or no NVIDIA detected
#   - newer: newer than Turing (Ampere/Ada/Blackwell/etc.)
#   - turing: Turing generation (e.g. RTX 20xx, GTX 16xx)
#   - older: older than Turing (Pascal/Kepler/...)
#   - unknown: detected NVIDIA but couldn't classify
detect_nvidia_generation() {
  local lspci_line model num_found series_val series_major series_major_num
  if ! have_cmd lspci; then
    echo "none|lspci-missing"
    return
  fi

  # Prefer VGA entries; fall back to 3D controller entries
  lspci_line="$(lspci -nn | grep -i 'vga' | grep -i nvidia || true)"
  if [ -z "$lspci_line" ]; then
    lspci_line="$(lspci -nn | grep -i '3d controller' | grep -i nvidia || true)"
  fi

  if [ -z "$lspci_line" ]; then
    echo "none|no-nvidia-detected"
    return
  fi

  # Extract a cleaned model string (strip vendor prefix and bracketed HEX IDs)
  model="$(printf "%s" "$lspci_line" | sed -E 's/^[^:]+: *//; s/ *\\[.*\\]//g' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  # Numeric detection: look for 3-4 digit sequences (e.g. 4060, 3060, 2080, 1660)
  num_found="$(printf "%s\n" "$model" | grep -oE '[0-9]{3,4}' || true)"
  if [ -n "$num_found" ]; then
    series_val="$(printf "%s\n" "$num_found" | head -n1)"
    # leading two digits, force base-10 conversion to avoid octal interpretation
    series_major="$(printf "%s" "$series_val" | sed -E 's/^([0-9]{2}).*/\\1/')"
    series_major_num=$((10#$series_major))

    # classification by numeric major
    # >=50 : Blackwell / future (newer)
    # >=40 : Ada Lovelace (newer)
    # >=30 : Ampere (newer)
    # 20 or 16 : Turing family
    # <=15 : older (Pascal/Kepler/...)
    if [ "$series_major_num" -ge 50 ] 2>/dev/null; then
      echo "newer|$model"
      return
    elif [ "$series_major_num" -ge 40 ] 2>/dev/null; then
      echo "newer|$model"
      return
    elif [ "$series_major_num" -ge 30 ] 2>/dev/null; then
      echo "newer|$model"
      return
    elif [ "$series_major_num" -eq 20 ] 2>/dev/null || [ "$series_major_num" -eq 16 ] 2>/dev/null; then
      echo "turing|$model"
      return
    elif [ "$series_major_num" -le 15 ] 2>/dev/null; then
      echo "older|$model"
      return
    else
      echo "unknown|$model"
      return
    fi
  fi

  # Textual cues fallback (case-insensitive)
  # Blackwell: 'Blackwell' or code 'GB' (vendor strings may contain GBxyz)
  if printf "%s" "$model" | grep -qiE 'blackwell|\bGB[0-9]+'; then
    echo "newer|$model"
    return
  fi

  # Ada Lovelace: 'AD' prefixes, 'Ada', 'Lovelace'
  if printf "%s" "$model" | grep -qiE '\bAD[0-9A-Z]*\b|ada|lovelace'; then
    echo "newer|$model"
    return
  fi

  # Ampere: 'GA' codes or 'Ampere' or explicit RTX 30-series textual hints
  if printf "%s" "$model" | grep -qiE '\bGA[0-9]+|ampere|rtx[[:space:]]*30|rtx30'; then
    echo "newer|$model"
    return
  fi

  # Turing: 'TU' codes or 'Turing' or RTX 20-series / GTX 16-series hints
  if printf "%s" "$model" | grep -qiE '\bTU[0-9]+|turing|rtx[[:space:]]*20|gtx[[:space:]]*16|gtx16'; then
    echo "turing|$model"
    return
  fi

  # Older: Pascal/Maxwell/Kepler hints
  if printf "%s" "$model" | grep -qiE 'pascal|gtx[[:space:]]*10|kepler|maxwell|gf|gk'; then
    echo "older|$model"
    return
  fi

  echo "unknown|$model"
}

# --------------- CachyOS kernel + NVIDIA install ---------------

install_cachyos_kernel_and_nvidia() {
  bold "CachyOS kernel installation"

  if ! ask_yes_no "Would you like to install the CachyOS kernel package 'linux-cachyos' now?" "n"; then
    info "Skipping CachyOS kernel installation."
    return
  fi

  info "Installing 'linux-cachyos' kernel"
  set +e
  sudo pacman -S --needed --noconfirm linux-cachyos
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    warn "Installation of 'linux-cachyos' exited with code $rc. Check pacman output for details."
    # Continue to detection: user may still want driver without kernel
  else
    info "'linux-cachyos' installed (or already present)."
  fi

  # Detect NVIDIA GPU generation
  local detect model_status model driver_pkg
  detect="$(detect_nvidia_generation || true)"
  model_status="${detect%%|*}"
  model="${detect#*|}"

  if [ "$model_status" = "none" ]; then
    info "No NVIDIA GPU detected ($model). Skipping NVIDIA driver install."
    return
  fi

  if [ "$model_status" = "unknown" ]; then
    warn "Detected NVIDIA device but could not reliably infer generation: $model"
    if ask_yes_no "Install proprietary NVIDIA package 'linux-cachyos-nvidia' (recommended) instead of 'linux-cachyos-nvidia-open'?" "n"; then
      driver_pkg="linux-cachyos-nvidia"
    else
      driver_pkg="linux-cachyos-nvidia-open"
    fi
  elif [ "$model_status" = "turing" ]; then
    info "Detected NVIDIA GPU that appears to be Turing-generation: $model"
    if ask_yes_no "Turing GPUs may work with either driver. Install proprietary 'linux-cachyos-nvidia'?" "y"; then
      driver_pkg="linux-cachyos-nvidia"
    else
      driver_pkg="linux-cachyos-nvidia-open"
    fi
  elif [ "$model_status" = "newer" ]; then
    info "Detected NVIDIA GPU newer than Turing: $model"
    driver_pkg="linux-cachyos-nvidia"
  elif [ "$model_status" = "older" ]; then
    info "Detected NVIDIA GPU older than Turing: $model"
    driver_pkg="linux-cachyos-nvidia-open"
  else
    driver_pkg="linux-cachyos-nvidia"
  fi

  bold "Installing NVIDIA driver package: $driver_pkg"
  set +e
  sudo pacman -S --needed --noconfirm "$driver_pkg"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    warn "Installation of '$driver_pkg' exited with code $rc. Inspect pacman output."
  else
    info "NVIDIA driver package '$driver_pkg' installed (or already present)."
  fi

  # Offer lib32 driver for 32-bit compatibility if available in repos
  local lib32_pkg="lib32-${driver_pkg#linux-cachyos-}"
  if pacman -Si "$lib32_pkg" >/dev/null 2>&1; then
    if ask_yes_no "Install corresponding lib32 package '$lib32_pkg' for 32-bit compatibility?" "n"; then
      set +e
      sudo pacman -S --needed --noconfirm "$lib32_pkg"
      rc=$?
      set -e
      if [ $rc -ne 0 ]; then
        warn "Installation of '$lib32_pkg' failed (rc=$rc)."
      else
        info "Installed '$lib32_pkg'."
      fi
    fi
  fi

  info "CachyOS kernel + NVIDIA driver installation step complete. Pacman hooks should handle initramfs updates; you may still need to reboot."
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
    sudo mkdir -p /root/.config
    sudo rm -rf /root/.config/nvim
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
  info "Refreshing package databases and updating system"
  sudo pacman -Syu --noconfirm

  # Load base package list from package helper if available
  local base_pkgs=()
  if declare -f packages_base >/dev/null 2>&1; then
    mapfile -t base_pkgs < <(packages_base)
  else
    base_pkgs=(neovim ripgrep fd fzf zsh curl rsync reflector)
    warn "packages_base() not found; falling back to embedded list."
  fi

  info "Installing base packages: ${base_pkgs[*]}"
  sudo pacman -S --needed --noconfirm "${base_pkgs[@]}"

  enable_service "reflector.service"
  enable_service "reflector.timer"
}

step_2_setup_repos() {
  bold "Step 2: Configure optional repositories (CachyOS / Chaotic AUR)"
  if ask_yes_no "Would you like to add/configure the CachyOS repository (optional)?" "n"; then
    setup_cachyos
  else
    info "Skipping CachyOS setup."
  fi

  if ask_yes_no "Would you like to add/configure the Chaotic AUR repository (optional)?" "n"; then
    setup_chaotic_aur
  else
    info "Skipping Chaotic AUR setup."
  fi
}

step_3_install_yay() {
  bold "Step 3: Install yay (AUR helper)"
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

step_4_install_oh_my_zsh() {
  bold "Step 4: Install Oh My Zsh"
  if [ -d "$HOME/.oh-my-zsh" ]; then
    info "Oh My Zsh already present; skipping installation"
    return
  fi

  info "Running Oh My Zsh installer (non-interactive)"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
}

step_5_install_packages() {
  bold "Step 5: Install requested packages via yay"
  if ! have_cmd yay; then
    die "yay not found; Step 3 should have installed it."
  fi

  local pkgs=()
  if declare -f packages_extra >/dev/null 2>&1; then
    mapfile -t pkgs < <(packages_extra)
  else
    pkgs=(zsh-syntax-highlighting zsh-autosuggestions zsh-completions mise zoxide starship eza github-cli vim unzip zed opencode-bin ttf-jetbrains-mono-nerd ttf-zed-mono-nerd otf-geist-mono-nerd stremio re2c gd pipes-rs pfetch-rs-bin ghostty brave-bin flatpak fastfetch easyeffects lsp-plugins-lv2 lsp-plugins-vst3 zam-plugins-lv2 mda.lv2 cachyos-hello cachyos-settings cairo calf docker pango lib32-pango lazygit lazydocker ladspa gemini-cli jre21-openjdk-headless fmt cachyos-gaming-meta bpftune-git brave-bin btop ardour ananicy-cpp adwaita-fonts openai-codex)
    warn "packages_extra() not found; falling back to embedded list."
  fi

  info "Installing packages: ${pkgs[*]}"
  yay -S --needed --noconfirm "${pkgs[@]}"

  enable_service "docker.service"
  enable_service "opentabletdriver.service" "--user"
}

step_6_deploy_dotfiles() {
  bold "Step 6: Deploy dotfiles"

  local src_config="${SCRIPT_DIR}/config"
  if [ -d "$src_config" ]; then
    mkdir -p "$HOME/.config"
    info "Syncing ${src_config}/ -> $HOME/.config/"
    rsync -avh "${src_config}/" "$HOME/.config/"
  else
    warn "No config directory found at ${src_config}; skipping"
  fi

  local src_zshconf="${SCRIPT_DIR}/.zshconf"
  if [ -f "$src_zshconf" ]; then
    info "Installing ${src_zshconf} -> $HOME/.zshconf"
    install -m 0644 "$src_zshconf" "$HOME/.zshconf"

    # Ensure the user's ~/.zshrc sources the repo-provided ~/.zshconf
    # Append only if the source line is not already present.
    if [ -f "$HOME/.zshrc" ]; then
      if ! grep -qF "source \$HOME/.zshconf" "$HOME/.zshrc" 2>/dev/null; then
        info "Appending 'source \$HOME/.zshconf' to \$HOME/.zshrc"
        printf "%s\n" "source \$HOME/.zshconf" >> "$HOME/.zshrc"
      else
        info "\$HOME/.zshrc already sources \$HOME/.zshconf"
      fi
    else
      # If no ~/.zshrc exists, create one that sources the conf file
      info "No existing ~/.zshrc found; creating one that sources ~/.zshconf"
      printf "%s\n" "source \$HOME/.zshconf" > "$HOME/.zshrc"
      install -m 0644 "$HOME/.zshrc" "$HOME/.zshrc" >/dev/null 2>&1 || true
    fi

    # RSYNC helper aliases are provided by the scripts themselves (e.g. update.sh).
    # Do not append rsync helper functions into user files from the installer.
  else
    warn "No .zshconf found at ${src_zshconf}; skipping"
  fi
}

# Install selected Flatpak applications (called from main)
step_7_install_flatpaks() {
  bold "Step 7: Install Flatpak applications"

  if ! have_cmd flatpak; then
    warn "flatpak not found; skipping Flatpak application installation"
    return
  fi

  # Ensure Flathub remote exists
  if ! flatpak remote-list | grep -q '^flathub\b' 2>/dev/null; then
    info "Adding Flathub remote"
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || warn "Failed to add Flathub remote (continuing)"
  fi

  # Install Bottles (try common Flathub ID first, fallback to literal 'bottles' request)
  info "Installing Bottles (Flatpak)"
  if ! flatpak install -y flathub com.usebottles.bottles 2>/dev/null; then
    # Fallback to literal command requested
    if ! flatpak install -y bottles 2>/dev/null; then
      warn "Failed to install 'bottles' via Flatpak"
    fi
  fi

  # Install Sober (as requested)
  info "Installing Sober (Flatpak: org.vinegarhq.Sober)"
  if ! flatpak install -y flathub org.vinegarhq.Sober 2>/dev/null; then
    warn "Failed to install org.vinegarhq.Sober via Flatpak"
  fi
}

# --------------- main ---------------

main() {
  require_arch
  require_sudo

  step_1_system_update_and_base_tools
  step_2_setup_repos
  step_3_install_yay
  step_4_install_oh_my_zsh
  step_5_install_packages
  step_6_deploy_dotfiles

  # Install flatpak apps requested by the repository/setup
  step_7_install_flatpaks

  install_basile_nvim

  change_shells_to_zsh

  # Before reboot: offer to install CachyOS kernel (and possibly NVIDIA driver)
  install_cachyos_kernel_and_nvidia

  if ask_yes_no "Would you like to reboot now to apply breaking changes (kernel updates, shell changes, etc.)?" "n"; then
    bold "Rebooting now..."
    sudo reboot
  else
    bold "All done! Consider restarting your session or rebooting later for all changes to take effect."
  fi
}

main "$@"
