#!/usr/bin/env bash
# update.sh - Update system, sync this git repo, redeploy dotfiles, and install missing packages
#
# - Upgrades system (pacman)
# - Synchronizes only this repository (fast-forward pull)
# - Rsyncs dotfiles: config/ -> ~/.config/ and .zshrc -> ~/.zshrc
# - Sources package-lists/packages.sh and installs any missing packages (repo via pacman, AUR via yay)
#
# Usage: ./update.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_HELPER="$SCRIPT_DIR/package-lists/packages.sh"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*" >&2; }
err() { printf "[ERROR] %s\n" "$*" >&2; }
die() { err "$*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_sudo() {
  if ! have_cmd sudo; then
    die "sudo is required. Install and configure sudo, then re-run."
  fi
  if ! sudo -n true 2>/dev/null; then
    bold "Elevated privileges are required. You may be prompted by sudo."
    sudo -v
    # Keep sudo alive for script duration
    while true; do sleep 60; sudo -n true; kill -0 "$$" || exit; done 2>/dev/null &
  fi
}

# Source packages helper if present (provides functions packages_base/packages_extra)
if [ -f "$PKG_HELPER" ]; then
  # shellcheck source=/dev/null
  source "$PKG_HELPER"
else
  warn "Package helper not found at $PKG_HELPER. install/update will not read package lists."
fi

# Sync only this repository (fast-forward only)
sync_git_repo() {
  if ! have_cmd git; then
    warn "git not found; skipping repository synchronization"
    return
  fi

  if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "Repository root ($SCRIPT_DIR) is not a git work tree; skipping git sync"
    return
  fi

  info "Fetching remote refs for repository at: $SCRIPT_DIR"
  if ! git -C "$SCRIPT_DIR" fetch --all --prune --quiet; then
    warn "git fetch failed (continuing)"
  fi

  info "Attempting fast-forward pull for current branch"
  if git -C "$SCRIPT_DIR" pull --ff-only --quiet; then
    info "Repository updated (fast-forward)"
  else
    warn "Fast-forward pull failed. You may have local changes or divergent history. Run: git -C \"$SCRIPT_DIR\" status"
  fi
}

# Deploy dotfiles from repo to user home using rsync and direct installs
# Also ensure that .zshconf is deployed (if present) and that ~/.zshrc
# sources it (append-once semantics).
deploy_dotfiles() {
  if ! have_cmd rsync; then
    warn "rsync not found; skipping dotfiles deployment"
    return
  fi

  # Sync config/ to ~/.config/ as before
  local src_config="$SCRIPT_DIR/config"
  if [ -d "$src_config" ]; then
    mkdir -p "$HOME/.config"
    info "Rsyncing config/ -> $HOME/.config/"
    rsync -avh --delete --exclude='.git/' "${src_config}/" "$HOME/.config/"
  else
    warn "No config/ directory at $src_config; skipping config sync"
  fi

  # Install common shell dotfiles from repo root (overwrite with install)
  # This includes .zshrc and .zshconf and other common root dotfiles.
  local dotfiles=( ".zshrc" ".zshconf" ".zprofile" ".zshenv" ".profile" ".bashrc" )
  for f in "${dotfiles[@]}"; do
    local src="$SCRIPT_DIR/$f"
    if [ -f "$src" ]; then
      info "Installing $f -> $HOME/$f"
      install -m 0644 "$src" "$HOME/$f"
    else
      info "No $f at $src; skipping"
    fi
  done

  # If a .zshconf exists in the repo (or already in $HOME), ensure ~/.zshrc sources it.
  local src_zshconf="$SCRIPT_DIR/.zshconf"
  if [ -f "$src_zshconf" ] || [ -f "$HOME/.zshconf" ]; then
    # Ensure ~/.zshrc exists and append the source line only once.
    local zshrc="$HOME/.zshrc"
    local source_line='source $HOME/.zshconf'
    # Check both unquoted and quoted variants to avoid duplicates
    if [ -f "$zshrc" ]; then
      if ! grep -qF "$source_line" "$zshrc" && ! grep -qF 'source "$HOME/.zshconf"' "$zshrc"; then
        info "Appending 'source \$HOME/.zshconf' to $zshrc"
        printf '\n# Source repository zsh configuration\n%s\n' "$source_line" >> "$zshrc"
      else
        info "$zshrc already sources .zshconf; skipping append"
      fi
    else
      info "$zshrc not present; creating and adding source for .zshconf"
      printf '# Created by update.sh\n%s\n' "$source_line" > "$zshrc"
    fi
  fi

  # If the repository contains a 'home/' directory for additional dotfiles,
  # mirror it into the user's $HOME (only dotfiles and directories).
  # This provides a way to ship miscellaneous dotfiles not handled above.
  local src_home="$SCRIPT_DIR/home"
  if [ -d "$src_home" ]; then
    info "Rsyncing home/ -> $HOME/ (dotfiles and directories)"
    # include dotfiles and directories, exclude other files unless desired
    rsync -avh --delete --exclude='.git/' --include='*/' --include='.*' --exclude='*' "${src_home}/" "$HOME/"
  fi
}

# Update Flatpak packages (user then system if sudo available)
update_flatpaks() {
  if ! have_cmd flatpak; then
    warn "flatpak not found; skipping flatpak updates"
    return
  fi

  info "Updating user-installed Flatpak packages"
  # Update user installs (do not require sudo)
  if ! flatpak update --user -y; then
    warn "User flatpak update encountered errors or no user flatpaks present"
  fi

  # Update system-wide flatpaks if sudo is available
  if have_cmd sudo; then
    info "Updating system-wide Flatpak packages (requires sudo)"
    if ! sudo flatpak update --system -y; then
      warn "System flatpak update encountered errors or no system flatpaks present"
    fi
  else
    info "sudo not available; skipping system-wide flatpak updates"
  fi
}

# Read package lists by invoking functions from packages.sh if available.
# Returns newline-separated package names on stdout.
read_package_list_all() {
  if declare -f packages_all >/dev/null 2>&1; then
    packages_all
    return
  fi
  # fallback: concat base then extra if individual functions exist
  if declare -f packages_base >/dev/null 2>&1; then
    packages_base
  fi
  if declare -f packages_extra >/dev/null 2>&1; then
    packages_extra
  fi
}

# Install missing packages from package lists:
# - determine which packages are already installed (pacman -Q)
# - for missing, detect repo availability via pacman -Si
# - install repo packages with pacman, AUR packages with yay (if available)
install_missing_packages() {
  # If pacman is not available, skip package installation entirely.
  if ! have_cmd pacman; then
    warn "pacman not found; skipping package installation step."
    return
  fi

  # Read package list into array
  local all_pkgs=()
  while IFS= read -r pkg; do
    # ignore blanks/comments
    pkg="${pkg%%#*}"
    pkg="$(printf "%s" "$pkg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$pkg" ] && continue
    all_pkgs+=("$pkg")
  done < <(read_package_list_all)

  if [ ${#all_pkgs[@]} -eq 0 ]; then
    info "No packages defined in package helper; skipping package installation"
    return
  fi

  info "Checking installed packages from the package list (this may take a moment)"
  local missing=()
  for pkg in "${all_pkgs[@]}"; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
      continue
    fi
    missing+=("$pkg")
  done

  if [ ${#missing[@]} -eq 0 ]; then
    info "All listed packages are already installed"
    return
  fi

  info "Missing packages detected: ${missing[*]}"

  # Partition missing into repo vs aur
  local repo_missing=()
  local aur_missing=()
  for pkg in "${missing[@]}"; do
    if pacman -Si "$pkg" >/dev/null 2>&1; then
      repo_missing+=("$pkg")
    else
      aur_missing+=("$pkg")
    fi
  done

  # Install repo packages via pacman
  if [ ${#repo_missing[@]} -gt 0 ]; then
    info "Installing repo packages: ${repo_missing[*]}"
    if ! sudo pacman -S --needed --noconfirm "${repo_missing[@]}"; then
      warn "Some repo package installations failed; check pacman output above"
    fi
  fi

  # Install AUR packages via yay if available
  if [ ${#aur_missing[@]} -gt 0 ]; then
    if have_cmd yay; then
      info "Installing AUR packages with yay: ${aur_missing[*]}"
      if ! yay -S --needed --noconfirm "${aur_missing[@]}"; then
        warn "Some AUR package installations failed; check yay output above"
      fi
    else
      warn "The following packages appear to be AUR-only and 'yay' is not installed: ${aur_missing[*]}"
      warn "Install an AUR helper (e.g. yay) and re-run this script to install them."
    fi
  fi
}

main() {
  if have_cmd pacman; then
    require_sudo

    bold "== System upgrade =="
    info "Refreshing package databases and upgrading system (pacman -Syu)"
    sudo pacman -Syu --noconfirm
  else
    warn "pacman not found; skipping system upgrade and pacman-based package installation"
  fi

  bold "== Git repository sync =="
  sync_git_repo

  bold "== Redeploy dotfiles =="
  deploy_dotfiles

  bold "== Update Flatpak packages =="
  update_flatpaks

  bold "== Install missing packages =="
  install_missing_packages

  bold "== Done =="
  info "update.sh completed."
}

main "$@"
