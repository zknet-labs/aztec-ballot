#!/usr/bin/env bash
set -euo pipefail
clear
#############################################################################
# Aztec Project Setup Script
# Installs/configures the Aztec toolchain for this project.
# Supports macOS (zsh/bash) and Linux (bash/zsh)
#
# Can be invoked from any directory:
#   bash scripts/setup_install.sh
#   cd scripts && ./setup_install.sh
#   /absolute/path/to/setup_install.sh
#
# Version management:
#   The pinned Aztec version is read from .aztecrc in the project root.
#   This is the native upstream convention used by `aztec-up use`.
#############################################################################

# ── Resolve PROJECT_ROOT from the script's own location ──────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function info() { echo -e "${BLUE}ℹ${NC} $1"; }
function success() { echo -e "${GREEN}✓${NC} $1"; }
function warn() { echo -e "${YELLOW}⚠${NC} $1"; }
function error() { echo -e "${RED}✗${NC} $1"; }

#############################################################################
# Detect OS and Shell
#############################################################################

OS="$(uname -s)"
case "$OS" in
Darwin) PLATFORM="macos" ;;
Linux) PLATFORM="linux" ;;
*)
  error "Unsupported OS: $OS"
  exit 1
  ;;
esac


# Detect the user's login shell and corresponding rc file
USER_SHELL="$(basename "${SHELL:-/bin/bash}")"
case "$USER_SHELL" in
zsh) SHELL_RC="$HOME/.zshrc" ;;
bash) SHELL_RC="$HOME/.bashrc" ;;
*)
  SHELL_RC="$HOME/.profile"
  USER_SHELL="sh"
  ;;
esac

# macOS: Check for Xcode Command Line Tools before proceeding
if [ "$PLATFORM" = "macos" ]; then
  if ! xcode-select -p &>/dev/null; then
    error "Xcode Command Line Tools are not installed."
    echo ""
    echo "Please install them first by running: xcode-select --install"
    echo "Then re-run this setup script."
    exit 1
  fi
fi

RC_MODIFIED=false

function reload_shell_rc() {
  if [ "$RC_MODIFIED" = true ]; then
    echo ""
    info "Shell config was modified — reloading $SHELL_RC..."
    # shellcheck disable=SC1090
    source "$SHELL_RC" 2>/dev/null || true
    success "Reloaded $SHELL_RC"
  fi
}

function get_aztec_version() {
  echo ""
  info "Determining Aztec version for this project..."

  AZTECRC="$PROJECT_ROOT/.aztecrc"

  if [ -f "$AZTECRC" ]; then
    AZTEC_VERSION=$(cat "$AZTECRC" | tr -d '[:space:]')
    info "Found .aztecrc: $AZTEC_VERSION"
  else
    echo ""
    warn "No .aztecrc file found in project root."
    read -p "Enter Aztec version (e.g., 4.0.0-devnet.2-patch.1): " AZTEC_VERSION

    if [ -z "$AZTEC_VERSION" ]; then
      error "Version is required!"
      exit 1
    fi

    echo "$AZTEC_VERSION" >"$AZTECRC"
    success "Saved version to $AZTECRC"
    info "Note: .aztecrc is the canonical version pin for this project."
  fi

  echo ""
  success "Project Aztec version: $AZTEC_VERSION"
}

function install_or_update_aztec() {
  echo ""
  info "Checking Aztec installation..."

  if command -v aztec-up &>/dev/null; then
    info "aztec-up is already installed."

    CURRENT_VERSION=$(aztec --version 2>/dev/null | grep -o '[0-9][^ ]*' | head -1 || echo "unknown")
    info "Active aztec version: $CURRENT_VERSION"

    if [ "$CURRENT_VERSION" = "$AZTEC_VERSION" ]; then
      success "Correct version ($AZTEC_VERSION) is already active."
    else
      warn "Version mismatch! Active: $CURRENT_VERSION  →  Required: $AZTEC_VERSION"
      echo ""
      read -p "Install and switch to $AZTEC_VERSION? (y/n): " update
      if [[ "$update" =~ ^[Yy]$ ]]; then
        info "Running: aztec-up install $AZTEC_VERSION"
        aztec-up install "$AZTEC_VERSION"
        # Remove 'shopt: inherit_errexit' from .bin/aztec if on macOS
        if [ "$PLATFORM" = "macos" ]; then
          AZTEC_BIN="$HOME/.aztec/current/node_modules/@aztec/aztec/scripts/aztec.sh"
          if [ -f "$AZTEC_BIN" ]; then
            sed -i '' '/shopt: inherit_errexit/d' "$AZTEC_BIN"
            success "Patched $AZTEC_BIN to remove 'shopt: inherit_errexit' (macOS workaround)"
          fi
        fi
        success "Switched to $AZTEC_VERSION"
      else
        warn "Skipping version switch. The project may not work correctly."
      fi
    fi
  else
    info "aztec-up is not installed. Bootstrapping with the version-specific installer..."
    echo ""
    info "Running: VERSION=$AZTEC_VERSION bash -i <(curl -sL https://install.aztec.network/$AZTEC_VERSION)"
    echo ""

    VERSION="$AZTEC_VERSION" bash -i <(curl -sL "https://install.aztec.network/$AZTEC_VERSION")

    if [ $? -eq 0 ]; then
      success "Aztec $AZTEC_VERSION installed successfully"
      # shellcheck disable=SC1090
      source "$SHELL_RC" 2>/dev/null || true
      # Remove 'shopt: inherit_errexit' from .bin/aztec if on macOS
      if [ "$PLATFORM" = "macos" ]; then
        AZTEC_BIN="$HOME/.aztec/current/node_modules/@aztec/aztec/scripts/aztec.sh"
        if [ -f "$AZTEC_BIN" ]; then
          sed -i '' '/shopt: inherit_errexit/d' "$AZTEC_BIN"
          success "Patched $AZTEC_BIN to remove 'shopt: inherit_errexit' (macOS workaround)"
        fi
      fi
    else
      error "Aztec installation failed"
      exit 1
    fi
  fi
}

function sync_project_dependencies() {
  echo ""
  info "Syncing project dependencies to Aztec version $AZTEC_VERSION..."

  PKG_JSON="$PROJECT_ROOT/package.json"

  if [ -f "$PKG_JSON" ]; then
    CURRENT_PKG_VERSION=$(grep -m1 '"@aztec/' "$PKG_JSON" | sed 's/.*: *"\([^"]*\)".*/\1/')

    if [ "$CURRENT_PKG_VERSION" = "$AZTEC_VERSION" ]; then
      success "package.json @aztec/* deps already at $AZTEC_VERSION"
    else
      info "Updating package.json: $CURRENT_PKG_VERSION → $AZTEC_VERSION"

      sed -i.bak -E \
        "s/(\"@aztec\/[^\"]+\":[[:space:]]*\")[^\"]+(\")/\1${AZTEC_VERSION}\2/g" \
        "$PKG_JSON"
      rm -f "${PKG_JSON}.bak"

      success "Updated @aztec/* deps in package.json to $AZTEC_VERSION"
    fi
  else
    warn "No package.json found at $PKG_JSON — skipping npm deps"
  fi

  NARGO_TAG="v${AZTEC_VERSION}"
  NARGO_UPDATED=0

  for toml in $(find "$PROJECT_ROOT/contracts" -name "Nargo.toml" -not -path "*/target/*"); do
    if grep -q 'tag=' "$toml"; then
      CURRENT_TAG=$(grep -m1 'tag=' "$toml" | sed 's/.*tag="\([^"]*\)".*/\1/')
      if [ "$CURRENT_TAG" = "$NARGO_TAG" ]; then
        continue
      fi
      info "Updating $(basename $(dirname "$toml"))/Nargo.toml: $CURRENT_TAG → $NARGO_TAG"
      sed -i.bak -E "s/tag=\"[^\"]+\"/tag=\"${NARGO_TAG}\"/g" "$toml"
      rm -f "${toml}.bak"
      NARGO_UPDATED=$((NARGO_UPDATED + 1))
    fi
  done

  if [ "$NARGO_UPDATED" -gt 0 ]; then
    success "Updated $NARGO_UPDATED Nargo.toml file(s) to tag=$NARGO_TAG"
  else
    success "All Nargo.toml files already at tag=$NARGO_TAG"
  fi

  if [ "${CURRENT_PKG_VERSION:-}" != "$AZTEC_VERSION" ]; then
    echo ""
    warn "Run 'yarn install' to fetch updated packages."
  fi
}

function show_version_info() {
  echo ""
  info "Version Information:"
  echo ""
  echo "  📦 Aztec: $AZTEC_VERSION"

  if command -v aztec &>/dev/null; then
    ACTIVE=$(aztec --version 2>/dev/null | head -1 || echo "unknown")
    echo "  ✅ Active aztec: $ACTIVE"
  fi

  if command -v nargo &>/dev/null; then
    LOCAL_NARGO=$(nargo --version 2>/dev/null | head -1 | awk '{print $4}' || echo "unknown")
    echo "  🔧 Nargo (local): $LOCAL_NARGO"
  else
    echo "  🔧 Nargo (local): Not installed"
    echo "     For VS Code Noir support, run: noirup"
  fi
}

function summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  success "Setup Complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Platform:     $PLATFORM ($USER_SHELL)"
  echo "Shell config: $SHELL_RC"
  echo "Project root: $PROJECT_ROOT"
  echo "Version pin:  $PROJECT_ROOT/.aztecrc ($AZTEC_VERSION)"
  echo ""
  echo "Aztec Configuration:"
  echo "  • Version: $AZTEC_VERSION"
  echo "  • Managed by: aztec-up (version manager)"
  echo ""
  echo "Next Steps:"
  echo "  1. yarn install                 — fetch updated @aztec/* packages"
  echo "  2. yarn build-contracts         — compile contracts"
  echo "  3. aztec start --local-network  — start local testnet (separate terminal)"
  echo "  4. yarn deploy-contracts        — deploy contracts"
  echo "  5. yarn start                   — run the CLI demo"
  echo ""
  echo "To switch Aztec version in future:"
  echo "  1. Edit .aztecrc with the new version"
  echo "  2. Run: bash scripts/setup_install.sh"
  echo ""
}

#############################################################################
# Main Execution
#############################################################################

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Aztec Project Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Detected: $PLATFORM / $USER_SHELL (rc: $SHELL_RC)"
info "Project root: $PROJECT_ROOT"

get_aztec_version
install_or_update_aztec
sync_project_dependencies
show_version_info

reload_shell_rc

summary
