#!/bin/bash
# Install (or update) offload on this Mac. Safe to re-run.
#
# Without cloning:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/offload/main/install.sh)"
# From a clone:
#   ./install.sh          interactive
#   ./install.sh --yes    accept every prompt (installs missing apps too)

set -o pipefail

# Where to download from when run via curl. Override with OFFLOAD_REPO / OFFLOAD_REF.
OFFLOAD_REPO="${OFFLOAD_REPO:-YOUR_GITHUB_USER/offload}"
OFFLOAD_REF="${OFFLOAD_REF:-main}"
OFFLOAD_HOME="${OFFLOAD_HOME:-$HOME/.local/share/offload}"

ROOT=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

# ---------------------------------------------------------------- bootstrap
# Run via curl (no repo next to this script): download a snapshot of the repo
# into $OFFLOAD_HOME and re-run the installer from there. No git needed.
if [ -z "$ROOT" ] || [ ! -r "$ROOT/lib/common.sh" ]; then
  if [ -d "$OFFLOAD_HOME/.git" ]; then
    echo "error: $OFFLOAD_HOME is a git clone — update it with 'git pull' and run ./install.sh there" >&2
    exit 1
  fi
  url="https://github.com/$OFFLOAD_REPO/archive/refs/heads/$OFFLOAD_REF.tar.gz"
  echo "Downloading offload from $OFFLOAD_REPO ($OFFLOAD_REF)…"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/offload.XXXXXX") || exit 1
  if ! curl -fsSL "$url" | tar -xz -C "$tmp" --strip-components 1; then
    echo "error: couldn't download $url (private repo? wrong OFFLOAD_REPO?)" >&2
    rm -rf "$tmp"; exit 1
  fi
  printf '%s %s\n' "$OFFLOAD_REPO" "$OFFLOAD_REF" > "$tmp/.source"
  mkdir -p "$(dirname "$OFFLOAD_HOME")"
  rm -rf "$OFFLOAD_HOME.old"
  [ -d "$OFFLOAD_HOME" ] && mv "$OFFLOAD_HOME" "$OFFLOAD_HOME.old"
  mv "$tmp" "$OFFLOAD_HOME" || exit 1
  rm -rf "$OFFLOAD_HOME.old"
  chmod +x "$OFFLOAD_HOME/install.sh" "$OFFLOAD_HOME/bin/offload"
  exec /bin/bash "$OFFLOAD_HOME/install.sh" "$@"
fi

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

for a in "$@"; do case "$a" in -y|--yes) OFFLOAD_YES=1 ;; esac; done

[ "$(uname -s)" = Darwin ] || die "offload is for macOS"

BIN_DIR="$HOME/.local/bin"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
RC_MARKER="# offload shell integration"

# brew_cask <name...> — try each cask name in turn (Homebrew renames casks now and then).
brew_cask() {
  local c
  for c in "$@"; do brew install --cask "$c" && return 0; done
  return 1
}

say "${_c_bld}Installing offload from $ROOT${_c_off}"

# 1. Prerequisites ------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew isn't installed; it's used to install Tailscale and Docker Desktop."
  if confirm "Install Homebrew now?" y; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || die "Homebrew install failed"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
  fi
fi

if command -v tailscale >/dev/null 2>&1 || [ -d /Applications/Tailscale.app ]; then
  ok "Tailscale installed"
elif command -v brew >/dev/null 2>&1 && confirm "Tailscale isn't installed. Install it with Homebrew?" y; then
  brew_cask tailscale-app tailscale && ok "Tailscale installed — open it and sign in (same account on both Macs)"
else
  warn "install Tailscale from https://tailscale.com/download/mac and sign in on both Macs"
fi

if command -v docker >/dev/null 2>&1 || [ -d /Applications/Docker.app ]; then
  ok "Docker Desktop installed"
elif command -v brew >/dev/null 2>&1 && confirm "Docker Desktop isn't installed. Install it with Homebrew?" y; then
  brew_cask docker-desktop docker && ok "Docker Desktop installed — open it once to finish setup"
else
  warn "install Docker Desktop from https://www.docker.com/products/docker-desktop/"
fi

# 2. The command ------------------------------------------------------------------
mkdir -p "$BIN_DIR"
chmod +x "$ROOT/bin/offload"
ln -sf "$ROOT/bin/offload" "$BIN_DIR/offload"
ok "linked $BIN_DIR/offload"

# 3. Config ----------------------------------------------------------------------
if [ -f "$OFFLOAD_CONFIG" ]; then
  ok "config exists: $OFFLOAD_CONFIG"
else
  mkdir -p "$OFFLOAD_CONFIG_DIR"
  sed "s/^ssh_user *= *\"[^\"]*\"/ssh_user   = \"$USER\"/" "$ROOT/config.example.toml" > "$OFFLOAD_CONFIG"
  ok "wrote $OFFLOAD_CONFIG — check the machine names match your Tailscale names"
fi

# 4. Shell integration ---------------------------------------------------------------
if grep -qF "$RC_MARKER" "$ZSHRC" 2>/dev/null; then
  ok "~/.zshrc already sources offload"
else
  {
    echo ""
    echo "$RC_MARKER"
    echo "case \":\$PATH:\" in *\":$BIN_DIR:\"*) ;; *) export PATH=\"$BIN_DIR:\$PATH\" ;; esac"
    echo "[ -r \"$ROOT/shell/offload.zsh\" ] && source \"$ROOT/shell/offload.zsh\""
  } >> "$ZSHRC"
  ok "added offload to $ZSHRC"
fi

say ""
say "Next:"
say "  1. Edit $OFFLOAD_CONFIG if your machine names differ from mini / macbook"
say "  2. Open a new terminal and run:  offload setup"
say "  3. Do the same on the other Mac"
