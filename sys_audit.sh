#!/usr/bin/env bash

# ==============================================================================
# SYSTEM-AUDIT SCRIPT
# ==============================================================================

# 1. Privilege separation & root check
if [ "$EUID" -ne 0 ]; then
    sudo -v || { echo "Error: sudo authentication required."; exit 1; }
    exec sudo bash "$0" "$@"
fi

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

# Storage devices (physical block devices only, no loop devices)
STORAGE=$(lsblk -d -o NAME,SIZE,MODEL,TRAN --noheadings 2>/dev/null \
    | grep -v "^loop" \
    | awk '{printf "  - /dev/%-6s %6s  %-30s [%s]\n", $1, $2, $3, $4}')
[ -z "$STORAGE" ] && STORAGE="  (no block devices detected)"

# Monitors (DRM sysfs + EDID name via Python3)
# Differentiated error output: EDID empty | no 0xFC descriptor | Python error | no EDID file
# Note: NVIDIA only writes EDID data to sysfs when the compositor holds DRM ownership.
#       When run as root outside the Wayland session the file remains empty – not a script bug.
MONITORS=""
for conn_path in /sys/class/drm/card*-*/; do
    [ -f "${conn_path}status" ] || continue
    [ "$(cat "${conn_path}status" 2>/dev/null)" = "connected" ] || continue
    conn=$(basename "$conn_path")
    mon_name=""
    edid_file="${conn_path}edid"
    if [ -f "$edid_file" ] && [ -s "$edid_file" ]; then
        mon_name=$(python3 - "$edid_file" 2>/dev/null <<'EOF'
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
EOF
)
        if [ "$mon_name" = "__NO_DESCRIPTOR__" ]; then
            mon_name="connected (EDID present, no 0xFC monitor descriptor)"
        elif [ -z "$mon_name" ]; then
            mon_name="connected (Python3 error reading EDID)"
        fi
    elif [ -f "$edid_file" ]; then
        mon_name="connected (EDID file empty – no compositor ownership during root execution)"
    else
        mon_name="connected (no EDID file under DRM sysfs)"
    fi
    MONITORS="${MONITORS}  - ${conn}: ${mon_name}\n"
done
[ -z "$MONITORS" ] && MONITORS="  (no connected monitors detected via DRM)"

# NICs (PCI-based)
NICS=$(lspci -mm 2>/dev/null \
    | grep -iE '"(Ethernet|Network|Wireless|Wi-Fi|WLAN|InfiniBand)' \
    | awk -F'"' '{print "  - " $4 ": " $6}')
[ -z "$NICS" ] && NICS="  (none detected via lspci)"

# Sound cards (PCI + USB via ALSA; HDMI audio endpoints appear twice – intended)
SOUND_PCI=$(lspci 2>/dev/null | grep -iE "audio|sound" | sed 's/^/  - /')
SOUND_ALSA=$(aplay -l 2>/dev/null | grep "^card" | sed 's/^/  - /')
SOUND="${SOUND_PCI}${SOUND_ALSA:+
$SOUND_ALSA}"
[ -z "$SOUND" ] && SOUND="  (none detected)"

# Keyboards & mice
# Keyboard blacklist: Power Button, Video Bus, PC Speaker, WMI hotkeys,
# Consumer/System Control all register a kbd handler in the kernel
# but are not input keyboards.
INPUT_KB=$(awk 'BEGIN{RS=""; FS="\n"}
    /Handlers=[^\n]*kbd/ {
        for(i=1;i<=NF;i++) if($i~/^N:/) {
            name=$i
            gsub(/N: Name=|"/,"",name)
            if(name !~ /[Pp]ower [Bb]utton|[Vv]ideo [Bb]us|[Pp][Cc] [Ss]peaker|[Ww][Mm][Ii]|[Cc]onsumer [Cc]ontrol|[Ss]ystem [Cc]ontrol/) {
                print "  - " name
            }
        }
    }' /proc/bus/input/devices 2>/dev/null)
[ -z "$INPUT_KB" ] && INPUT_KB="  (none detected)"

INPUT_MOUSE=$(awk 'BEGIN{RS=""; FS="\n"}
    /Handlers=[^\n]*mouse/ {
        for(i=1;i<=NF;i++) if($i~/^N:/) {
            gsub(/N: Name=|"/,"",$i); print "  - " $i
        }
    }' /proc/bus/input/devices 2>/dev/null)
[ -z "$INPUT_MOUSE" ] && INPUT_MOUSE="  (none detected)"

# 4. Architecture level validation
# x86-64-v4 formally requires avx512f + avx512cd + avx512bw + avx512dq + avx512vl.
# Checking only avx512vl+avx512bw would be incomplete – CPUs with partial AVX-512
# (e.g. Alder Lake P-Cores) would incorrectly report v4.
if grep -q "avx512f"  /proc/cpuinfo && \
   grep -q "avx512cd" /proc/cpuinfo && \
   grep -q "avx512bw" /proc/cpuinfo && \
   grep -q "avx512dq" /proc/cpuinfo && \
   grep -q "avx512vl" /proc/cpuinfo; then
    ARCH_LVL="x86-64-v4 (AVX-512: f+cd+bw+dq+vl active)"
elif grep -q "avx2" /proc/cpuinfo; then
    ARCH_LVL="x86-64-v3 (AVX2 active)"
elif grep -q "sse4_2" /proc/cpuinfo; then
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
REPOS_ACTIVE=$(grep -E "^\[" /etc/pacman.conf | grep -v "\[options\]" | tr -d '[]' | xargs)
FIRST_REPO=$(echo "$REPOS_ACTIVE" | awk '{print $1}')

GLIBC_VER=$(pacman -Q glibc 2>/dev/null | awk '{print $2}')

# pacman -Si returns multiple hits for packages present in several repos without
# a unique Repository header. pacman -Sl <repo> is deterministic: iterates repos
# in priority order and breaks on first match – mirrors pacman's install logic.
GLIBC_REPO="unknown"
for repo in $REPOS_ACTIVE; do
    if pacman -Sl "$repo" 2>/dev/null | grep -q "^${repo} glibc "; then
        GLIBC_REPO="$repo"
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
# Regex covers linux-hardened, linux-rt, linux-rt-lts etc.
# Filters: -headers and -firmware excluded.
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
fi

# 9. Report generation
{
    printf "######################################################\n"
    printf "             SYSTEM AUDIT: %s\n" "$HOSTNAME_STR"
    printf "             TIMESTAMP: %s\n" "$TIMESTAMP"
    printf "######################################################\n"

    printf "\n[HARDWARE & GRAPHICS]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s\n" "CPU model"           "$CPU_FULL"
    printf "%-30s : %s\n" "Instruction set level" "$ARCH_LVL"
    printf "%-30s : %s\n" "Active driver"       "${GPU_DRV_RAW:-NONE}"
    printf "%-30s : %s\n" "Driver type"         "$GPU_TYPE"
    printf "%-30s : %s\n" "Driver version"      "${GPU_VER:-N/A}"

    printf "\n[HARDWARE DETAILS]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s\n" "Motherboard" "$MAINBOARD"

    printf "\nStorage devices:\n"
    echo "$STORAGE"

    printf "\nMonitors:\n"
    printf "%b" "$MONITORS"

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
    printf "%-30s : %s\n" "Running kernel"  "$KERNEL_RUN"
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

if [ -n "$SUDO_USER" ]; then
    chown "${SUDO_USER}":"${SUDO_USER}" "$OUTPUT"
fi

printf "\nAudit complete: %s\n" "$OUTPUT"
