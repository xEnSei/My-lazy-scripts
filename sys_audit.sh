#!/usr/bin/env bash

# ==============================================================================
# SYSTEM-AUDIT SCRIPT
# ==============================================================================

# 0. Error handling & cleanup
trap '[ -n "$MONITOR_TMPFILE" ] && rm -f "$MONITOR_TMPFILE" 2>/dev/null
      [ -n "$AUR_TMPFILE" ]     && rm -f "$AUR_TMPFILE"     2>/dev/null' EXIT
trap 'echo "Fehler: Skript unterbrochen"; exit 130' INT TERM

# 1. Privilege separation & root check
SCRIPT_PATH=$(realpath "$0")

# User-session data must be collected BEFORE sudo relaunch.
# kscreen-doctor and AUR helpers require an active user session.
MONITOR_TMPFILE=$(mktemp /tmp/sys_audit_monitors.XXXXXX)
AUR_TMPFILE=$(mktemp /tmp/sys_audit_aur.XXXXXX)

if [ "$EUID" -ne 0 ]; then
    # --- Monitor-Daten sammeln (Wayland/DBus User-Session) ---
    if command -v kscreen-doctor >/dev/null 2>&1; then
        _wd="${WAYLAND_DISPLAY:-}"
        if [ -z "$_wd" ]; then
            for _sock in wayland-0 wayland-1; do
                [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$_sock" ] && _wd="$_sock" && break
            done
        fi
        if [ -n "$_wd" ]; then
            WAYLAND_DISPLAY="$_wd" kscreen-doctor -o 2>/dev/null \
                | sed 's/\x1b\[[0-9;]*m//g' \
                > "$MONITOR_TMPFILE"
        fi
    fi

    # --- AUR-Daten sammeln (paru/yay nicht als root lauffähig) ---
    _aur_help=""
    if command -v paru >/dev/null 2>&1; then
        _aur_help="paru"
    elif command -v yay >/dev/null 2>&1; then
        _aur_help="yay"
    fi

    if [ -n "$_aur_help" ]; then
        {
            printf "HELPER=%s\n" "$_aur_help"
            printf "UPDATES_START\n"
            $_aur_help -Qu 2>/dev/null || true
            printf "UPDATES_END\n"
            printf "FOREIGN_START\n"
            $_aur_help -Qm 2>/dev/null || true
            printf "FOREIGN_END\n"
        } > "$AUR_TMPFILE"
    else
        printf "HELPER=none\n" > "$AUR_TMPFILE"
    fi

    sudo -v || { echo "Error: sudo authentication required."; exit 1; }
    exec sudo /usr/bin/env bash "$SCRIPT_PATH" \
        --monitor-tmpfile "$MONITOR_TMPFILE" \
        --aur-tmpfile "$AUR_TMPFILE" \
        "$@"
fi

# Parse arguments passed from user-space invocation
MONITOR_TMPFILE=""
AUR_TMPFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --monitor-tmpfile) MONITOR_TMPFILE="$2"; shift 2 ;;
        --aur-tmpfile)     AUR_TMPFILE="$2";     shift 2 ;;
        *) shift ;;
    esac
done

CALLER_USER="${SUDO_USER:-$USER}"

# ==============================================================================
# 2. Metadata & dynamic naming
# ==============================================================================
DISTRO_ID=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "unknown")
DATE_TAG=$(date "+%Y_%m_%d")
TIME_TAG=$(date "+%H%M")
OUTPUT="${DISTRO_ID}_${DATE_TAG}_${TIME_TAG}.txt"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
HOSTNAME_STR=$(hostname)

# ==============================================================================
# 3. CPU
# ==============================================================================
CPU_FULL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -n1 | cut -d':' -f2 | xargs || echo "unknown")
CPU_CORES_PHYS=$(grep "cpu cores" /proc/cpuinfo 2>/dev/null | head -n1 | awk -F': ' '{print $2}' || echo "?")
CPU_THREADS=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "?")

CPU_FLAGS=$(grep "^flags" /proc/cpuinfo 2>/dev/null | head -n1)
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

# ==============================================================================
# 4. RAM
# ==============================================================================
RAM_TOTAL=$(awk '/^MemTotal:/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "unknown")
RAM_AVAIL=$(awk '/^MemAvailable:/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "unknown")

# DMI: Slot-Belegung, Takt, Kapazität pro DIMM
RAM_DIMMS=$(dmidecode -t memory 2>/dev/null \
    | awk '
        /^Memory Device$/ { in_dev=1; size=""; speed=""; type=""; loc="" }
        in_dev && /^\tSize:/ {
            if ($2 == "No") next   # "No Module Installed"
            size=$2" "$3
        }
        in_dev && /^\tConfigured Memory Speed:/ { speed=$4" "$5 }
        in_dev && /^\tType:/ && !/Type Detail/ { type=$2 }
        in_dev && /^\tLocator:/ && !/Bank/ { loc=$2 }
        in_dev && /^$/ {
            if (size != "") printf "  - %-12s %s  %s  %s\n", loc, size, type, speed
            in_dev=0
        }
    ' || echo "  (dmidecode unavailable)")
[ -z "$RAM_DIMMS" ] && RAM_DIMMS="  (no DIMM data)"

# EXPO/XMP: Überprüfung ob OC-Profil aktiv ist via DMI Configured Speed vs Max Speed
RAM_XMP=$(dmidecode -t memory 2>/dev/null \
    | awk '
        /^Memory Device$/ { max=""; cfg="" }
        /^\tSpeed:/ && !/Configured/ { max=$2 }
        /^\tConfigured Memory Speed:/ { cfg=$4 }
        /^$/ {
            if (max != "" && cfg != "" && cfg > max) {
                print "  EXPO/XMP active: Configured " cfg " MT/s > Rated " max " MT/s"
            }
        }
    ' | head -n1)
[ -z "$RAM_XMP" ] && RAM_XMP="  EXPO/XMP: not detected (running at rated speed or dmidecode insufficient)"

# ==============================================================================
# 5. GPU
# ==============================================================================
GPU_MODELS=$(/usr/bin/lspci 2>/dev/null | grep -E "VGA|3D Controller" | sed 's/^.*: //')
[ -z "$GPU_MODELS" ] && GPU_MODELS="(none detected)"

GPU_DRV_RAW=$(/usr/bin/lspci -k 2>/dev/null \
    | awk '/VGA|3D Controller/{found=1} found && /Kernel driver in use:/{print $NF; found=0}' \
    | head -n1 | xargs || echo "")

GPU_TYPE="Unknown"
GPU_VER="N/A"
GPU_VRAM="unknown"

if grep -q "Open Kernel Module" /proc/driver/nvidia/version 2>/dev/null; then
    GPU_TYPE="NVIDIA Open-Kernel (proprietary user-space)"
    GPU_VER=$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+" /proc/driver/nvidia/version 2>/dev/null | head -n1 || echo "N/A")
    # VRAM aus nvidia-smi (zuverlässiger als /proc)
    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            | awk '{printf "%.0f MiB", $1}' | head -n1 || echo "unknown")
    fi
elif [ -d /proc/driver/nvidia/ ]; then
    GPU_TYPE="NVIDIA proprietary (legacy/closed)"
    GPU_VER=$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+" /proc/driver/nvidia/version 2>/dev/null | head -n1)
    [ -z "$GPU_VER" ] && GPU_VER=$(modinfo -F version nvidia 2>/dev/null || echo "N/A")
    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            | awk '{printf "%.0f MiB", $1}' | head -n1 || echo "unknown")
    fi
elif lsmod 2>/dev/null | grep -q "^nouveau"; then
    GPU_TYPE="Nouveau (open source)"
    GPU_VER="N/A"
elif lsmod 2>/dev/null | grep -q "^amdgpu"; then
    GPU_TYPE="AMDGPU (open source)"
    # modinfo -F version liefert Kernel-Version, nicht AMDGPU-Treiberversion.
    # Mesa ist die relevante Userspace-Komponente (entspricht funktional dem NVIDIA-Treiberpaket).
    GPU_VER=$(pacman -Q mesa 2>/dev/null | awk '{print "mesa " $2}' || echo "N/A")
    # VRAM aus sysfs — Glob über alle DRM-Cards, erste AMDGPU-Card nehmen
    _vram_path=$(grep -rl "amdgpu" /sys/class/drm/card*/device/driver/module/drivers 2>/dev/null \
        | head -n1 | sed 's|/driver/module/drivers.*||')
    # Fallback: erstes card*-Verzeichnis mit mem_info_vram_total
    if [ -z "$_vram_path" ]; then
        _vram_path=$(ls /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null \
            | head -n1 | sed 's|/mem_info_vram_total||')
    fi
    if [ -n "$_vram_path" ] && [ -f "${_vram_path}/mem_info_vram_total" ]; then
        GPU_VRAM=$(awk '{printf "%.0f MiB", $1/1024/1024}' \
            "${_vram_path}/mem_info_vram_total" 2>/dev/null || echo "unknown")
    fi
elif lsmod 2>/dev/null | grep -q "^i915"; then
    GPU_TYPE="Intel i915 (open source)"
    GPU_VER=$(pacman -Q mesa 2>/dev/null | awk '{print "mesa " $2}' || echo "N/A")
else
    GPU_TYPE="Generic / Other (${GPU_DRV_RAW:-unknown})"
    [ -n "$GPU_DRV_RAW" ] && GPU_VER=$(modinfo -F version "$GPU_DRV_RAW" 2>/dev/null || echo "N/A")
fi

# ==============================================================================
# 6. Motherboard & Storage
# ==============================================================================
MB_VENDOR=$(cat /sys/class/dmi/id/board_vendor  2>/dev/null | xargs || echo "unknown")
MB_NAME=$(cat   /sys/class/dmi/id/board_name    2>/dev/null | xargs || echo "unknown")
MB_VER=$(cat    /sys/class/dmi/id/board_version 2>/dev/null | xargs)
MAINBOARD="${MB_VENDOR} ${MB_NAME}${MB_VER:+ (${MB_VER})}"

STORAGE=$(/usr/bin/lsblk -d -o NAME,SIZE,MODEL,TRAN --noheadings 2>/dev/null \
    | grep -vE "^(loop|zram)" \
    | awk '{printf "  - /dev/%-10s %7s  %-30s [%s]\n", $1, $2, $3, $4}')
[ -z "$STORAGE" ] && STORAGE="  (no block devices detected)"

# SMART-Status (nur physische Disks, kein loop/zram/nvme-partitionen)
SMART_STATUS=""
while IFS= read -r line; do
    dev=$(echo "$line" | awk '{print $1}')
    [ -b "/dev/$dev" ] || continue
    result=$(smartctl -H "/dev/$dev" 2>/dev/null \
        | awk '/overall-health|SMART overall/{
            if (/PASSED|OK/) print "PASSED"
            else if (/FAILED/) print "FAILED"
        }')
    [ -z "$result" ] && result="N/A (NVMe/unsupported)"
    SMART_STATUS="${SMART_STATUS}  - /dev/${dev}: ${result}\n"
done < <(/usr/bin/lsblk -d -o NAME,TRAN --noheadings 2>/dev/null | grep -vE "^(loop|zram)")
[ -z "$SMART_STATUS" ] && SMART_STATUS="  (no devices checked)"

# ==============================================================================
# 7. Monitors (Plasma 6 kscreen-doctor Parser)
# ==============================================================================
MONITORS=""
if [ -n "$MONITOR_TMPFILE" ] && [ -s "$MONITOR_TMPFILE" ]; then
    MONITORS=$(awk '
    /^Output:/ {
        if (connector != "") {
            printf "  Output: %-6s  %-12s @ %-10s  HDR: %-10s  VRR: %s\n",
                connector, geometry, refresh, hdr, vrr
        }
        connector = $3
        geometry = ""; refresh = ""; hdr = "N/A"; vrr = "N/A"
        next
    }
    /^\tGeometry:/ {
        # "Geometry: X,Y WxH" — nur WxH (Feld 3 nach split auf Leerzeichen)
        n = split($0, a, " ")
        geometry = a[n]
        next
    }
    /^\tModes:/ {
        # Aktiver Mode hat "*" (aktuell laufend)
        if (match($0, /[0-9]+x[0-9]+@([0-9.]+)\*/, m)) {
            split(m[0], b, "@")
            refresh = b[2]
            gsub(/[*!]/, "", refresh)
            refresh = refresh " Hz"
        }
        next
    }
    /^\tHDR:/ { hdr = $2; next }
    /^\tVrr:/ { vrr = $2; next }
    END {
        if (connector != "") {
            printf "  Output: %-6s  %-12s @ %-10s  HDR: %-10s  VRR: %s\n",
                connector, geometry, refresh, hdr, vrr
        }
    }
    ' "$MONITOR_TMPFILE")
fi

if [ -z "$MONITORS" ]; then
    MONITORS="  (Monitor info from kscreen-doctor unavailable)"
    shopt -s nullglob
    for conn_path in /sys/class/drm/card*-*/; do
        [ -f "${conn_path}status" ] || continue
        [ "$(cat "${conn_path}status" 2>/dev/null)" = "connected" ] || continue
        conn=$(basename "$conn_path")
        MONITORS="${MONITORS}"$'\n'"  - ${conn}: (DRM fallback; run kscreen-doctor from user session)"
    done
    shopt -u nullglob
fi
[ -z "$MONITORS" ] && MONITORS="  (no connected monitors detected)"

# ==============================================================================
# 8. NICs & Netzwerk (IPs und MACs geschwärzt für öffentliche Logs)
# ==============================================================================
NICS=$(/usr/bin/lspci -mm 2>/dev/null \
    | grep -iE '"(Ethernet|Network|Wireless|Wi-Fi|WLAN|InfiniBand)' \
    | awk -F'"' '{print "  - " $4 ": " $6}')
[ -z "$NICS" ] && NICS="  (none detected via lspci)"

# Aktive Interfaces: Name, Status, Typ — IPs, MACs und ZeroTier-Namen geschwärzt.
# ZeroTier Interface-Namen sind aus der Network-ID abgeleitet und gelten als sensitiv.
NET_INTERFACES=$(ip -o link show 2>/dev/null \
    | grep -v "^[0-9]*: lo:" \
    | awk '{
        iface = $2; gsub(/:/, "", iface)
        state = "DOWN"
        if ($0 ~ /state UP/) state = "UP"
        type = "ethernet"
        if (iface ~ /^wl/)           type = "wifi"
        if (iface ~ /^zt/)         { type = "zerotier"; iface = "[redacted]" }
        if (iface ~ /^tun|^wg/)      type = "vpn"
        if (iface ~ /^br-|^virbr/)  { type = "bridge";    iface = "[redacted]" }
        if (iface ~ /^br$/)           type = "bridge"
        if (iface ~ /^docker|^veth/)  type = "container"
        printf "  - %-18s [%s]  state: %s\n", iface, type, state
    }')
[ -z "$NET_INTERFACES" ] && NET_INTERFACES="  (none detected)"

# DNS-Server: resolvectl liefert die tatsächlichen Upstream-Server pro Interface.
# /etc/resolv.conf zeigt bei systemd-resolved nur 127.0.0.53 (Stub) — nicht auditrelevant.
DNS_SERVERS=""
if command -v resolvectl >/dev/null 2>&1; then
    DNS_SERVERS=$(resolvectl status 2>/dev/null \
        | awk '
            /^Link [0-9]+ \(/ {
                iface = $0; gsub(/.*\(|\).*/, "", iface)
            }
            /Current DNS Server:|DNS Servers:/ {
                for (i=NF; i>=1; i--) {
                    if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^[0-9a-fA-F:]+:[0-9a-fA-F:]+$/) {
                        printf "  - %-10s %s\n", iface ":", $i
                    }
                }
            }
        ' | sort -u)
fi
# Fallback: resolv.conf (nur wenn resolvectl nicht verfügbar oder leer)
if [ -z "$DNS_SERVERS" ]; then
    DNS_SERVERS=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null \
        | grep -v "127.0.0.53" \
        | awk '{print "  - " $2}')
fi
[ -z "$DNS_SERVERS" ] && DNS_SERVERS="  (none configured or systemd-resolved stub only)"

# ==============================================================================
# 9. Sound
# ==============================================================================
SOUND=$(/usr/bin/lspci 2>/dev/null | grep -iE "Audio device" | sed 's/^/  [PCI] /')
[ -z "$SOUND" ] && SOUND="  (none detected)"

# ==============================================================================
# 10. Input devices
# ==============================================================================
INPUT_KB=$(awk 'BEGIN{RS=""; FS="\n"}
    /Handlers=[^\n]*kbd/ {
        for(i=1;i<=NF;i++) if($i~/^N:/) {
            name=$i
            gsub(/N: Name=|"/,"",name)
            if(name !~ /[Pp]ower [Bb]utton|[Vv]ideo [Bb]us|[Pp][Cc] [Ss]peaker|[Ww][Mm][Ii]|[Cc]onsumer [Cc]ontrol|[Ss]ystem [Cc]ontrol/) {
                print "  - " name
            }
        }
    }' /proc/bus/input/devices 2>/dev/null | sort -u || true)
[ -z "$INPUT_KB" ] && INPUT_KB="  (none detected)"

INPUT_MOUSE=$(awk 'BEGIN{RS=""; FS="\n"}
    /Handlers=[^\n]*mouse/ {
        for(i=1;i<=NF;i++) if($i~/^N:/) {
            gsub(/N: Name=|"/,"",$i); print "  - " $i
        }
    }' /proc/bus/input/devices 2>/dev/null | sort -u || true)
[ -z "$INPUT_MOUSE" ] && INPUT_MOUSE="  (none detected)"

# ==============================================================================
# 11. Swap
# ==============================================================================
SWAP_INFO=$(swapon --show=NAME,TYPE,SIZE,USED --noheadings 2>/dev/null \
    | awk '{printf "  - %-20s type: %-10s size: %-8s used: %s\n", $1, $2, $3, $4}')
if [ -z "$SWAP_INFO" ]; then
    # zram-generator erzeugt ggf. swap der in swapon noch nicht sichtbar ist beim ersten Boot
    SWAP_INFO="  (no active swap)"
fi
SWAP_TOTAL=$(awk '/^SwapTotal:/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0")
SWAP_FREE=$(awk  '/^SwapFree:/  {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0")

# ==============================================================================
# 12. Repository audit & glibc validation
# ==============================================================================
REPOS_ACTIVE=$(pacman-conf --repo-list 2>/dev/null | xargs || echo "unknown")
FIRST_REPO=$(echo "$REPOS_ACTIVE" | awk '{print $1}')

GLIBC_VER=$(pacman -Q glibc 2>/dev/null | awk '{print $2}' || echo "unknown")

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

# ==============================================================================
# 13. Kernel & Microcode
# ==============================================================================
KERNEL_RUN=$(uname -r)
KERNEL_PARAMS=$(cat /proc/cmdline 2>/dev/null || echo "(unavailable)")
KERNEL_INST=$(pacman -Q 2>/dev/null | grep -E '^linux(-[a-z0-9]+([-][a-z0-9]+)*)? ' \
    | grep -v '\-headers' \
    | grep -v '\-firmware' \
    | awk '{print $1 " v" $2}' || echo "")
UCODE=$(pacman -Qq 2>/dev/null | grep -E '^(amd|intel)-ucode$' || echo "NOT INSTALLED")

# ==============================================================================
# 14. Disk-Nutzung (alle Mounts, nicht nur kritische)
# ==============================================================================
DISK_USAGE=$(df -h --output=source,fstype,size,used,avail,pcent,target 2>/dev/null \
    | grep -vE "^(tmpfs|devtmpfs|efivarfs|Filesystem|overlay|udev)" \
    | awk 'NR==1{printf "  %-30s %-8s %6s %6s %6s %5s  %s\n",$1,$2,$3,$4,$5,$6,$7; next}
           {printf "  %-30s %-8s %6s %6s %6s %5s  %s\n",$1,$2,$3,$4,$5,$6,$7}')
[ -z "$DISK_USAGE" ] && DISK_USAGE="  (df failed)"

CRIT=$(df -h 2>/dev/null | awk 'NR>1 && int($5) >= 90 {print "  ! WARNING: " $6 " is " $5 " full !"}' || echo "")
[ -z "$CRIT" ] && CRIT="  No critical fill levels (>=90%)."

# ==============================================================================
# 15. Systemd failed units
# ==============================================================================
FAILED_UNITS=$(systemctl --failed --no-legend --plain 2>/dev/null \
    | awk '{print "  ! " $1 " (" $2 ")"}')
[ -z "$FAILED_UNITS" ] && FAILED_UNITS="  No failed units."

# ==============================================================================
# 16. Proton / Steam (installierte Versionen)
# ==============================================================================
PROTON_VERS=""

# Home-Verzeichnis des aufrufenden Users bestimmen
CALLER_HOME=$(getent passwd "$CALLER_USER" 2>/dev/null | cut -d: -f6)

# Steam-Root ermitteln (symlink ~/.steam/steam zeigt auf ~/.local/share/Steam)
_steam_root=""
for _candidate in \
    "${CALLER_HOME}/.local/share/Steam" \
    "${CALLER_HOME}/.steam/steam"; do
    [ -d "$_candidate/steamapps" ] && _steam_root="$_candidate" && break
done

if [ -n "$_steam_root" ]; then
    # Offizielle Valve Proton-Versionen: nur "Proton X.Y" Pattern (nicht BattlEye/Hotfix/Next)
    while IFS= read -r -d '' _pdir; do
        _pname=$(basename "$_pdir")
        [[ "$_pname" =~ ^Proton\ [0-9] ]] || continue
        PROTON_VERS="${PROTON_VERS}  - [Steam] ${_pname}\n"
    done < <(find "$_steam_root/steamapps/common" -maxdepth 1 -type d -print0 2>/dev/null)

    # GE-Proton und andere Custom-Tools aus compatibilitytools.d
    _compat_dir="$_steam_root/compatibilitytools.d"
    if [ -d "$_compat_dir" ]; then
        while IFS= read -r -d '' _tdir; do
            _tname=$(basename "$_tdir")
            PROTON_VERS="${PROTON_VERS}  - [compat] ${_tname}\n"
        done < <(find "$_compat_dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
    fi
fi

# System-seitig installierte Proton/Wine-Pakete via pacman.
# Explizit ausgeschlossen: protonplus, protonup-qt, protontricks (Tools, keine Runtimes)
SYS_PROTON=$(pacman -Q 2>/dev/null \
    | grep -iE "^(proton-|wine-cachyos|wine-staging|wine-tkg)" \
    | grep -viE "^(protonplus|protonup|protontricks)" \
    | awk '{print "  - [pacman] " $1 " " $2}')
[ -n "$SYS_PROTON" ] && PROTON_VERS="${PROTON_VERS}${SYS_PROTON}\n"

[ -z "$PROTON_VERS" ] && PROTON_VERS="  (none found)"

# ==============================================================================
# 17. AUR data (aus User-Tmpfile)
# ==============================================================================
AUR_HELP="none"
AUR_UPDATES=""
AUR_FOREIGN=""

if [ -n "$AUR_TMPFILE" ] && [ -s "$AUR_TMPFILE" ]; then
    AUR_HELP=$(grep "^HELPER=" "$AUR_TMPFILE" | cut -d'=' -f2)
    if [ "$AUR_HELP" != "none" ]; then
        AUR_UPDATES=$(sed -n '/^UPDATES_START$/,/^UPDATES_END$/p' "$AUR_TMPFILE" \
            | grep -v "^UPDATES_")
        AUR_FOREIGN=$(sed -n '/^FOREIGN_START$/,/^FOREIGN_END$/p' "$AUR_TMPFILE" \
            | grep -v "^FOREIGN_")
    fi
fi

# ==============================================================================
# 18. Report generation
# ==============================================================================
{
    printf "######################################################\n"
    printf "             SYSTEM AUDIT: %s\n" "$HOSTNAME_STR"
    printf "             TIMESTAMP: %s\n" "$TIMESTAMP"
    printf "######################################################\n"

    # ------------------------------------------------------------------
    printf "\n[HARDWARE & GRAPHICS]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s (%s cores / %s threads)\n" "CPU model" "$CPU_FULL" "$CPU_CORES_PHYS" "$CPU_THREADS"
    printf "%-30s : %s\n" "Instruction set level" "$ARCH_LVL"
    printf "%-30s : %s\n" "GPU model"             "$GPU_MODELS"
    printf "%-30s : %s\n" "Active driver"         "${GPU_DRV_RAW:-NONE}"
    printf "%-30s : %s\n" "Driver type"           "$GPU_TYPE"
    printf "%-30s : %s\n" "Driver version"        "${GPU_VER:-N/A}"
    printf "%-30s : %s\n" "GPU VRAM"              "$GPU_VRAM"

    # ------------------------------------------------------------------
    printf "\n[MEMORY]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s  (available: %s)\n" "RAM total" "$RAM_TOTAL" "$RAM_AVAIL"
    printf "\nDIMM slots:\n"
    echo "$RAM_DIMMS"
    printf "\n%s\n" "$RAM_XMP"

    printf "\nSwap:\n"
    printf "  Total: %s  Free: %s\n" "$SWAP_TOTAL" "$SWAP_FREE"
    echo "$SWAP_INFO"

    # ------------------------------------------------------------------
    printf "\n[HARDWARE DETAILS]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s\n" "Motherboard" "$MAINBOARD"

    printf "\nStorage devices:\n"
    echo "$STORAGE"

    printf "\nSMART health:\n"
    printf "%b" "$SMART_STATUS"

    printf "\nMonitors:\n"
    echo "$MONITORS"

    printf "\nNetwork cards (NICs):\n"
    echo "$NICS"

    printf "\nActive interfaces (IPs/MACs/sensitive names redacted):\n"
    echo "$NET_INTERFACES"

    printf "\nSound cards:\n"
    echo "$SOUND"

    printf "\nKeyboards:\n"
    echo "$INPUT_KB"

    printf "\nMice:\n"
    echo "$INPUT_MOUSE"

    # ------------------------------------------------------------------
    printf "\n[REPOSITORIES & OPTIMIZATION]\n"
    echo "------------------------------------------------------"
    printf "%-30s : %s\n" "Optimization status"  "$OPT_STATUS"
    printf "%-30s : %s\n" "Primary repository"   "$FIRST_REPO"
    printf "%-30s : %s\n" "glibc version"        "${GLIBC_VER:-unknown}"
    printf "%-30s : %s\n" "glibc repo"           "$GLIBC_REPO"
    printf "\nActive pacman repositories (priority order):\n"
    echo "$REPOS_ACTIVE" | tr ' ' '\n' | sed 's/^/  - /'

    # ------------------------------------------------------------------
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
    printf "\nKernel parameters:\n  %s\n" "$KERNEL_PARAMS"

    # ------------------------------------------------------------------
    printf "\n[STORAGE & FILESYSTEM]\n"
    echo "------------------------------------------------------"
    findmnt -n -o SOURCE,FSTYPE,OPTIONS / 2>/dev/null \
        | awk '{printf "%-30s : %s (%s)\n", "Root mount", $1, $2}' || \
        printf "%-30s : %s\n" "Root mount" "(unable to determine)"

    printf "\nDisk usage (all mounts):\n"
    echo "$DISK_USAGE"

    printf "\nCritical partitions (>=90%%):\n"
    echo "$CRIT"

    # ------------------------------------------------------------------
    printf "\n[SYSTEMD]\n"
    echo "------------------------------------------------------"
    printf "Failed units:\n"
    echo "$FAILED_UNITS"

    # ------------------------------------------------------------------
    printf "\n[NETWORK]\n"
    echo "------------------------------------------------------"
    printf "Note: IPs and MAC addresses redacted for public log sharing.\n"
    printf "\nDNS servers (upstream, via resolvectl):\n"
    echo "$DNS_SERVERS"

    # ------------------------------------------------------------------
    printf "\n[PROTON & WINE]\n"
    echo "------------------------------------------------------"
    printf "%b" "$PROTON_VERS"

    # ------------------------------------------------------------------
    printf "\n[PACKAGE MANAGEMENT & AUR]\n"
    echo "------------------------------------------------------"
    if [ "$AUR_HELP" != "none" ]; then
        if [ -z "$AUR_UPDATES" ]; then
            printf "AUR status: consistent (up to date)\n"
        else
            printf "Pending AUR updates:\n%s\n" "$AUR_UPDATES"
        fi
        printf "\nInstalled foreign packages (AUR):\n"
        if [ -n "$AUR_FOREIGN" ]; then
            echo "$AUR_FOREIGN" | sed 's/^/  - /'
        else
            echo "  (none)"
        fi
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

    # ------------------------------------------------------------------
    printf "\n[FULL PACKAGE INVENTORY (PACMAN)]\n"
    echo "------------------------------------------------------"
    pacman -Q 2>/dev/null || echo "  (pacman not available or error)"

} > "$OUTPUT"

if [ $? -ne 0 ]; then
    echo "Error: Fehler beim Schreiben der Ausgabedatei: $OUTPUT" >&2
    exit 1
fi

if [ -n "$CALLER_USER" ] && id "$CALLER_USER" >/dev/null 2>&1; then
    chown "${CALLER_USER}:${CALLER_USER}" "$OUTPUT" 2>/dev/null || true
fi

printf "\nAudit complete: %s\n" "$OUTPUT"
