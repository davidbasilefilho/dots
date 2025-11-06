#!/usr/bin/env bash
# packages.sh - package helper script providing two functions that return package lists
#
# This file is meant to be sourced by other scripts (e.g. install.sh, update.sh).
# It exposes:
#   - packages_base    : prints the base (core) package list, one package per line
#   - packages_extra   : prints the larger/extra package list, one package per line
#
# Example usage:
#   # source this file
#   source /path/to/package-lists/packages.sh
#
#   # read into arrays
#   mapfile -t BASE_PACKAGES  < <(packages_base)
#   mapfile -t EXTRA_PACKAGES < <(packages_extra)
#
#   # install with pacman (example)
#   sudo pacman -S --needed --noconfirm "${BASE_PACKAGES[@]}"
#   # install extras (AUR helper may be required for some)
#   sudo pacman -S --needed --noconfirm "${EXTRA_PACKAGES[@]}"
#
# Notes:
# - Functions output one package name per line (safe for mapfile/readarray usage).
# - Keep the package names here canonical for your distro's package manager.
# - Edit this file to add/remove packages; other scripts just source it.

# Print the base/core packages (one per line)
packages_base() {
  cat <<'PKG'
neovim
ripgrep
fd
fzf
zsh
curl
rsync
reflector
git
base-devel
PKG
}

# Print the larger/extra package list (one per line)
packages_extra() {
  cat <<'PKG'
zsh-syntax-highlighting
zsh-autosuggestions
zsh-completions
mise
zoxide
starship
eza
github-cli
vim
unzip
zed
opencode-bin
ttf-jetbrains-mono-nerd
ttf-zed-mono-nerd
otf-geist-mono-nerd
stremio
re2c
gd
pipes-rs
pfetch-rs-bin
ghostty
brave-bin
flatpak
fastfetch
easyeffects
lsp-plugins-lv2
lsp-plugins-vst3
zam-plugins-lv2
mda.lv2
cachyos-hello
cachyos-settings
cairo
calf
docker
pango
lib32-pango
lazygit
lazydocker
ladspa
gemini-cli
jre21-openjdk-headless
fmt
cachyos-gaming-meta
bpftune-git
btop
ardour
ananicy-cpp
adwaita-fonts
openai-codex
PKG
}

# Convenience: print all packages (base then extra)
packages_all() {
  packages_base
  packages_extra
}

# Helper: return packages as a bash array variable (useful for direct assignment)
# Example:
#   source packages.sh
#   eval "$(packages_base_array BASE_PACKS)"
#   # now $BASE_PACKS is a bash array variable
packages_base_array() {
  local varname="${1:-BASE_PACKS}"
  printf '%s=(\n' "$varname"
  packages_base | sed -e "s/^/  '/" -e "s/$/'/"
  printf ')\n'
}

packages_extra_array() {
  local varname="${1:-EXTRA_PACKS}"
  printf '%s=(\n' "$varname"
  packages_extra | sed -e "s/^/  '/" -e "s/$/'/"
  printf ')\n'
}

# If executed directly, show a short help/preview
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is intended to be sourced. Available functions:"
  echo "  packages_base    - prints base package names (one per line)"
  echo "  packages_extra   - prints extra package names (one per line)"
  echo "  packages_all     - prints both lists"
  echo
  echo "Preview (base packages):"
  packages_base
  echo
  echo "Preview (extra packages):"
  packages_extra
fi
