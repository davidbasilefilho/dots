#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Install Homebrew
if ! command -v brew &>/dev/null; then
	echo "Installing Homebrew..."
	/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
	echo "Homebrew is already installed."
fi

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

# Create Neovim config directory and symlink
mkdir -p ~/.config/nvim

if [ ! -L ~/.config/nvim/init.lua ]; then
	echo "Creating symlink for Neovim config..."
	ln -s "$(pwd)/nvim/init.vim" ~/.config/nvim/init.vim
else
	echo "Neovim config symlink already exists."
fi

# Create Mise config directory and symlink
mkdir -p ~/.config/mise
if [ ! -L ~/.config/mise/config.toml ]; then
	echo "Creating symlink for Mise config..."
	ln -s "$(pwd)/mise/config.toml" ~/.config/mise/config.toml
else
	echo "Mise config symlink already exists."
fi

echo "Installation complete!"
