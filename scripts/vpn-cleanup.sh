#!/bin/bash
# Host-side cleanup for leaked WireGuard interfaces and routing rules.
# Run this if the Agent VPN container was killed without graceful shutdown
# and left wg0 / policy routes on the host (breaks OpenVPN, SSH, etc).

set -e

echo "Agent VPN — Host Cleanup"
echo "================================"

FOUND=0

# Remove wg0 interface
if ip link show wg0 >/dev/null 2>&1; then
    echo "[fix] Bringing down wg0 interface..."
    wg-quick down wg0 2>/dev/null || ip link delete wg0 2>/dev/null || true
    FOUND=1
else
    echo "[ok]  No wg0 interface found."
fi

# Remove leaked policy routing rules (WireGuard uses fwmark 0xca6c / table 51820)
if ip rule show | grep -q "lookup 51820"; then
    echo "[fix] Removing policy rule → table 51820..."
    ip rule del lookup 51820 2>/dev/null || true
    FOUND=1
else
    echo "[ok]  No table 51820 policy rule."
fi

if ip rule show | grep -q "suppress_prefixlength 0"; then
    echo "[fix] Removing suppress_prefixlength rule..."
    ip rule del from all lookup main suppress_prefixlength 0 2>/dev/null || true
    FOUND=1
else
    echo "[ok]  No suppress_prefixlength rule."
fi

# Flush routing table 51820
if ip route show table 51820 2>/dev/null | grep -q .; then
    echo "[fix] Flushing routing table 51820..."
    ip route flush table 51820 2>/dev/null || true
    FOUND=1
else
    echo "[ok]  Table 51820 already empty."
fi

echo ""
if [ "$FOUND" -eq 1 ]; then
    echo "Cleanup complete. Verify with:"
    echo "  ip rule show"
    echo "  ip route show table 51820"
    echo "  ip link show type wireguard"
else
    echo "Nothing to clean up — host routing is clean."
fi
