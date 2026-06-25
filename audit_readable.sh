#!/usr/bin/env bash
# ==============================================================================
# CachyOS / Arch Linux Audit (Readable Edition)
# Version: 2.0 (Enhanced with Complete Package Inventory)
# Usage:
#   ./audit_readable.sh
#   ./audit_readable.sh --extended
#   ./audit_readable.sh --full-packages
#   ./audit_readable.sh --no-redact
# ==============================================================================

set -uo pipefail

MODE="standard"
REDACT_SENSITIVE=1

for arg in "$@"; do
    case "$arg" in
        --extended) MODE="extended" ;;
        --full-packages) MODE="full" ;;
        --no-redact) REDACT_SENSITIVE=0 ;;
    esac
done

TS=$(date '+%Y-%m-%d_%H-%M-%S')
DISTRO=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
OUT="${DISTRO}_audit_${TS}.txt"
PKG_OUT="${DISTRO}_packages_${TS}.txt"

redact_ip() {
    # Redact IP addresses: XXX.XXX.XXX.XXX -> XXX.XXX.X.X
    sed -E 's/([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/\1.\2.X.X/g'
}

redact_mac() {
    # Redact MAC addresses: aa:bb:cc:dd:ee:ff -> XX:XX:XX:[REDACTED]
    sed -E 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/XX:XX:XX:[REDACTED]/g'
}

section() {
    echo
    echo "===================================================================="
    echo "$1"
    echo "===================================================================="
    echo
}

{
echo "===================================================================="
echo "SYSTEM AUDIT REPORT"
echo "===================================================================="
echo
printf "%-15s : %s\n" "Hostname" "$(hostname)"
printf "%-15s : %s\n" "Distribution" "$DISTRO"
printf "%-15s : %s\n" "Kernel" "$(uname -r)"
printf "%-15s : %s\n" "Generated" "$(date)"
printf "%-15s : %s\n" "Redacted" "$([ $REDACT_SENSITIVE -eq 1 ] && echo 'YES' || echo 'NO')"
echo

section "SYSTEM SUMMARY"

CPU=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)
RAM=$(free -h | awk '/Mem:/ {print $2}')
GPU=$(lspci 2>/dev/null | grep -E 'VGA|3D|Display' | head -n1 | cut -d: -f3- | xargs)

printf "%-15s : %s\n" "CPU" "$CPU"
printf "%-15s : %s\n" "Memory" "$RAM"
printf "%-15s : %s\n" "GPU" "${GPU:-Not detected}"

section "CPU"

printf "%-15s : %s\n" "Model" "$CPU"
printf "%-15s : %s\n" "Threads" "$(nproc)"
printf "%-15s : %s\n" "Architecture" "$(uname -m)"

FLAGS=$(grep -m1 '^flags' /proc/cpuinfo)

if echo "$FLAGS" | grep -qw avx512f; then
    LEVEL="x86-64-v4"
elif echo "$FLAGS" | grep -qw avx2; then
    LEVEL="x86-64-v3"
elif echo "$FLAGS" | grep -qw sse4_2; then
    LEVEL="x86-64-v2"
else
    LEVEL="x86-64-v1"
fi

printf "%-15s : %s\n" "Instruction" "$LEVEL"

section "MEMORY"

free -h

section "GRAPHICS"

lspci 2>/dev/null | grep -E 'VGA|3D|Display' | sed 's/^[0-9a-f:.]*//'

echo
echo "Drivers:"
lspci -k 2>/dev/null | grep -A3 -E 'VGA|3D|Display' | sed 's/^[0-9a-f:.]*//'

section "MONITORS"

FOUND=0
for f in /sys/class/drm/card*-*/status; do
    [[ -f "$f" ]] || continue
    FOUND=1
    printf "%-20s : %s\n" \
        "$(basename "$(dirname "$f")")" \
        "$(cat "$f")"
done

[[ $FOUND -eq 0 ]] && echo "No DRM monitor data available."

section "MAINBOARD / BIOS"

printf "%-15s : %s\n" "Vendor" "$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo 'unknown')"
printf "%-15s : %s\n" "Board" "$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo 'unknown')"
printf "%-15s : %s\n" "BIOS" "$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo 'unknown')"

section "STORAGE"

lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null || true

echo
echo "Filesystem Usage:"
df -h / 2>/dev/null || true

section "NETWORK"

echo "PCI Network Adapters:"
lspci 2>/dev/null | grep -iE 'ethernet|network|wireless' | sed 's/^[0-9a-f:.]*//' | sort -u || echo "No network devices detected"

echo
echo "Network Interfaces (Names and Status only):"
if command -v ip >/dev/null 2>&1; then
    ip -brief link 2>/dev/null | awk '{print $1, $2}' | column -t || echo "Unable to retrieve interface info"
else
    echo "ip command not available"
fi

section "AUDIO"

if command -v wpctl >/dev/null 2>&1; then
    echo "PipeWire: Detected"
    wpctl status 2>/dev/null | head -15
else
    echo "PipeWire: Not detected"
fi

echo
echo "ALSA Devices:"
if command -v aplay >/dev/null 2>&1; then
    aplay -l 2>/dev/null | grep '^card' || echo "No ALSA devices detected"
else
    echo "aplay not available"
fi

section "BOOT & SECURITY"

if [[ -e /dev/tpm0 || -e /dev/tpmrm0 ]]; then
    echo "TPM          : Present"
else
    echo "TPM          : Not detected"
fi

if command -v mokutil >/dev/null 2>&1; then
    echo "Secure Boot  : $(mokutil --sb-state 2>/dev/null | head -n1)"
fi

echo
echo "Microcode:"
pacman -Q amd-ucode intel-ucode 2>/dev/null || echo "Microcode packages not installed"

section "CACHYOS ANALYSIS"

echo "Repositories:"
if command -v pacman-conf >/dev/null 2>&1; then
    pacman-conf --repo-list 2>/dev/null | sed 's/^/  - /' || echo "  Unable to retrieve repositories"
else
    echo "  pacman-conf not available"
fi

echo
echo "glibc:"
pacman -Q glibc 2>/dev/null || echo "glibc not found"

section "INSTALLED KERNELS"

pacman -Qq 2>/dev/null | grep '^linux' | sed 's/^/  - /' || echo "No linux packages found"

section "PACKAGE SUMMARY"

TOTAL=$(pacman -Q 2>/dev/null | wc -l)
AUR=$(pacman -Qm 2>/dev/null | wc -l)
OFFICIAL=$((TOTAL - AUR))

printf "%-20s : %d\n" "Total Packages" "$TOTAL"
printf "%-20s : %d\n" "Official Packages" "$OFFICIAL"
printf "%-20s : %d\n" "AUR Packages" "$AUR"

echo
echo "→ Complete package inventory saved to:"
echo "   $PKG_OUT"

if [[ "$MODE" != "standard" ]]; then
    echo
    echo "Top AUR Packages (showing first 50):"
    pacman -Qm 2>/dev/null | head -50 | sed 's/^/  /'
    if [ $(pacman -Qm 2>/dev/null | wc -l) -gt 50 ]; then
        echo "  ... and $(( $(pacman -Qm 2>/dev/null | wc -l) - 50 )) more AUR packages"
    fi
fi

section "FLATPAK"

if command -v flatpak >/dev/null 2>&1; then
    APPS=$(flatpak list --app 2>/dev/null | tail -n +1 | wc -l)
    RT=$(flatpak list --runtime 2>/dev/null | tail -n +1 | wc -l)

    printf "%-20s : %d\n" "Applications" "$APPS"
    printf "%-20s : %d\n" "Runtimes" "$RT"
else
    echo "Flatpak not installed"
fi

if [[ "$MODE" == "extended" || "$MODE" == "full" ]]; then

section "EXTENDED INFORMATION"

echo "USB Devices:"
lsusb 2>/dev/null || echo "lsusb not available"

echo
echo "BTRFS Filesystems:"
if command -v btrfs >/dev/null 2>&1; then
    btrfs filesystem show 2>/dev/null || echo "No BTRFS filesystems detected"
else
    echo "btrfs-progs not installed"
fi

echo
echo "SMART Device Status:"
for d in /dev/sd? /dev/nvme?n1; do
    [[ -e "$d" ]] || continue
    echo "  $d: $(smartctl -H "$d" 2>/dev/null | head -n3 | tail -n1 || echo 'Unable to read')"
done

fi

echo
echo "===================================================================="
echo "END OF REPORT"
echo "===================================================================="

} > "$OUT" 2>&1

# Apply redaction if enabled
if [[ "$REDACT_SENSITIVE" -eq 1 ]]; then
    sed -i -e "$(redact_ip)" -e "$(redact_mac)" "$OUT" 2>/dev/null || true
fi

# ============================================================================
# CREATE COMPREHENSIVE PACKAGE INVENTORY FILE
# ============================================================================

{
echo "===================================================================="
echo "CACHYOS / ARCH LINUX - COMPLETE PACKAGE INVENTORY"
echo "===================================================================="
echo
printf "%-20s : %s\n" "Generated" "$(date)"
printf "%-20s : %s\n" "Hostname" "$(hostname)"
printf "%-20s : %s\n" "Distribution" "$DISTRO"
echo

section "PACKAGE STATISTICS"

TOTAL=$(pacman -Q 2>/dev/null | wc -l)
OFFICIAL=$(pacman -Qn 2>/dev/null | wc -l)
AUR=$(pacman -Qm 2>/dev/null | wc -l)
EXPLICIT=$(pacman -Qe 2>/dev/null | wc -l)
DEPS=$(pacman -Qd 2>/dev/null | wc -l)

printf "%-25s : %5d\n" "Total Packages" "$TOTAL"
printf "%-25s : %5d\n" "Official Repository" "$OFFICIAL"
printf "%-25s : %5d\n" "AUR (User-Built)" "$AUR"
printf "%-25s : %5d\n" "Explicitly Installed" "$EXPLICIT"
printf "%-25s : %5d\n" "As Dependencies" "$DEPS"

section "CACHYOS REPOSITORIES"

if command -v pacman-conf >/dev/null 2>&1; then
    repos=$(pacman-conf --repo-list 2>/dev/null)
    echo "Configured Repositories:"
    for repo in $repos; do
        count=$(pacman -Sql "$repo" 2>/dev/null | wc -l)
        printf "  %-20s : %5d packages available\n" "$repo" "$count"
    done
else
    echo "pacman-conf not available"
fi

section "OFFICIAL PACKAGES - ALPHABETICAL ($OFFICIAL total)"

echo "Format: PACKAGE VERSION SIZE"
pacman -Qn 2>/dev/null | sort || echo "No official packages found"

section "AUR PACKAGES - USER-BUILT ($AUR total)"

echo "Format: PACKAGE VERSION"
pacman -Qm 2>/dev/null | sort || echo "No AUR packages installed"

section "EXPLICITLY INSTALLED PACKAGES ($EXPLICIT total)"

echo "Format: PACKAGE VERSION SOURCE"
pacman -Qe 2>/dev/null | sort || echo "No explicit packages found"

section "DEPENDENCY PACKAGES ONLY ($DEPS total)"

echo "Format: PACKAGE VERSION SOURCE"
pacman -Qd 2>/dev/null | sort || echo "No dependency packages found"

section "TOP 50 PACKAGES BY INSTALLED SIZE"

echo "Format: SIZE PACKAGE"
pacman -Qi 2>/dev/null | \
    awk '/^Name/ {name=$3} /^Installed Size/ {size=$4; gsub(/[^0-9.]/, "", size); print size " " name}' | \
    sort -rn | head -50 | \
    awk '{printf "%-15s %s\n", $1, $2}' || echo "Unable to retrieve package sizes"

section "PACKAGES WITH MULTIPLE VERSIONS / CONFLICTS"

echo "Checking for packages that might have conflicts or multiple installations..."
echo "(Usually empty - listed if found:)"
echo

pacman -Qq 2>/dev/null | sort | uniq -d | sed 's/^/  /' || echo "  No duplicate packages detected (normal state)"

section "PACKAGE GROUPS"

echo "Installed package groups:"
for group in $(pacman -Qq --groups 2>/dev/null | cut -d' ' -f2 | sort -u); do
    count=$(pacman -Qg "$group" 2>/dev/null | wc -l)
    [ $count -gt 0 ] && printf "  %-30s : %3d packages\n" "$group" "$count"
done

section "FOREIGN PACKAGES"

echo "Packages not in official repos or AUR (these need investigation):"
pacman -Qm 2>/dev/null | sed 's/^/  /' || echo "  None found"

section "ORPHANED PACKAGES"

echo "Installed packages with no dependencies (safe to remove):"
if command -v pacman >/dev/null 2>&1; then
    ORPHANS=$(pacman -Qdt 2>/dev/null | wc -l)
    if [ "$ORPHANS" -gt 0 ]; then
        pacman -Qdt 2>/dev/null | sed 's/^/  /'
    else
        echo "  No orphaned packages found (clean installation)"
    fi
else
    echo "  Unable to check for orphaned packages"
fi

section "DETAILED PACKAGE INFORMATION"

echo "Complete list with all details:"
echo
pacman -Q 2>/dev/null | sort || echo "No packages found"

echo
echo "===================================================================="
echo "END OF PACKAGE INVENTORY"
echo "===================================================================="

} > "$PKG_OUT" 2>&1

# Summary output
echo
echo "════════════════════════════════════════════════════════════════════"
echo "AUDIT COMPLETE"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "Generated files:"
printf "  %-35s : %s\n" "System Audit Report" "$(basename "$OUT")"
printf "  %-35s : %s\n" "Package Inventory" "$(basename "$PKG_OUT")"
echo
echo "File sizes:"
du -h "$OUT" "$PKG_OUT" 2>/dev/null | awk '{printf "  %-35s : %s\n", $2, $1}'
echo
echo "Usage:"
echo "  ./audit_readable.sh                    # Standard mode"
echo "  ./audit_readable.sh --extended         # Extended info"
echo "  ./audit_readable.sh --full-packages    # Show all packages in report"
echo "  ./audit_readable.sh --no-redact        # Don't redact sensitive data"
echo
echo "Mode: $MODE"
echo "Sensitive data redacted: $([ $REDACT_SENSITIVE -eq 1 ] && echo 'YES' || echo 'NO')"
echo
