#!/usr/bin/env bash
# dots/install.sh - Thin wrapper installer
# - Clones the repo to a temporary directory (or fetches an archive if git missing)
# - Runs `setup.sh` from the clone
# - Optionally moves the clone to a permanent location (default: ~/dots)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/davidbasilefilho/dots/main/install.sh | bash
#
# Options:
#   --yes               : non-interactive, accept prompts (keep repo by default)
#   --keep-dir <path>   : if provided, use this path as the destination to keep the repo
#   --ref <ref>         : Git ref (branch/tag/commit) to checkout. Default: main
#   --archive-only      : if git is unavailable, always use the tarball fetch fallback
#
# Notes:
# - Do NOT run this wrapper as root. The underlying `setup.sh` will prompt for sudo where needed.
# - The wrapper will try to use `git` first; if not present and curl is available it will fetch
#   a tarball from GitHub and extract it.
# - After a successful run of setup.sh you will be prompted whether to keep the cloned repo.
#   With --yes the repo will be kept at the provided --keep-dir (or ~/dots if not provided).
#
set -Eeuo pipefail

REPO_URL="https://github.com/davidbasilefilho/dots"
GITHUB_RAW="https://raw.githubusercontent.com/davidbasilefilho/dots"
DEFAULT_REF="main"
KEEP_DIR_DEFAULT="$HOME/dots"

# CLI flags
OPT_YES=0
OPT_KEEP_DIR=""
OPT_REF="$DEFAULT_REF"
OPT_ARCHIVE_ONLY=0

print() { printf "%s\n" "$*"; }
bold() { printf "\\033[1m%s\\033[0m\\n" "$*"; }
info() { printf "[INFO] %s\\n" "$*"; }
warn() { printf "[WARN] %s\\n" "$*" >&2; }
err() { printf "[ERROR] %s\\n" "$*" >&2; }

usage() {
  cat <<EOF
Usage: install.sh [--yes] [--keep-dir <path>] [--ref <git-ref>] [--archive-only]

Options:
  --yes               Non-interactive; accept prompts and keep the repo by default.
  --keep-dir <path>   Directory to move the cloned repo to if user chooses to keep it.
  --ref <ref>         Git ref (branch/tag/commit) to check out. Default: ${DEFAULT_REF}
  --archive-only      Use tarball download fallback instead of git (even if git present).
  -h, --help          Show this help and exit.

This script clones the repository, runs 'setup.sh' from the clone, then optionally keeps
or removes the cloned repo. It's designed to be used as a short remote installer.
EOF
}

# Simple prompt helper
ask_yes_no() {
  # ask_yes_no "Question?" default_answer
  # returns 0 for yes, 1 for no
  local prompt default reply
  prompt="$1"
  default="${2:-n}"

  # Non-interactive -> follow default
  if [ ! -t 0 ]; then
    if [ "$default" = "y" ] || [ "$default" = "Y" ]; then
      return 0
    fi
    return 1
  fi

  while true; do
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
      *) printf "Please answer y or n.\\n" ;;
    esac
  done
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) OPT_YES=1; shift ;;
    --keep-dir) OPT_KEEP_DIR="$2"; shift 2 ;;
    --ref) OPT_REF="$2"; shift 2 ;;
    --archive-only) OPT_ARCHIVE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) warn "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [ -z "$OPT_KEEP_DIR" ]; then
  OPT_KEEP_DIR="$KEEP_DIR_DEFAULT"
fi

if [ "$(id -u)" -eq 0 ]; then
  warn "Running this wrapper as root is not recommended. The setup script will use sudo where necessary."
fi

# Make a temporary working directory
WORKDIR="$(mktemp -d -t dots-install-XXXXXX)"
cleanup() {
  # Only remove WORKDIR if it's still present and not the same as the kept dir
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

CLONE_DIR="$WORKDIR/dots"

# Ensure we have at least one method to obtain repo
have_git=0
have_curl=0
if command -v git >/dev/null 2>&1; then
  have_git=1
fi
if command -v curl >/dev/null 2>&1; then
  have_curl=1
fi

fetch_with_git() {
  info "Cloning ${REPO_URL} (ref: ${OPT_REF}) to temporary directory..."
  # Attempt shallow clone of the requested ref. If ref is a commit hash, --depth=1 with --branch may fail;
  # in that case do a normal clone as fallback.
  if git clone --depth 1 --branch "${OPT_REF}" "${REPO_URL}" "$CLONE_DIR" 2>/dev/null; then
    info "Repository cloned (shallow) to $CLONE_DIR"
    return 0
  fi
  info "Shallow clone failed; trying full clone and checkout..."
  if git clone "${REPO_URL}" "$CLONE_DIR"; then
    (
      cd "$CLONE_DIR"
      if git checkout "${OPT_REF}" >/dev/null 2>&1; then
        info "Checked out ${OPT_REF}"
      else
        warn "Could not checkout ${OPT_REF}; repository left on default branch."
      fi
    )
    return 0
  fi
  return 1
}

fetch_with_archive() {
  if [ "$have_curl" -ne 1 ]; then
    return 1
  fi
  info "Downloading repository archive for ref: ${OPT_REF}"
  # GitHub archive URL: https://github.com/<user>/<repo>/archive/<ref>.tar.gz
  ARCHIVE_URL="${REPO_URL}/archive/${OPT_REF}.tar.gz"
  ARCHIVE="$WORKDIR/repo.tar.gz"
  if ! curl -fsSL -o "$ARCHIVE" "$ARCHIVE_URL"; then
    warn "Failed to download archive from $ARCHIVE_URL"
    return 1
  fi
  mkdir -p "$CLONE_DIR"
  tar -xzf "$ARCHIVE" -C "$WORKDIR"
  # The archive extracts to something like dots-<ref> or <repo>-<ref>
  # Find the first directory under WORKDIR that looks like the repo
  extracted="$(find "$WORKDIR" -maxdepth 1 -type d -name "$(basename $REPO_URL)-*" | head -n1 || true)"
  if [ -z "$extracted" ]; then
    # try a more general heuristic
    extracted="$(find "$WORKDIR" -maxdepth 1 -type d ! -name "$(basename $WORKDIR)" | head -n1 || true)"
  fi
  if [ -z "$extracted" ]; then
    warn "Could not locate extracted repository directory"
    return 1
  fi
  mv "$extracted" "$CLONE_DIR"
  info "Repository archive extracted to $CLONE_DIR"
  return 0
}

obtain_repository() {
  if [ "$OPT_ARCHIVE_ONLY" -eq 1 ]; then
    if fetch_with_archive; then
      return 0
    fi
    return 1
  fi

  if [ "$have_git" -eq 1 ]; then
    if fetch_with_git; then
      return 0
    fi
    warn "git clone method failed; attempting archive download fallback..."
  fi

  if [ "$have_curl" -eq 1 ]; then
    if fetch_with_archive; then
      return 0
    fi
    warn "Archive download fallback failed."
  fi

  return 1
}

run_setup() {
  # Ensure setup.sh exists and is executable
  if [ ! -f "$CLONE_DIR/setup.sh" ]; then
    err "setup.sh not found in the cloned repository ($CLONE_DIR/setup.sh). Aborting."
    return 2
  fi

  info "Running setup.sh from the cloned repository. You may be prompted for sudo by that script."
  # Run setup.sh with any args passed to this installer after options.
  # Use bash to ensure a consistent shell.
  (cd "$CLONE_DIR" && bash setup.sh)
  return $?
}

move_repo_to_keepdir() {
  local dest="$1"
  if [ -e "$dest" ]; then
    warn "Destination $dest already exists."
    if [ "$OPT_YES" -eq 1 ]; then
      info "--yes specified; removing existing $dest"
      rm -rf "$dest"
    else
      if ask_yes_no "Destination $dest exists. Overwrite it?" "n"; then
        rm -rf "$dest"
      else
        warn "User declined to overwrite $dest. Aborting move; repository remains at $CLONE_DIR"
        return 1
      fi
    fi
  fi

  mv "$CLONE_DIR" "$dest"
  # Prevent trap cleanup from deleting the moved dir
  trap - EXIT
  info "Repository moved to: $dest"
  return 0
}

main() {
  bold "dots thin installer"
  info "Temporary working directory: $WORKDIR"

  if ! obtain_repository; then
    err "Failed to obtain repository (git clone or archive download). Ensure git or curl is installed and network access is available."
    exit 1
  fi

  # Run the setup script
  if ! run_setup; then
    err "setup.sh failed. The temporary clone remains at: $CLONE_DIR for inspection."
    # Do not delete the clone so user can inspect; but we will not keep it permanently unless asked.
    if [ "$OPT_YES" -eq 1 ]; then
      info "--yes set; keeping repository at $OPT_KEEP_DIR"
      move_repo_to_keepdir "$OPT_KEEP_DIR" || true
    else
      warn "Not moving repository to permanent location. It will be removed on exit unless you set --keep-dir and --yes."
    fi
    exit 2
  fi

  # setup.sh succeeded
  if [ "$OPT_YES" -eq 1 ]; then
    info "--yes specified: keeping repository at $OPT_KEEP_DIR"
    if move_repo_to_keepdir "$OPT_KEEP_DIR"; then
      bold "Installation complete. Repository saved at: $OPT_KEEP_DIR"
      exit 0
    else
      warn "Could not move repository to $OPT_KEEP_DIR; leaving temporary clone for inspection: $CLONE_DIR"
      exit 0
    fi
  fi

  # Interactive: ask user whether to keep the clone
  if ask_yes_no "setup.sh completed successfully. Would you like to keep a copy of the repository at '$OPT_KEEP_DIR' for future use?" "n"; then
    if move_repo_to_keepdir "$OPT_KEEP_DIR"; then
      bold "Repository preserved at: $OPT_KEEP_DIR"
      exit 0
    else
      warn "Failed to move repository to $OPT_KEEP_DIR; leaving temporary clone at $CLONE_DIR"
      exit 0
    fi
  else
    info "Removing temporary clone..."
    # cleanup trap will remove WORKDIR
    exit 0
  fi
}

main "$@"
