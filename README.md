# dots — installer quick reference

This repository provides a small thin installer (`install.sh`) that clones the repo and runs the real installer (`setup.sh`) contained in the repository. `setup.sh` expects to be run from the repository root and reads package lists from `package-lists/packages.sh`.

This layout keeps the remote one-liner small and auditable while ensuring the full installer has access to repo files like `package-lists/packages.sh`.

## Requirements

- Arch-based system (script checks `/etc/arch-release`)
- `sudo` configured for the invoking user (the scripts call `sudo` for privileged operations)
- Network access (to clone/download the repository)
- `git` or `curl` available on the host (the thin installer uses `git` if present, otherwise downloads a tarball)

## How it works (high level)

- `dots/install.sh` (thin wrapper)
  - clones the repository into a temporary directory (or downloads an archive if `git` is not available),
  - runs `setup.sh` from that clone,
  - prompts whether to keep the cloned repository permanently (default: `~/dots`),
  - removes the temporary clone if the user declines to keep it.
- `dots/setup.sh`
  - is the full installer that expects to be executed from the repo root,
  - sources `package-lists/packages.sh` for package lists and performs package installation, repo setup, dotfiles deployment, etc.

## Quick run (no clone) — recommended one-liner

Use the thin wrapper `install.sh` (this downloads the repo and runs the real installer):

### curl

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/davidbasilefilho/dots/main/install.sh)"
```

### wget

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/davidbasilefilho/dots/main/install.sh)"
```

Those commands run the thin wrapper which obtains the repository contents and executes `setup.sh` from the clone.

## Wrapper flags

The thin `install.sh` supports a few flags (pass them after the one-liner or use the downloaded wrapper):

- `--yes`
  Non-interactive: accept prompts and keep the repository by default in `~/dots` (useful for automation).

- `--keep-dir <path>`
  If you choose to keep the cloned repo, move it to `<path>` (defaults to `~/dots`).

- `--ref <git-ref>`
  Checkout a specific git ref (branch, tag, or commit). Defaults to `main`.

- `--archive-only`
  Use the tarball download fallback even if `git` is available.

Example:

```bash
# non-interactive: clone main, run setup, keep repo at ~/dots
bash -c "$(curl -fsSL https://raw.githubusercontent.com/davidbasilefilho/dots/main/install.sh)" -- --yes
```

Note: the `--` is used in the example to forward options to the downloaded script when invoking via `bash -c "$(curl ...)" -- ...`.

## Running from a clone (safer / recommended for auditing)

If you prefer to inspect first or work from a local clone:

```bash
git clone https://github.com/davidbasilefilho/dots.git ~/dots
cd ~/dots
less setup.sh          # inspect the installer
bash setup.sh          # run the installer from the repo root
```

`setup.sh` expects to find `package-lists/packages.sh` in the cloned repo and will source it to determine which packages to install.

## What `setup.sh` does

- Updates the system (`pacman -Syu`) and installs base packages (or uses lists from `package-lists/packages.sh`)
- Optionally configures CachyOS and Chaotic AUR repos
- Installs `yay` (AUR helper), Oh My Zsh, and requested user packages
- Deploys dotfiles from `config/` -> `~/.config/` and `.zshconf` -> `~/.zshconf` (the installer will append a safe `source ~/.zshconf` snippet to your existing `~/.zshrc` rather than overwriting it)
- Installs `basile.nvim` configuration to `~/.config/nvim` (optional root install)
- Offers to install the CachyOS kernel and will detect NVIDIA GPUs and install the appropriate `linux-cachyos-nvidia*` variant (proprietary/open) based on hardware detection heuristics
- Offers to change login shell to `zsh` for the invoking user and root
- Prompts about rebooting when kernel or other breaking updates are applied

## update.sh

The repository also contains `update.sh`. When run from a clone, `update.sh`:

- updates the system (`pacman -Syu`),
- attempts a fast-forward `git pull` of the local repo,
- redeploys dotfiles,
- installs any missing packages from `package-lists/packages.sh` (`pacman` for repo packages; `yay` for AUR if available).

Run it from a cloned copy:

```bash
cd ~/dots
bash update.sh
```

## Security notes and best practices

- Always review scripts you fetch and run from the network. Prefer the clone-and-inspect workflow for maximum safety.
- The thin wrapper is designed to be minimal: it downloads the repository and executes the bundled `setup.sh`. If you require stronger guarantees, consider:
  - downloading a specific release tarball and verifying a signature, or
  - checking out a pinned commit in a clone before running `setup.sh`.
- Do not run the thin wrapper as `root`; it uses `sudo` internally where needed.

## Troubleshooting

- If the thin installer cannot find `git` and `curl`, it will fail — install one of them and retry.
- If `setup.sh` cannot find `package-lists/packages.sh`, ensure you ran the thin wrapper (which clones the repo) or that you're running `setup.sh` from a clone.
- If you encounter driver/kernel issues after NVIDIA or kernel changes, boot to a previous kernel (via your bootloader) or use the temporary clone that remains for inspection.

## Contributing / Customization

- Edit `package-lists/packages.sh` to adjust package lists. `setup.sh` sources that file when executed from the repo root.
- If you want additional flags (dry-run, verbose, auto-accept granular prompts), open a PR or request features and I can add them.

---

If you want, I can:

- add a short `--dry-run` mode to `setup.sh` that only prints actions without performing them, or
- add GPG verification to the thin wrapper so it verifies a signed tag before running `setup.sh`.

Which would you prefer?
