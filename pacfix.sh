#!/usr/bin/env bash
# pacfix.sh - Targeted package manager repair
# Scope: Eliminating download blockages and sync errors

set -euo pipefail

# --- Color output ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo $0)."
    exit 1
fi

# --- Pacman lock check ---
LOCK="/var/lib/pacman/db.lck"
if [[ -f "$LOCK" ]]; then
    warn "Pacman lockfile detected. Removing $LOCK ..."
    rm -f "$LOCK"
fi

# --- Step 1: Remove corrupt download fragments ---
info "[1/4] Removing corrupt download fragments..."
# Eliminates the physical cause of "Error reading fd 7"
shopt -s nullglob
fragments=(/var/cache/pacman/pkg/download-*)
if (( ${#fragments[@]} > 0 )); then
    rm -rf "${fragments[@]}"
    info "  ${#fragments[@]} fragment(s) removed."
else
    info "  No fragments found."
fi
shopt -u nullglob

# --- Step 2: Optimize mirror infrastructure ---
info "[2/4] Validating and optimizing mirror infrastructure..."
if command -v cachyos-rate-mirrors &>/dev/null; then
    cachyos-rate-mirrors
else
    warn "cachyos-rate-mirrors not found – mirror optimization skipped."
fi

# --- Step 3: Reconstruct keyrings ---
info "[3/4] Reconstructing trust anchors (keyrings)..."
# Correct order: init → sync DB → install keyring packages → populate
# --populate reads from /usr/share/pacman/keyrings/, which is written by the packages
pacman-key --init
pacman -Sy --noconfirm archlinux-keyring cachyos-keyring
pacman-key --populate archlinux cachyos

# --- Step 4: Full system sync ---
info "[4/4] Initiating full system synchronization..."
pacman -Su  # No -y needed – DB already current from step 3

echo ""
echo -e "${GREEN}Integrity restored. System status: Nominal.${NC}"
