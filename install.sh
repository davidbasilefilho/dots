#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Install Homebrew
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  echo "Update shell..."
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
else
  echo "Homebrew is already installed."
fi

# Symlink bashrc
echo "Creating symlink for bash config..."
rm -rf ~/.bashrc
ln -sf "$(pwd)/.bashrc" ~/.bashrc

# Update Homebrew
echo "Updating Homebrew..."
brew update

# Install Neovim
if ! command -v nvim &>/dev/null; then
  echo "Installing Neovim..."
  brew install neovim
else
  echo "Neovim is already installed."
fi

# Install Lazygit
if ! command -v lazygit &>/dev/null; then
  echo "Installing Lazygit..."
  brew install lazygit
else
  echo "Lazygit is already installed."
fi

# Install Starship
if ! command -v starship &>/dev/null; then
  echo "Installing Starship..."
  brew install starship
else
  echo "Starship is already installed."
fi

# Install Mise
if ! command -v mise &>/dev/null; then
  echo "Installing Mise..."
  brew install mise
else
  echo "Mise is already installed."
fi

# Install eza
if ! command -v eza &>/dev/null; then
  echo "Installing eza..."
  brew install eza
else
  echo "eza is already installed."
fi

# Install stow
if ! command -v stow &>/dev/null; then
  echo "Installing stow..."
  brew install stow
else
  echo "stow is already installed."
fi

# Install zoxide
if ! command -v zoxide &>/dev/null; then
  echo "Installing zoxide..."
  brew install zoxide
else
  echo "zoxide is already installed."
fi

# Create Neovim config directory and symlink
mkdir -p ~/.config/nvim
if [ ! -L ~/.config/nvim/init.lua ]; then
  echo "Creating symlink for Neovim config..."
  ln -sf "$(pwd)/nvim/init.lua" ~/.config/nvim/init.lua
else
  echo "Neovim config symlink already exists."
fi

# Create Mise config directory and symlink
mkdir -p ~/.config/mise
if [ ! -L ~/.config/mise/config.toml ]; then
  echo "Creating symlink for Mise config..."
  mise trust "$(pwd)/mise"
  ln -sf "$(pwd)/mise/config.toml" ~/.config/mise/config.toml
else
  echo "Mise config symlink already exists."
fi

# Create Lazygit config directory and symlink
mkdir -p ~/.config/lazygit
if [ ! -L ~/.config/lazygit/config.yml ]; then
  echo "Creating symlink for Lazygit config..."
  ln -sf "$(pwd)/lazygit/config.yml" ~/.config/lazygit/config.yml
else
  echo "Lazygit config symlink already exists."
fi

echo "Update shell..."
. ~/.bashrc
set +e

echo "Installation complete!"
