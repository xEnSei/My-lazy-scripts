#!/usr/bin/env bash

# ==============================================================================
# SYSTEM-AUDIT SCRIPT
# ==============================================================================

# 1. Privilege separation & root check
# realpath resolves symlinks and relative paths before exec
SCRIPT_PATH=$(realpath "$0")

# User-session data must be collected BEFORE sudo relaunch.
# kscreen-doctor requires an active Wayland/DBus session which root cannot access.
MONITOR_TMPFILE=$(mktemp /tmp/sys_audit_monitors.XXXXXX)
if [ "$EUID" -ne 0 ] && command -v kscreen-doctor >/dev/null 2>&1; then
    # WAYLAND_DISPLAY must be exported explicitly; fish does not auto-export to bash subshells.
    # Probe wayland-0 and wayland-1 as fallbacks if the variable is unset.
    _wd="${WAYLAND_DISPLAY:-}"
    if [ -z "$_wd" ]; then
        for _sock in wayland-0 wayland-1; do
            [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$_sock" ] && _wd="$_sock" && break
        done
    fi
    # ddcutil reads monitor names via I2C (works with NVIDIA open driver).
    # Build a connector->name map: "Display N" order from ddcutil matches
    # kscreen output index order. We pair them by position.
    declare -A _MON_NAMES=()
    if command -v ddcutil >/dev/null 2>&1; then
        mapfile -t _ddcutil_names < <(
            ddcutil detect --verbose 2>/dev/null             | grep "Monitor Model Id:"             | sed 's/.*Monitor Model Id: *//'             | sed 's/-[0-9]*$//'             | sed 's/-/ /g'
        )
        mapfile -t _kscreen_connectors < <(
            WAYLAND_DISPLAY="$_wd" kscreen-doctor -o 2>/dev/null             | sed 's/\x1b\[[0-9;]*m//g'             | grep "^Output:"             | sed -E 's/^Output: ([0-9]+) ([A-Z]+-[0-9]+).*/\1 \2/'
        )
        for _entry in "${_kscreen_connectors[@]}"; do
            _idx=$(echo "$_entry" | awk '{print $1}')
            _conn=$(echo "$_entry" | awk '{print $2}')
            _name="${_ddcutil_names[$_idx-1]:-}"
            [ -n "$_name" ] && _MON_NAMES["$_conn"]="$_name"
        done
    fi

    WAYLAND_DISPLAY="$_wd" kscreen-doctor -o 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -vE "^\s+Modes:" \
        | grep -vE "^\s+Custom modes:" \
        | grep -vE "^\s+replication source:" \
        | grep -vE "^\s+priority [0-9]" \
        | sed -E 's/^(Output: [0-9]+ ([A-Z]+-[0-9]+)) [a-f0-9-]{36}/\1/' \
        | awk '/^Output:/{if(NR>1) print ""} {print}' \
        | while IFS= read -r _line; do
            if [[ "$_line" =~ ^Output:\ [0-9]+\ ([A-Z]+-[0-9]+) ]]; then
                _conn="${BASH_REMATCH[1]}"
                _name="${_MON_NAMES[$_conn]:-}"
                [ -n "$_name" ] && _line="$_line  [$_name]"
            fi
            echo "$_line"
          done \
        > "$MONITOR_TMPFILE"
fi

if [ "$EUID" -ne 0 ]; then
    sudo -v || { echo "Error: sudo authentication required."; exit 1; }
    exec sudo bash "$SCRIPT_PATH" --monitor-tmpfile "$MONITOR_TMPFILE" "$@"
fi

# Parse --monitor-tmpfile argument passed from user-space invocation
MONITOR_TMPFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --monitor-tmpfile) MONITOR_TMPFILE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Preserve calling user's UID for chown at end
CALLER_USER="${SUDO_USER:-$USER}"
CALLER_UID=$(id -u "$CALLER_USER" 2>/dev/null)

# 2. Metadata & dynamic naming (format: distroname_YYYY.MM.DD_HHMM)
DISTRO_ID=$(grep "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
DATE_TAG=$(date "+%Y.%m.%d")
TIME_TAG=$(date "+%H%M")
OUTPUT="${DISTRO_ID}_${DATE_TAG}_${TIME_TAG}.txt"

# 3. Hardware metadata & environment
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
HOSTNAME_STR=$(hostname)
CPU_FULL=$(grep "model name" /proc/cpuinfo | head -n1 | cut -d':' -f2 | xargs)

# 3b. Extended hardware metadata

# Motherboard (DMI sysfs)
MB_VENDOR=$(cat /sys/class/dmi/id/board_vendor  2>/dev/null | xargs)
MB_NAME=$(cat   /sys/class/dmi/id/board_name    2>/dev/null | xargs)
MB_VER=$(cat    /sys/class/dmi/id/board_version 2>/dev/null | xargs)
MAINBOARD="${MB_VENDOR} ${MB_NAME}${MB_VER:+ (${MB_VER})}"

# Storage devices (physical block devices only, no loop/zram devices)
STORAGE=$(lsblk -d -o NAME,SIZE,MODEL,TRAN --noheadings 2>/dev/null \
    | grep -vE "^(loop|zram)" \
    | awk '{printf "  - /dev/%-6s %6s  %-30s [%s]\n", $1, $2, $3, $4}')
[ -z "$STORAGE" ] && STORAGE="  (no block devices detected)"

# Monitors: read from tmpfile written by user-space invocation (before sudo).
# Falls back to DRM sysfs if tmpfile absent or empty.
# Note on DRM fallback: NVIDIA only writes EDID to sysfs when compositor holds
# DRM ownership – under root without session the file is always empty.
MONITORS=""
if [ -n "$MONITOR_TMPFILE" ] && [ -s "$MONITOR_TMPFILE" ]; then
    MONITORS=$(cat "$MONITOR_TMPFILE")
    rm -f "$MONITOR_TMPFILE"
else
    rm -f "$MONITOR_TMPFILE"
    # DRM sysfs fallback (EDID will be empty under sudo without compositor ownership)
    for conn_path in /sys/class/drm/card*-*/; do
        [ -f "${conn_path}status" ] || continue
        [ "$(cat "${conn_path}status" 2>/dev/null)" = "connected" ] || continue
        conn=$(basename "$conn_path")
        mon_name=""
        edid_file="${conn_path}edid"
        if [ -f "$edid_file" ] && [ -s "$edid_file" ]; then
            mon_name=$(python3 - "$edid_file" 2>/dev/null <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read()
found = False
for i in range(4):
    o = 54 + i * 18
    if len(data) > o + 17 and data[o:o+3] == b'\x00\x00\x00' and data[o+3] == 0xfc:
        print(data[o+5:o+18].decode('ascii', 'ignore').strip())
        found = True
        break
if not found:
    print("__NO_DESCRIPTOR__")
PYEOF
)
            if [ "$mon_name" = "__NO_DESCRIPTOR__" ]; then
                mon_name="connected (EDID present, no 0xFC monitor name descriptor)"
            elif [ -z "$mon_name" ]; then
                mon_name="connected (Python3 error reading EDID)"
            fi
        elif [ -f "$edid_file" ]; then
            mon_name="connected (EDID empty – kscreen-doctor not available, no compositor ownership)"
        else
            mon_name="connected (no EDID file in DRM sysfs)"
        fi
        MONITORS="${MONITORS}  - ${conn}: ${mon_name}"$'\n'
    done
    [ -z "$MONITORS" ] && MONITORS="  (no connected monitors detected)"
fi

# NICs (PCI-based)
NICS=$(lspci -mm 2>/dev/null \
    | grep -iE '"(Ethernet|Network|Wireless|Wi-Fi|WLAN|InfiniBand)' \
    | awk -F'"' '{print "  - " $4 ": " $6}')
[ -z "$NICS" ] && NICS="  (none detected via lspci)"

# Sound cards
# PCI: raw lspci audio entries
# ALSA: human-readable card list; HDMI audio endpoints may appear in both – deduplicated below
SOUND_PCI=$(lspci 2>/dev/null | grep -iE "audio|sound" | sed 's/^/  [PCI] /')
SOUND_ALSA=$(aplay -l 2>/dev/null | grep "^card" | sed 's/^/  [ALSA] /')
SOUND=$(printf "%s\n%s" "$SOUND_PCI" "$SOUND_ALSA" \
    | grep -v '^$' \
    | awk '!seen[$0]++')
[ -z "$SOUND" ] && SOUND="  (none detected)"

# Keyboards & mice
# Blacklist: Power Button, Video Bus, PC Speaker, WMI hotkeys,
# Consumer/System Control register kbd handler but are not physical keyboards.
INPUT_KB=$(awk 'BEGIN{RS=""; FS="\n"}
    /Handlers=[^\n]*kbd/ {
        for(i=1;i<=NF;i++) if($i~/^N:/) {
            name=$i
            gsub(/N: Name=|"/,"",name)
            if(name !~ /[Pp]ower [Bb]utton|[Vv]ideo [Bb]us|[Pp][Cc] [Ss]peaker|[Ww][Mm][Ii]|[Cc]onsumer [Cc]ontrol|[Ss]ystem [Cc]ontrol/) {
                print "  - " name
            }
        }
    }' /proc/bus/input/devices 2>/dev/null | sort -u)
[ -z "$INPUT_KB" ] && INPUT_KB="  (none detected)"

INPUT_MOUSE=$(awk 'BEGIN{RS=""; FS="\n"}
    /Handlers=[^\n]*mouse/ {
        for(i=1;i<=NF;i++) if($i~/^N:/) {
            gsub(/N: Name=|"/,"",$i); print "  - " $i
        }
    }' /proc/bus/input/devices 2>/dev/null | sort -u)
[ -z "$INPUT_MOUSE" ] && INPUT_MOUSE="  (none detected)"

# 4. Architecture level validation
# x86-64-v4 requires avx512f + avx512cd + avx512bw + avx512dq + avx512vl (all five).
# Partial AVX-512 (e.g. Alder Lake P-cores) must not incorrectly report v4.
CPU_FLAGS=$(grep "^flags" /proc/cpuinfo | head -n1)
if echo "$CPU_FLAGS" | grep -qw "avx512f"  && \
   echo "$CPU_FLAGS" | grep -qw "avx512cd" && \
   echo "$CPU_FLAGS" | grep -qw "avx512bw" && \
   echo "$CPU_FLAGS" | grep -qw "avx512dq" && \
   echo "$CPU_FLAGS" | grep -qw "avx512vl"; then
    ARCH_LVL="x86-64-v4 (AVX-512: f+cd+bw+dq+vl active)"
elif echo "$CPU_FLAGS" | grep -qw "avx2"; then
    ARCH_LVL="x86-64-v3 (AVX2 active)"
elif echo "$CPU_FLAGS" | grep -qw "sse4_2"; then
    ARCH_LVL="x86-64-v2 (SSE4.2 active)"
else
    ARCH_LVL="x86-64-v1 (baseline)"
fi

# 5. Hierarchical GPU validation (kernel level -> fallback -> FOSS)
GPU_DRV_RAW=$(lspci -k | grep -A 3 -E "VGA|3D" | grep "Kernel driver in use" \
    | awk -F': ' '{print $2}' \
    | grep -v 'snd_hda_intel' \
    | grep -v '^$' \
    | head -n1 \
    | xargs)

# Open-kernel detection: "Open Kernel Module" string present since driver 515+
# Verify string on your system: cat /proc/driver/nvidia/version
if grep -q "Open Kernel Module" /proc/driver/nvidia/version 2>/dev/null; then
    GPU_TYPE="NVIDIA Open-Kernel (proprietary user-space)"
    GPU_VER=$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+" /proc/driver/nvidia/version 2>/dev/null | head -n1)
elif [ -d /proc/driver/nvidia/ ]; then
    GPU_TYPE="NVIDIA proprietary (legacy/closed)"
    GPU_VER=$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+" /proc/driver/nvidia/version 2>/dev/null | head -n1)
    [ -z "$GPU_VER" ] && GPU_VER=$(modinfo -F version nvidia 2>/dev/null)
elif lsmod | grep -q "^nouveau"; then
    GPU_TYPE="Nouveau (open source)"
    GPU_VER="N/A"
elif lsmod | grep -q "^amdgpu"; then
    GPU_TYPE="AMDGPU (open source)"
    GPU_VER=$(modinfo -F version amdgpu 2>/dev/null || echo "N/A")
elif lsmod | grep -q "^i915"; then
    GPU_TYPE="Intel i915 (open source)"
    GPU_VER=$(modinfo -F version i915 2>/dev/null || echo "N/A")
else
    GPU_TYPE="Generic / Other (${GPU_DRV_RAW:-unknown})"
    GPU_VER=$(modinfo -F version "$GPU_DRV_RAW" 2>/dev/null || echo "N/A")
fi

# 6. Repository audit & glibc validation
# pacman-conf --repo-list: parses only active repos, ignores inline comments
# and commented-out repo blocks that grep "^\[" would incorrectly include.
REPOS_ACTIVE=$(pacman-conf --repo-list 2>/dev/null | xargs)
FIRST_REPO=$(echo "$REPOS_ACTIVE" | awk '{print $1}')

GLIBC_VER=$(pacman -Q glibc 2>/dev/null | awk '{print $2}')

# pacman -Qi "From repo" is unreliable on CachyOS (field often absent).
# pacman -Sl per repo is deterministic: first hit = install source, mirrors pacman priority.
GLIBC_REPO="unknown"
for _repo in $REPOS_ACTIVE; do
    if pacman -Sl "$_repo" 2>/dev/null | awk '{print $2}' | grep -qx "glibc"; then
        GLIBC_REPO="$_repo"
        break
    fi
done

if [[ "$FIRST_REPO" == *"cachyos-znver4"* ]]; then
    if [[ "$GLIBC_REPO" == *"cachyos-znver4"* ]]; then
        OPT_STATUS="VERIFIED (CachyOS znver4 baseline active)"
    else
        OPT_STATUS="PARTIAL (cachyos-znver4 repo active, glibc sourced from: ${GLIBC_REPO})"
    fi
elif [[ "$FIRST_REPO" == *"cachyos"* ]]; then
    OPT_STATUS="CachyOS (x86-64-v3 or generic)"
else
    OPT_STATUS="Standard Arch Linux (no CPU-specific optimizations)"
fi

# 7. Software & kernel status
KERNEL_RUN=$(uname -r)
# Regex covers linux-hardened, linux-rt, linux-rt-lts, linux-cachyos-bore, etc.
# Excludes -headers and -firmware packages.
KERNEL_INST=$(pacman -Q 2>/dev/null | grep -E '^linux(-[a-z0-9]+([-][a-z0-9]+)*)? ' \
    | grep -v '\-headers' \
    | grep -v '\-firmware' \
    | awk '{print $1 " v" $2}')
UCODE=$(pacman -Qq 2>/dev/null | grep -E '^(amd|intel)-ucode$' || echo "NOT INSTALLED")

# 8. AUR helper check
if command -v paru >/dev/null 2>&1; then
    AUR_HELP="paru"
    AUR_CMD="paru -Qu"
elif command -v yay >/dev/null 2>&1; then
    AUR_HELP="yay"
    AUR_CMD="yay -Qu"
else
    AUR_HELP="none"
    AUR_CMD=""
fi

# 9. Report generation
{
    printf "######################################################\n"
    printf "             SYSTEM AUDIT: %s\n" "$HOSTNAME_STR"
    printf "             TIMESTAMP: %s\n" "$TIMESTAMP"
    printf "######################################################\n"

    printf "\n[HARDWARE & GRAPHICS]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s\n" "CPU model"             "$CPU_FULL"
    printf "%-30s : %s\n" "Instruction set level" "$ARCH_LVL"
    printf "%-30s : %s\n" "Active driver"         "${GPU_DRV_RAW:-NONE}"
    printf "%-30s : %s\n" "Driver type"           "$GPU_TYPE"
    printf "%-30s : %s\n" "Driver version"        "${GPU_VER:-N/A}"

    printf "\n[HARDWARE DETAILS]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s\n" "Motherboard" "$MAINBOARD"

    printf "\nStorage devices:\n"
    echo "$STORAGE"

    printf "\nMonitors:\n"
    if [ -n "$MONITORS" ]; then
        echo "$MONITORS" | sed 's/^/  /'
    else
        echo "  (no monitor data)"
    fi

    printf "\nNetwork cards (NICs):\n"
    echo "$NICS"

    printf "\nSound cards:\n"
    echo "$SOUND"

    printf "\nKeyboards:\n"
    echo "$INPUT_KB"

    printf "\nMice:\n"
    echo "$INPUT_MOUSE"

    printf "\n[REPOSITORIES & OPTIMIZATION]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s\n" "Optimization status"  "$OPT_STATUS"
    printf "%-30s : %s\n" "Primary repository"   "$FIRST_REPO"
    printf "%-30s : %s\n" "glibc version"        "${GLIBC_VER:-unknown}"
    printf "%-30s : %s\n" "glibc repo"           "$GLIBC_REPO"
    printf "\nActive pacman repositories (priority order):\n"
    echo "$REPOS_ACTIVE" | tr ' ' '\n' | sed 's/^/  - /'

    printf "\n[KERNEL & MICROCODE]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s\n" "Running kernel"   "$KERNEL_RUN"
    printf "%-30s : %s\n" "Microcode status" "$UCODE"
    printf "\nInstalled kernel images:\n"
    if [ -n "$KERNEL_INST" ]; then
        echo "$KERNEL_INST" | sed 's/^/  - /'
    else
        echo "  (no linux packages found via pacman)"
    fi

    printf "\n[STORAGE & FILESYSTEM]\n"
    echo "------------------------------------------------------"
    findmnt -n -o SOURCE,FSTYPE,OPTIONS / \
        | awk '{printf "%-30s : %s (%s)\n", "Root mount", $1, $2}'
    printf "\nCritical partitions (>90%%):\n"
    CRIT=$(df -h | awk 'NR>1 && int($5) >= 90 {print "  ! WARNING: " $6 " is " $5 " full !"}')
    [ -n "$CRIT" ] && echo "$CRIT" || echo "  No critical fill levels."

    printf "\n[PACKAGE MANAGEMENT & AUR]\n"
    echo "------------------------------------------------------"
    if [ "$AUR_HELP" != "none" ]; then
        AUR_UPDATES=$($AUR_CMD 2>/dev/null)
        if [ -z "$AUR_UPDATES" ]; then
            printf "AUR status: consistent (up to date)\n"
        else
            printf "Pending AUR updates:\n%s\n" "$AUR_UPDATES"
        fi

        printf "\nInstalled foreign packages (AUR):\n"
        $AUR_HELP -Qm 2>/dev/null | sed 's/^/  - /' || echo "  (none)"
    else
        printf "AUR helper: none installed (paru/yay not found)\n"
    fi

    printf "\nActive Flatpak runtimes:\n"
    if command -v flatpak >/dev/null 2>&1; then
        flatpak list --columns=name,version 2>/dev/null | sed 's/^/  - /' \
            || echo "  (Flatpak present but no packages or error)"
    else
        echo "  No Flatpaks registered."
    fi

    printf "\n[FULL PACKAGE INVENTORY (PACMAN)]\n"
    echo "------------------------------------------------------"
    pacman -Q 2>/dev/null

} > "$OUTPUT"

if [ -n "$CALLER_USER" ]; then
    chown "${CALLER_USER}":"${CALLER_USER}" "$OUTPUT"
fi

printf "\nAudit complete: %s\n" "$OUTPUT"
