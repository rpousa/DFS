#!/bin/bash
# Detect which interface has which IP and update config

CONFIG_FILE="${1:-/openair-upf/etc/config.yaml}"

# Define expected IPs
CORE_IP="${CORE_NET_IP:-192.168.61.160}"
EXT_IP="${EXT_NET_IP:-192.168.72.160}"

# Find interfaces
CORE_IF=$(ip -o addr show | grep "${CORE_IP}" | awk '{print $2}' | head -1)
EXT_IF=$(ip -o addr show | grep "${EXT_IP}" | awk '{print $2}' | head -1)

echo "Detected interfaces:"
echo "  Core network (${CORE_IP}): ${CORE_IF:-NOT FOUND}"
echo "  Ext network (${EXT_IP}): ${EXT_IF:-NOT FOUND}"

# Update config if interface_name is used
if [ -n "$CORE_IF" ] && [ -n "$EXT_IF" ]; then
    # Replace interface names in config
    sed -i "s/interface_name: eth0/interface_name: ${CORE_IF}/g" "$CONFIG_FILE"
    sed -i "s/interface_name: eth1/interface_name: ${EXT_IF}/g" "$CONFIG_FILE"
    echo "Updated config with correct interface names"
fi

exec "$@"