#!/bin/bash
# rename-interfaces.sh - Rename network interfaces to match expected order
# Mount this to /usr/local/bin/rename-interfaces.sh and use as entrypoint
#
# This script ensures eth0 = core_net, eth1 = ext_net regardless of
# Docker's random interface ordering.

set -e

# ---- Build INTERFACE_MAP from ETH<N>_IP env vars (any count) ----
INTERFACE_MAP=()
i=0
while true; do
    var="ETH${i}_IP"
    ip_val="${!var:-}"
    [ -z "$ip_val" ] && break
    INTERFACE_MAP+=("eth${i}=${ip_val}")
    i=$((i+1))
done

# Fallback defaults for UPF if nothing was passed
if [ ${#INTERFACE_MAP[@]} -eq 0 ]; then
    INTERFACE_MAP=(
        "eth0=192.168.71.134"    # core_net should be eth0
        "eth1=192.168.72.30"    # ext_net should be eth1 "eth2=192.168.100.30"    # n3_net should be eth2
    )
fi

echo "=== Interface Renaming Script ==="
echo "Target mapping:"
for m in "${INTERFACE_MAP[@]}"; do echo "  $m"; done

echo ""
echo "Current interfaces:"
ip -o addr show | grep -E "eth[0-9]" | awk '{print "  " $2 ": " $4}'

# ---- Build IP → current_iface and IP → MAC maps ----
declare -A IP_TO_IFACE
declare -A IFACE_TO_MAC
for iface in $(ip -o link show | awk -F': ' '/^[0-9]+: eth/ {print $2}' | sed 's/@.*//'); do
    ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    mac=$(ip -o link show "$iface" | awk '{print $(NF-2)}')
    [ -n "$ip_addr" ] && IP_TO_IFACE["$ip_addr"]="$iface"
    IFACE_TO_MAC["$iface"]="$mac"
    echo "  Found: $iface ($mac) has IP ${ip_addr:-<none>}"
done

# ---- Decide which interfaces need to move ----
declare -A DESIRED_NAME     # current_iface → desired_name
for mapping in "${INTERFACE_MAP[@]}"; do
    target="${mapping%%=*}"
    tip="${mapping#*=}"
    cur="${IP_TO_IFACE[$tip]:-}"
    if [ -z "$cur" ]; then
        echo "  WARN: no interface has IP $tip (wanted $target) — skipping"
        continue
    fi
    DESIRED_NAME["$cur"]="$target"
done

# ---- Short-circuit if nothing to do ----
need_work=0
for cur in "${!DESIRED_NAME[@]}"; do
    [ "$cur" != "${DESIRED_NAME[$cur]}" ] && need_work=1
done
if [ $need_work -eq 0 ]; then
    echo "All interfaces already correctly named."
    exec "$@"
fi

# ---- Phase 1: rename ALL managed interfaces to unique tmp names ----
#    Using a counter-based tmp name avoids any collision with existing names.
echo ""
echo "Phase 1: move ALL managed interfaces to tmp names..."
declare -A TMP_NAME
idx=0
for cur in "${!DESIRED_NAME[@]}"; do
    tmp="ifrenametmp${idx}"
    echo "  $cur → $tmp"
    ip link set "$cur" down 2>/dev/null || true
    ip link set "$cur" name "$tmp"
    TMP_NAME["$cur"]="$tmp"
    idx=$((idx+1))
done

# ---- Phase 2: if anything STILL squats on a target name, park it too ----
#    (e.g., eth0 is held by an unmapped network → move it to a side name)
echo "Phase 2: park any interface still squatting on a target name..."
declare -A PARKED
for cur in "${!DESIRED_NAME[@]}"; do
    target="${DESIRED_NAME[$cur]}"
    if ip link show "$target" &>/dev/null; then
        parked="ifrenameparked${idx}"
        echo "  $target is occupied — parking as $parked"
        ip link set "$target" down 2>/dev/null || true
        ip link set "$target" name "$parked"
        PARKED["$target"]="$parked"
        idx=$((idx+1))
    fi
done

# ---- Phase 3: rename tmp → target ----
echo "Phase 3: tmp → final name..."
for cur in "${!DESIRED_NAME[@]}"; do
    tmp="${TMP_NAME[$cur]}"
    target="${DESIRED_NAME[$cur]}"
    echo "  $tmp → $target"
    ip link set "$tmp" name "$target"
    ip link set "$target" up
done

# ---- Phase 4: give parked squatters a fresh name so they still work ----
#    Assign them to the next available ethN slot.
echo "Phase 4: re-home parked interfaces..."
next=0
for target in "${!PARKED[@]}"; do
    parked="${PARKED[$target]}"
    while ip link show "eth$next" &>/dev/null; do next=$((next+1)); done
    echo "  $parked → eth$next"
    ip link set "$parked" name "eth$next"
    ip link set "eth$next" up
    next=$((next+1))
done

echo ""
echo "Final interface configuration:"
ip -o addr show | grep -E "eth[0-9]" | awk '{print "  " $2 ": " $4}'
echo ""
echo "=== Interface renaming complete ==="

exec "$@"