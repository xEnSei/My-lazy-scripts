#!/usr/bin/env bash
# pacfix.sh - Targeted package manager repair
# Scope: Eliminating download blockages and sync errors

set -euo pipefail

# --- Color output ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Root check / sudo escalation ---
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# --- Pacman lock check ---
LOCK="/var/lib/pacman/db.lck"
if [[ -f "$LOCK" ]]; then
    if pgrep -x pacman &>/dev/null; then
        error "Pacman läuft aktiv – Lockfile wird nicht entfernt. Abbruch."
        exit 1
    fi
    warn "Verwaistes Lockfile gefunden. Entferne $LOCK ..."
    rm -f "$LOCK"
fi

# --- Step 1: Remove corrupt download fragments ---
info "[1/4] Removing corrupt download fragments..."
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
    if ! timeout 240 cachyos-rate-mirrors; then
        warn "cachyos-rate-mirrors fehlgeschlagen oder Timeout – wird übersprungen."
    fi
else
    warn "cachyos-rate-mirrors not found – mirror optimization skipped."
fi

# --- Step 3: Reconstruct keyrings ---
info "[3/4] Reconstructing trust anchors (keyrings)..."

GNUPG_DIR="/etc/pacman.d/gnupg"
GNUPG_BAK="${GNUPG_DIR}.bak"

# Backup existing keyring before destructive reset
if [[ -d "$GNUPG_DIR" ]]; then
    rm -rf "$GNUPG_BAK"
    cp -a "$GNUPG_DIR" "$GNUPG_BAK"
    info "  Keyring-Backup erstellt: $GNUPG_BAK"
fi

# Full reset to handle corrupt keyring state
rm -rf "$GNUPG_DIR"

# Restore backup and abort if any keyring step fails
keyring_restore() {
    error "Keyring-Rekonstruktion fehlgeschlagen – stelle Backup wieder her."
    rm -rf "$GNUPG_DIR"
    if [[ -d "$GNUPG_BAK" ]]; then
        cp -a "$GNUPG_BAK" "$GNUPG_DIR"
        warn "Backup wiederhergestellt. System-Zustand: unverändert."
    else
        error "Kein Backup vorhanden – manueller Eingriff erforderlich."
    fi
    exit 1
}
trap keyring_restore ERR

pacman-key --init
# Populate from local /usr/share/pacman/keyrings/ before any network sync
# pacman -Syu needs valid keys to verify repo signatures
pacman-key --populate archlinux cachyos
pacman -Syu --noconfirm archlinux-keyring cachyos-keyring

# Keyring intact – disable error trap
trap - ERR

# --- Step 4: Full system sync ---
info "[4/4] Initiating full system synchronization..."
# DBs already current from Step 3 – no -y needed
pacman -Su

echo ""
echo -e "${GREEN}Integrity restored. System status: Nominal.${NC}"
