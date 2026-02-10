#!/usr/bin/env bash
set -euo pipefail
clear
#############################################################################
# Aztec Project Setup Script
# Sets up Docker security restrictions and installs/configures Aztec
# Supports macOS (zsh/bash) and Linux (bash/zsh)
#
# Can be invoked from any directory:
#   bash scripts/setup_install.sh
#   cd scripts && ./setup_install.sh
#   /absolute/path/to/setup_install.sh
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
  Linux)  PLATFORM="linux" ;;
  *)      error "Unsupported OS: $OS"; exit 1 ;;
esac

# Detect the user's login shell and corresponding rc file
USER_SHELL="$(basename "${SHELL:-/bin/bash}")"
case "$USER_SHELL" in
  zsh)  SHELL_RC="$HOME/.zshrc" ;;
  bash) SHELL_RC="$HOME/.bashrc" ;;
  *)    SHELL_RC="$HOME/.profile"; USER_SHELL="sh" ;;
esac

# Track whether we modified the rc file (to know if we need to source it)
RC_MODIFIED=false

# Helper: append a line to the shell rc file if not already present
function ensure_in_rc() {
  local line="$1"
  local label="${2:-$1}"
  if grep -qF "$line" "$SHELL_RC" 2>/dev/null; then
    info "Already in $SHELL_RC: $label"
  else
    echo "$line" >> "$SHELL_RC"
    success "Added to $SHELL_RC: $label"
    RC_MODIFIED=true
  fi
}

# Helper: remove a matching line from the shell rc file
function remove_from_rc() {
  local pattern="$1"
  local label="${2:-$pattern}"
  if grep -q "$pattern" "$SHELL_RC" 2>/dev/null; then
    sed -i.bak "/$pattern/d" "$SHELL_RC"
    rm -f "${SHELL_RC}.bak"
    success "Removed from $SHELL_RC: $label"
    RC_MODIFIED=true
  fi
}

# Helper: source the rc file in the current session if it was modified
function reload_shell_rc() {
  if [ "$RC_MODIFIED" = true ]; then
    echo ""
    info "Shell config was modified — reloading $SHELL_RC..."
    # shellcheck disable=SC1090
    source "$SHELL_RC" 2>/dev/null || true
    success "Reloaded $SHELL_RC"
  fi
}

function check_docker() {
  info "Checking Docker installation..."
  
  if ! command -v docker &>/dev/null; then
    error "Docker is not installed!"
    echo ""
    if [ "$PLATFORM" = "macos" ]; then
      echo "Please install Docker Desktop from:"
      echo "  https://docs.docker.com/desktop/install/mac-install/"
    else
      echo "Please install Docker Engine from:"
      echo "  https://docs.docker.com/engine/install/"
      echo ""
      echo "Or install Docker Desktop for Linux:"
      echo "  https://docs.docker.com/desktop/install/linux/"
    fi
    echo ""
    exit 1
  fi
  
  if ! docker info &>/dev/null; then
    error "Docker is installed but not running!"
    echo ""
    if [ "$PLATFORM" = "macos" ]; then
      echo "Please start Docker Desktop and try again."
    else
      echo "Please start the Docker daemon:"
      echo "  sudo systemctl start docker"
      echo ""
      echo "Or if using Docker Desktop for Linux, start the application."
    fi
    exit 1
  fi
  
  success "Docker is installed and running"
}

function get_mount_base() {
  echo ""
  info "Configuring Docker mount restrictions..."
  echo ""
  echo "Docker needs access to your project files. For security, we restrict"
  echo "Docker to only access a specific directory (not your entire home folder)."
  echo ""
  
  # Suggest parent of project root as default
  DEFAULT_MOUNT=$(dirname "$PROJECT_ROOT")

  echo "Project root:       $PROJECT_ROOT"
  echo "Suggested mount base: $DEFAULT_MOUNT"
  echo ""
  read -p "Enter Docker mount base directory (or press Enter for default): " USER_INPUT
  
  if [ -z "$USER_INPUT" ]; then
    DOCKER_MOUNT_BASE="$DEFAULT_MOUNT"
  else
    # Expand ~ if present
    DOCKER_MOUNT_BASE="${USER_INPUT/#\~/$HOME}"
  fi
  
  # Validate directory exists
  if [ ! -d "$DOCKER_MOUNT_BASE" ]; then
    error "Directory does not exist: $DOCKER_MOUNT_BASE"
    exit 1
  fi
  
  # Validate project root is within mount base
  if [[ "$PROJECT_ROOT" != "$DOCKER_MOUNT_BASE"* ]]; then
    error "Project root is not within the mount base!"
    echo "  Project: $PROJECT_ROOT"
    echo "  Mount:   $DOCKER_MOUNT_BASE"
    exit 1
  fi
  
  success "Docker mount base: $DOCKER_MOUNT_BASE"
  echo ""
  warn "Docker will ONLY have access to: $DOCKER_MOUNT_BASE"
  warn "Docker will NOT access: Documents, Downloads, Desktop, .ssh, etc."
  echo ""
  read -p "Continue? (y/n): " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    exit 0
  fi
}

function check_rootless() {
  echo ""
  info "Checking ROOTLESS environment variable..."
  
  if [ -z "${ROOTLESS:-}" ]; then
    warn "ROOTLESS is not set in your environment"
    echo ""
    if [ "$PLATFORM" = "macos" ]; then
      echo "On macOS, Aztec may fail without this variable set."
    else
      echo "Some Aztec configurations require this variable."
    fi
    echo "We'll add 'export ROOTLESS=true' to your $SHELL_RC"
    echo ""
    
    ensure_in_rc "export ROOTLESS=true"
    
    export ROOTLESS=true
    success "Set ROOTLESS=true for current session"
  else
    success "ROOTLESS is already set to: $ROOTLESS"
  fi
}

function get_aztec_version() {
  echo ""
  info "Determining Aztec version for this project..."
  
  # Check if there's a version file in the project root
  if [ -f "$PROJECT_ROOT/aztec-version.txt" ]; then
    AZTEC_VERSION=$(cat "$PROJECT_ROOT/aztec-version.txt" | tr -d '[:space:]')
    info "Found aztec-version.txt: $AZTEC_VERSION"
  elif [ -f "$PROJECT_ROOT/aztec-version" ]; then
    AZTEC_VERSION=$(cat "$PROJECT_ROOT/aztec-version" | tr -d '[:space:]')
    info "Found aztec-version: $AZTEC_VERSION"
  else
    echo ""
    echo "No version file found in project."
    read -p "Enter Aztec version (e.g., 3.0.0-devnet.6-patch.1): " AZTEC_VERSION
    
    if [ -z "$AZTEC_VERSION" ]; then
      error "Version is required!"
      exit 1
    fi
    
    # Offer to save version to file
    read -p "Save version to aztec-version.txt? (y/n): " save_version
    if [[ "$save_version" =~ ^[Yy]$ ]]; then
      echo "$AZTEC_VERSION" > "$PROJECT_ROOT/aztec-version.txt"
      success "Saved to $PROJECT_ROOT/aztec-version.txt"
    fi
  fi
  
  echo ""
  success "Project Aztec version: $AZTEC_VERSION"
}

function install_or_update_aztec() {
  echo ""
  info "Checking Aztec installation..."
  
  if command -v aztec &>/dev/null; then
    CURRENT_VERSION=$(cat ~/.aztec/default_version 2>/dev/null || echo "unknown")
    info "Aztec is installed (current version: $CURRENT_VERSION)"
    
    if [ "$CURRENT_VERSION" != "$AZTEC_VERSION" ]; then
      warn "Version mismatch! Need: $AZTEC_VERSION"
      echo ""
      read -p "Update to $AZTEC_VERSION? (y/n): " update
      if [[ "$update" =~ ^[Yy]$ ]]; then
        info "Running aztec-up -v $AZTEC_VERSION..."
        aztec-up -v "$AZTEC_VERSION"
        success "Updated to $AZTEC_VERSION"
      fi
    else
      success "Correct version already installed"
    fi
  else
    info "Aztec is not installed. Installing version $AZTEC_VERSION..."
    echo ""
    
    # Set VERSION env var for installer
    export VERSION="$AZTEC_VERSION"
    
    # Run Aztec installer
    bash -i <(curl -s https://install.aztec.network)
    
    if [ $? -eq 0 ]; then
      success "Aztec $AZTEC_VERSION installed successfully"
    else
      error "Aztec installation failed"
      exit 1
    fi
  fi
}

function apply_security_patches() {
  echo ""
  info "Applying Docker security patches..."
  
  NARGO_CACHE_DIR="${DOCKER_MOUNT_BASE}/.nargo-cache"
  
  # Create nargo cache directory with git subdirs
  mkdir -p "$NARGO_CACHE_DIR/git/checkouts"
  mkdir -p "$NARGO_CACHE_DIR/git/db"
  chmod -R 777 "$NARGO_CACHE_DIR"
  
  # Backup originals
  for script in .aztec-run aztec; do
    if [ ! -f ~/.aztec/bin/${script}.original ]; then
      cp ~/.aztec/bin/${script} ~/.aztec/bin/${script}.original
      success "Backed up ${script}"
    fi
  done
  
  # Patch .aztec-run
  sed \
    -e "s|if \[\[ \$PWD != \${HOME}\*|if [[ \$PWD != ${DOCKER_MOUNT_BASE}*|g" \
    -e "s|arg_volume_mounts=\"-v \$HOME:\$HOME|arg_volume_mounts=\"-v ${DOCKER_MOUNT_BASE}:${DOCKER_MOUNT_BASE}|g" \
    -e "s|\[\[ \$(realpath \$arg) != \${HOME}\*|\[\[ \$(realpath \$arg) != ${DOCKER_MOUNT_BASE}*|g" \
    -e "s|paths outside of \$HOME|paths outside of ${DOCKER_MOUNT_BASE}|g" \
    -e "s|within \$HOME|within ${DOCKER_MOUNT_BASE}|g" \
    -e 's|arg_env_vars=("-e" "HOME=\$HOME")|arg_env_vars=("-e" "HOME='${DOCKER_MOUNT_BASE}'")|g' \
    ~/.aztec/bin/.aztec-run.original > ~/.aztec/bin/.aztec-run
  
  chmod +x ~/.aztec/bin/.aztec-run
  success "Patched .aztec-run"
  
  # Patch aztec
  sed \
    -e "s|if \[\[ \$PWD != \${HOME}\*|if [[ \$PWD != ${DOCKER_MOUNT_BASE}*|g" \
    -e "s|-v \$HOME:\$HOME|-v ${DOCKER_MOUNT_BASE}:${DOCKER_MOUNT_BASE}|g" \
    -e "s|within \$HOME|within ${DOCKER_MOUNT_BASE}|g" \
    -e "s|under \$HOME|under ${DOCKER_MOUNT_BASE}|g" \
    -e "s|-e HOME=\$HOME|-e HOME=${DOCKER_MOUNT_BASE} -e NARGO_HOME=${NARGO_CACHE_DIR}|g" \
    ~/.aztec/bin/aztec.original > ~/.aztec/bin/aztec
  
  chmod +x ~/.aztec/bin/aztec
  success "Patched aztec"
  
  # Remove NARGO_HOME from shell config if present (not needed locally)
  remove_from_rc "export NARGO_HOME.*zknet.*nargo-cache" "Docker-specific NARGO_HOME"
}

function configure_docker_desktop() {
  echo ""

  if [ "$PLATFORM" = "linux" ]; then
    if docker context inspect desktop-linux &>/dev/null 2>&1; then
      info "Docker Desktop for Linux detected"
      warn "MANUAL STEP REQUIRED:"
      echo "  1. Open Docker Desktop"
      echo "  2. Go to Settings → Resources → File Sharing"
      echo "  3. ADD: $DOCKER_MOUNT_BASE (if not already present)"
      echo "  4. Click 'Apply & Restart'"
      echo ""
      read -p "Press Enter when you've completed this step..."
      success "Docker Desktop configured"
    else
      info "Docker Engine detected (native Linux)"
      success "No file sharing configuration needed — Docker has native filesystem access"
    fi
  else
    info "Docker Desktop File Sharing Configuration"
    echo ""
    warn "MANUAL STEP REQUIRED:"
    echo "  1. Open Docker Desktop"
    echo "  2. Go to Settings → Resources → File Sharing"
    echo "  3. REMOVE: /Users (if present)"
    echo "  4. ADD: $DOCKER_MOUNT_BASE"
    echo "  5. Click 'Apply & Restart'"
    echo ""
    read -p "Press Enter when you've completed this step..."
    success "Docker Desktop configured"
  fi
}

function show_version_info() {
  echo ""
  info "Version Information:"
  echo ""
  
  echo "  📦 Aztec: $AZTEC_VERSION"
  
  DOCKER_NARGO_VERSION=$(docker run --rm --entrypoint=/usr/src/noir/noir-repo/target/release/nargo \
    aztecprotocol/aztec:$AZTEC_VERSION --version 2>/dev/null | head -1 | grep -o 'nargo version = [^ ]*' | cut -d' ' -f4) || true
  
  if [ -n "${DOCKER_NARGO_VERSION:-}" ]; then
    echo "  🔧 Nargo (in Aztec): $DOCKER_NARGO_VERSION"
  fi
  
  if command -v nargo &>/dev/null; then
    LOCAL_NARGO=$(nargo --version 2>/dev/null | head -1 | awk '{print $4}')
    echo "  💻 Nargo (local): $LOCAL_NARGO"
    
    if [ -n "${DOCKER_NARGO_VERSION:-}" ] && [ "$LOCAL_NARGO" != "$DOCKER_NARGO_VERSION" ]; then
      warn "Local nargo version doesn't match Aztec's nargo"
      echo "     For best VS Code support, run: noirup -v $DOCKER_NARGO_VERSION"
    fi
  else
    echo "  💻 Nargo (local): Not installed"
    if [ -n "${DOCKER_NARGO_VERSION:-}" ]; then
      echo "     For VS Code support, run: noirup -v $DOCKER_NARGO_VERSION"
    fi
  fi
}

function create_project_config() {
  echo ""
 
  if [ -f "$PROJECT_ROOT/.gitignore" ]; then
    if ! grep -q ".nargo-cache" "$PROJECT_ROOT/.gitignore"; then
      echo ".nargo-cache/" >> "$PROJECT_ROOT/.gitignore"
      success "Added .nargo-cache/ to .gitignore"
    fi
  fi
}

function sync_project_dependencies() {
  echo ""
  info "Syncing project dependencies to Aztec version $AZTEC_VERSION..."

  PKG_JSON="$PROJECT_ROOT/package.json"

  # ── 1. Update package.json @aztec/* dependencies ──────────────────────────

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

  # ── 2. Update Nargo.toml tag= references ──────────────────────────────────

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

  if [ "$CURRENT_PKG_VERSION" != "$AZTEC_VERSION" ]; then
    echo ""
    warn "please run yarn install to fetch updated packages..."
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
  echo ""
  echo "Docker Security:"
  echo "  ✓ Can access:     $DOCKER_MOUNT_BASE"
  echo "  ✗ Cannot access:  Documents, Downloads, Desktop, .ssh, etc."
  echo ""
  echo "Aztec Configuration:"
  echo "  • Version: $AZTEC_VERSION"
  echo "  • Nargo cache: ${DOCKER_MOUNT_BASE}/.nargo-cache"
  echo ""
  echo "Next Steps:"
  echo "  1. yarn install - to apply @aztec/* dependencies"
  echo "  2. (optional) Test contracts: yarn test-contracts"
  echo "  3. build contracts: yarn build-contracts"
  echo "  4. Start sandbox in a different terminal: aztec start --local-network"
  echo "  5. deploy contracts: yarn deploy-contracts"
  echo "  6. run demo app: yarn demo"
  echo ""
  echo "After each aztec upgrade:"
  echo "  • update the Aztec version in the aztec-version.txt file (project root)"
  echo "  • run this script again"
  echo ""
}

#############################################################################
# Main Execution
#############################################################################

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Aztec Project Setup & Security Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Detected: $PLATFORM / $USER_SHELL (rc: $SHELL_RC)"
info "Project root: $PROJECT_ROOT"

check_docker
get_mount_base
check_rootless
get_aztec_version
install_or_update_aztec
sync_project_dependencies
apply_security_patches
configure_docker_desktop
show_version_info
create_project_config

# Source the shell rc file if we modified it, so the user doesn't have to
reload_shell_rc

summary