#!/bin/bash
# rename-interfaces.sh - Rename network interfaces to match expected order
# Mount this to /usr/local/bin/rename-interfaces.sh and use as entrypoint
#
# This script ensures eth0 = core_net, eth1 = ext_net regardless of
# Docker's random interface ordering.

set -e

# Define expected interface-to-IP mapping
# Format: EXPECTED_INTERFACE_NAME=IP_ADDRESS
# Customize these for each container type

# For UPF:
INTERFACE_MAP=(
    "eth0=192.168.61.160"    # core_net should be eth0
    "eth1=192.168.72.160"    # ext_net should be eth1
)

# Override from environment if provided
[ -n "$ETH0_IP" ] && INTERFACE_MAP[0]="eth0=$ETH0_IP"
[ -n "$ETH1_IP" ] && INTERFACE_MAP[1]="eth1=$ETH1_IP"

echo "=== Interface Renaming Script ==="
echo "Current interfaces:"
ip -o addr show | grep -E "eth[0-9]" | awk '{print "  " $2 ": " $4}'

# Build a map of current IP -> interface
declare -A IP_TO_IFACE
for iface in $(ip -o link show | grep -oP 'eth\d+' | sort -u); do
    ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "")
    if [ -n "$ip" ]; then
        IP_TO_IFACE["$ip"]="$iface"
        echo "  Found: $iface has IP $ip"
    fi
done

echo ""
echo "Renaming interfaces..."

# Track which interfaces need renaming
declare -A RENAME_MAP

for mapping in "${INTERFACE_MAP[@]}"; do
    target_iface="${mapping%%=*}"
    target_ip="${mapping#*=}"
    
    current_iface="${IP_TO_IFACE[$target_ip]}"
    
    if [ -z "$current_iface" ]; then
        echo "  WARNING: No interface found with IP $target_ip (expected for $target_iface)"
        continue
    fi
    
    if [ "$current_iface" = "$target_iface" ]; then
        echo "  ✓ $target_iface already has correct IP $target_ip"
        continue
    fi
    
    RENAME_MAP["$current_iface"]="$target_iface"
    echo "  Will rename: $current_iface ($target_ip) → $target_iface"
done

# Perform renames using temporary names to avoid conflicts
# (e.g., if eth0 needs to become eth1 and eth1 needs to become eth0)

# Step 1: Rename all to temporary names
TMP_SUFFIX="_tmp"
for current_iface in "${!RENAME_MAP[@]}"; do
    tmp_name="${current_iface}${TMP_SUFFIX}"
    echo "  Step 1: $current_iface → $tmp_name"
    ip link set "$current_iface" down 2>/dev/null || true
    ip link set "$current_iface" name "$tmp_name"
done

# Step 2: Rename from temporary to final names
for current_iface in "${!RENAME_MAP[@]}"; do
    tmp_name="${current_iface}${TMP_SUFFIX}"
    target_iface="${RENAME_MAP[$current_iface]}"
    echo "  Step 2: $tmp_name → $target_iface"
    ip link set "$tmp_name" name "$target_iface"
    ip link set "$target_iface" up
done

echo ""
echo "Final interface configuration:"
ip -o addr show | grep -E "eth[0-9]" | awk '{print "  " $2 ": " $4}'

echo ""
echo "=== Interface renaming complete ==="
echo ""

# Execute the main command
exec "$@"