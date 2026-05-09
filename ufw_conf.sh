#!/bin/bash
set -euo pipefail

# ==============================================================================
# UFW Firewall Configuration + NAT Optimization
# Purpose: Gaming, KDE Connect, Printer, Samba, NAT type improvement
# Note: PC is no longer registered as Exposed Host in the router.
#       UFW is the second active protection layer!
#
# CONFIGURATION — adjust before running:
#   ZEROTIER_IFACE : ZeroTier interface name (e.g. zt3jnwgui6 or ztXXXXXXXXXX)
#                    Run: ip link show | grep zt
#   LAN_FALLBACK   : Fallback subnet if auto-detection fails
# ==============================================================================

# --- User-configurable variables ---
# ZEROTIER_IFACE="ztXXXXXXXXXX"   # <-- Replace with your ZeroTier interface name
LAN_FALLBACK="192.168.1.0/24"    # <-- Replace with your LAN subnet if needed

# --- Self-Elevation ---
if [ "$EUID" -ne 0 ]; then
    echo "Insufficient privileges. Requesting root access..."
    exec sudo -- "$0" "$@"
fi

# --- Check prerequisites ---
if ! command -v ufw &>/dev/null; then
    echo "ERROR: ufw is not installed. Aborting." >&2
    exit 1
fi

# --- Detect LAN subnet ---
DEFAULT_IF=$(ip route show default | awk 'NR==1 {print $5}')
if [ -z "$DEFAULT_IF" ]; then
    echo "WARNING: Default interface could not be determined." >&2
    DEFAULT_IF=""
fi
LAN_SUBNET=$(ip route show dev "$DEFAULT_IF" scope link proto kernel 2>/dev/null | awk '{print $1; exit}')
if [ -z "$LAN_SUBNET" ]; then
    echo "WARNING: LAN subnet could not be determined." >&2
    echo "         Fallback: $LAN_FALLBACK" >&2
    LAN_SUBNET="$LAN_FALLBACK"
fi
echo "Detected LAN subnet: $LAN_SUBNET"

# ==============================================================================
# IPv6 hardening
# ==============================================================================
echo "Checking IPv6 configuration..."
UFW_DEFAULT="/etc/default/ufw"
if grep -q "^IPV6=no" "$UFW_DEFAULT"; then
    echo "  WARNING: IPv6 was disabled in UFW - setting to 'yes'."
    sed -i 's/^IPV6=no/IPV6=yes/' "$UFW_DEFAULT"
elif ! grep -q "^IPV6=yes" "$UFW_DEFAULT"; then
    echo "  Adding IPv6=yes..."
    echo "IPV6=yes" >> "$UFW_DEFAULT"
else
    echo "  IPv6 correctly configured."
fi

echo "Root privileges active. Starting UFW reconfiguration..."

# ==============================================================================
# 1. Reset firewall
# ==============================================================================
echo "1. Resetting firewall (deletes all existing rules)..."
ufw --force reset

# ==============================================================================
# 2. Default policies (IPv4 + IPv6)
# ==============================================================================
echo "2. Setting default policies (Deny in / Allow out)..."
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

# ==============================================================================
# 3. ICMP (Ping) — active by default via before.rules
# SSH intentionally omitted: default deny drops port 22 silently (stealth, no RST).
# ==============================================================================
echo "3. ICMP (Ping) active via before.rules - no action required."

# ==============================================================================
# 4. Steam & Gaming base infrastructure
# ==============================================================================
echo "4. Steam & Gaming base infrastructure..."
ufw allow 27015:27050/udp  comment 'Steam: Game Traffic'
ufw allow 27015:27037/tcp  comment 'Steam: Session Handshake'
ufw allow 3478/udp         comment 'Steam/STUN: Voice & NAT Traversal'
ufw allow 3479/udp         comment 'Steam: Secondary STUN'
ufw allow 4379:4380/udp    comment 'Steam: Networking'
ufw allow 27000:27100/udp  comment 'Steam: Server Browser & Discovery'

# ==============================================================================
# 5. Games
# ==============================================================================
echo "5. Games..."

# 5.1 No Man's Sky
# No dedicated port required - runs via Steam + Microsoft PlayFab (HTTPS outbound)
echo "  5.1 No Man's Sky: No extra ports required (Steam + PlayFab/HTTPS)."

# 5.2 Factorio
echo "  5.2 Factorio..."
ufw allow 34197/udp comment 'Factorio: Coop Standard Port'

# 5.3 Elite Dangerous
# P2P connections between players use a fixed configured UDP port.
# Default is 5100, officially supported range: 5100-5200.
# Without this rule all players connect via relay servers,
# causing desync and instancing issues.
echo "  5.3 Elite Dangerous (P2P)..."
ufw allow 5100:5200/udp comment 'Elite Dangerous: P2P Instancing'

# 5.4 Gray Zone Warfare
# Runs via Steam + EAC - no dedicated ports required.
echo "  5.4 Gray Zone Warfare: No extra ports required (Steam + EAC)."

# ==============================================================================
# 6. ZeroTier (VPN overlay network)
# ZeroTier uses UDP hole punching for direct peer connections.
# Port 9993/udp is the fixed main port - must be explicitly opened.
# Outbound connections (to ZeroTier root servers) are already covered
# by 'allow outgoing'.
# ==============================================================================
echo "6. ZeroTier..."
ufw allow 9993/udp comment 'ZeroTier: Peer Discovery & Hole Punching'

# ==============================================================================
# 7. ProtonVPN (WireGuard + OpenVPN)
# Both are outbound connections to ProtonVPN servers:
#   WireGuard : UDP 51820 (outbound - already covered by allow outgoing)
#   OpenVPN   : UDP 1194 / TCP 443 (outbound - already covered)
# No inbound rules required as long as no VPN server is operated.
# ==============================================================================
echo "7. ProtonVPN: No inbound rules required (outbound tunnels only)."

# ==============================================================================
# 8. LAN-only services
# CRITICAL: All following services are LAN-only and must never
# be reachable from the internet as an exposed host!
# ==============================================================================
echo "8. LAN-only services (restricted to $LAN_SUBNET)..."

# KDE Connect
ufw allow from "$LAN_SUBNET" to any port 1714:1764 proto udp comment 'KDE Connect (LAN only)'
ufw allow from "$LAN_SUBNET" to any port 1714:1764 proto tcp comment 'KDE Connect (LAN only)'

# Samba
ufw allow from "$LAN_SUBNET" to any port 445 proto tcp comment 'Samba: SMB direct (LAN only)'
ufw allow from "$LAN_SUBNET" to any port 139 proto tcp comment 'Samba: NetBIOS Session (LAN only)'
ufw allow from "$LAN_SUBNET" to any port 137 proto udp comment 'Samba: NetBIOS Name Resolution (LAN only)'
ufw allow from "$LAN_SUBNET" to any port 138 proto udp comment 'Samba: NetBIOS Datagram (LAN only)'

# Printer
ufw allow from "$LAN_SUBNET" to any port 631  proto tcp comment 'Printer: CUPS (LAN only)'
ufw allow from "$LAN_SUBNET" to any port 5353 proto udp comment 'Printer: mDNS (LAN only)'

# Samba via ZeroTier
# ufw allow in on "$ZEROTIER_IFACE" to any port 445 proto tcp comment 'Samba: SMB direct (ZeroTier)'
# ufw allow in on "$ZEROTIER_IFACE" to any port 139 proto tcp comment 'Samba: NetBIOS Session (ZeroTier)'
# ufw allow in on "$ZEROTIER_IFACE" to any port 137 proto udp comment 'Samba: NetBIOS Name Resolution (ZeroTier)'
# ufw allow in on "$ZEROTIER_IFACE" to any port 138 proto udp comment 'Samba: NetBIOS Datagram (ZeroTier)'

# ==============================================================================
# 9. Console cross-play (Xbox Live / PSN)
# ==============================================================================
echo "9. Console cross-play..."
ufw allow 88/udp   comment 'Xbox Live: Auth'
ufw allow 3074/udp comment 'Xbox Live / CoD: Multiplayer'
ufw allow 3074/tcp comment 'Xbox Live / CoD: Multiplayer'
ufw allow 3658/udp comment 'PSN: Peer-to-Peer'

# ==============================================================================
# 10. Logging & enable firewall
# ==============================================================================
echo "10. Configuring logging and enabling firewall..."
ufw logging low
ufw --force enable

# ==============================================================================
# 11. UFW config files: ensure 644 (readable by KDE Firewall module)
# Note: 640 with group root is functionally equivalent to 600 on a
# single-user desktop and breaks the KDE Plasma Firewall module.
# ==============================================================================
echo "11. Setting UFW config files to 644 (KDE compatibility)..."

UFW_FILES=(
    /etc/ufw/user.rules
    /etc/ufw/user6.rules
    /etc/ufw/before.rules
    /etc/ufw/before6.rules
    /etc/ufw/after.rules
    /etc/ufw/after6.rules
)

for f in "${UFW_FILES[@]}"; do
    if [ -f "$f" ]; then
        chmod 644 "$f"
        echo "  Set: $f"
    else
        echo "  WARNING: File not found: $f"
    fi
done

# ==============================================================================
# 12. Sysctl network optimizations
# ==============================================================================
echo "12. Applying sysctl network optimizations..."

SYSCTL_CONF="/etc/sysctl.d/99-gaming-nat.conf"

cat > "$SYSCTL_CONF" << 'EOF'
# ==============================================================
# Gaming & NAT Traversal Optimizations
# Created by ufw-gaming-setup.sh
# ==============================================================

# Increase UDP buffer sizes
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# Increase connection backlog
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 5000

# Optimize NAT conntrack timeouts for UDP
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 120

# Increase conntrack table size
net.netfilter.nf_conntrack_max = 131072

# TCP optimizations
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
EOF

sysctl --system > /dev/null 2>&1
echo "  Sysctl settings written to: $SYSCTL_CONF"
echo "  Settings active immediately (no reboot required)."

# ==============================================================================
# Status
# ==============================================================================
echo ""
echo "======================================================="
echo "Configuration complete. Current UFW status:"
echo "======================================================="
ufw status verbose

echo ""
echo "======================================================="
echo "  SECURITY STATUS:"
echo "  Protection layers: Router NAT + UFW"
echo "  IPv6:        Active and controlled by UFW"
echo "  SSH:         Stealth (default deny, no RST)"
echo "  LAN-only:    KDE Connect / Samba / CUPS / mDNS"
echo "               restricted to $LAN_SUBNET"
echo "  ZeroTier:    Interface $ZEROTIER_IFACE"
echo "  Rule files:  chmod 644 (KDE Firewall module readable)"
echo "======================================================="
