#!/bin/bash

# deploy-edge.sh - Deploy Edge RAN + Edge UPF + UEs on Machine 2
# Deploy on PC: 192.168.0.243

set -e

MACHINE1_IP="192.168.0.193"
MACHINE2_IP="192.168.0.243"

echo "================================================"
echo "Machine 2: Edge RAN + Edge UPF + UEs Deployment"
echo "================================================"
echo "Machine 1 (Core PC): $MACHINE1_IP"
echo "Machine 2 (This PC): $MACHINE2_IP"
echo ""
echo "Components on this machine:"
echo "  - Edge UPF + Ext DN (for local breakout)"
echo "  - CU-UP (Edge - for local processing)"
echo "  - DU (Distributed Unit with RFSimulator)"
echo "  - FlexRIC (Near-RT RIC)"
echo "  - 10 UEs (User Equipment)"
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_stage() { echo -e "${BLUE}[STAGE]${NC} $1"; }
print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

wait_for_service() {
    local service=$1
    local max_wait=${2:-60}
    local count=0
    print_info "Waiting for $service to be ready..."
    while [ $count -lt $max_wait ]; do
        if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
            local status=$(docker inspect --format='{{.State.Status}}' "$service" 2>/dev/null || echo "not found")
            if [ "$status" = "running" ]; then
                print_info "$service is running"
                return 0
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    print_error "$service failed to start within ${max_wait} seconds"
    return 1
}

wait_for_healthy() {
    local service=$1
    local max_wait=${2:-120}
    local count=0
    print_info "Waiting for $service to become healthy..."
    while [ $count -lt $max_wait ]; do
        local health=$(docker inspect --format='{{.State.Health.Status}}' "$service" 2>/dev/null || echo "none")
        if [ "$health" = "healthy" ]; then
            print_info "✓ $service is healthy"
            return 0
        elif [ "$health" = "none" ]; then
            local status=$(docker inspect --format='{{.State.Status}}' "$service" 2>/dev/null || echo "not found")
            if [ "$status" = "running" ]; then
                print_info "✓ $service is running (no healthcheck)"
                return 0
            fi
        fi
        sleep 2
        count=$((count + 2))
    done
    print_error "$service failed to become healthy within ${max_wait} seconds"
    return 1
}

check_ue_connections() {
    local total_ues=10
    local connected_ues=0
    local ues_with_ip=0
    UE_IPS=()
    UE_INTERFACES=()

    print_stage "Checking UE Connections..."
    echo ""

    for i in {1..10}; do
        interface="oaitun_ue$i"
        if docker exec ue_1 ip addr show 2>/dev/null | grep -q "$interface"; then
            ((connected_ues++))
            ip_addr=$(docker exec ue_1 ip addr show "$interface" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
            if [ -n "$ip_addr" ]; then
                print_info "✓ UE$i connected - Interface: $interface - IP: $ip_addr"
                UE_IPS+=("$ip_addr")
                UE_INTERFACES+=("$interface")
                ((ues_with_ip++))
            else
                print_warn "⚠ UE$i connected - Interface: $interface - No IP yet"
            fi
        fi
    done

    echo ""
    print_info "================================================"
    print_info "UE Connection Summary:"
    print_info "  Total UEs configured: $total_ues"
    print_info "  Connected UEs: $connected_ues/$total_ues"
    print_info "  UEs with IP: $ues_with_ip/$connected_ues"
    print_info "================================================"

    if [ $ues_with_ip -gt 0 ]; then
        echo ""
        print_info "Connected UE IPs:"
        for i in "${!UE_IPS[@]}"; do
            print_info "  ${UE_INTERFACES[$i]}: ${UE_IPS[$i]}"
        done
    fi
    echo ""

    export CONNECTED_UES=$connected_ues
    export UES_WITH_IP=$ues_with_ip

    if [ $connected_ues -eq 10 ]; then
        return 0
    else
        return 1
    fi
}

# ==========================================
# Helper: Remove ALL nftables rules matching a grep pattern
# ==========================================
nft_remove_all_matching() {
    local table=$1
    local chain=$2
    local pattern=$3
    while true; do
        local H=$(sudo nft -a list chain ${table} ${chain} 2>/dev/null | grep "${pattern}" | head -1 | grep -oP 'handle \K\d+' || echo "")
        [ -z "$H" ] && break
        print_info "    Removing rule (handle $H)..."
        sudo nft delete rule ${table} ${chain} handle $H
    done
}

# ==========================================
# Edge UPF PFCP/GTP-U Routing for Cross-Machine SMF
# ==========================================
# The Edge UPF registers with NRF using its Docker internal IP (192.168.71.160).
# The SMF on Machine 1 discovers this IP and tries to send PFCP there.
# Machine 1's deploy-centraloffice.sh will add an IP alias and DNAT to route
# traffic for 192.168.71.160 to Machine 2's host IP (192.168.0.243).
#
# This function sets up DNAT on Machine 2 to forward:
#   192.168.0.243:8805/udp  → 192.168.71.160:8805 (PFCP to UPF container)
#   192.168.0.243:2152/udp  → 192.168.71.160:2152 (GTP-U to UPF container)

setup_edge_upf_pfcp() {
    print_stage "Setting up Edge UPF PFCP/GTP-U routing..."

    local PROJECT_PREFIX="distributed_deployment_"

    # Detect UPF container's core_net IP
    local UPF1_CORE_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}core_net.IPAddress}}" upf_1 2>/dev/null || echo "")
    [ -z "$UPF1_CORE_IP" ] && UPF1_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' upf_1 2>/dev/null || echo "")
    [ -z "$UPF1_CORE_IP" ] && UPF1_CORE_IP="192.168.71.160"

    print_info "Edge UPF core_net IP: ${UPF1_CORE_IP}"

    # -------------------------------------------------------
    # 1. PFCP (UDP 8805): Machine 2 host → UPF container
    # -------------------------------------------------------
    print_info ""
    print_info "--- Edge UPF PFCP (N4) UDP [3GPP TS 29.244] ---"

    # Remove any existing PFCP DNAT rules
    print_info "  Cleaning old PFCP DNAT rules..."
    nft_remove_all_matching "ip nat" "PREROUTING" "udp dport 8805"
    nft_remove_all_matching "ip nat" "DOCKER" "udp dport 8805"

    # INSERT DNAT rule: external PFCP → UPF container
    sudo nft insert rule ip nat PREROUTING ip daddr ${MACHINE2_IP} udp dport 8805 counter dnat to ${UPF1_CORE_IP}:8805
    print_info "  ✓ PFCP DNAT: ${MACHINE2_IP}:8805/udp → ${UPF1_CORE_IP}:8805"

    # Remove any existing PFCP FORWARD rules
    print_info "  Cleaning old PFCP FORWARD rules..."
    nft_remove_all_matching "ip filter" "FORWARD" "udp dport 8805"

    # INSERT FORWARD accept for PFCP
    sudo nft insert rule ip filter FORWARD oifname "br-core" udp dport 8805 counter accept
    sudo nft insert rule ip filter FORWARD iifname "br-core" udp sport 8805 counter accept
    print_info "  ✓ PFCP FORWARD rules added"

    # -------------------------------------------------------
    # 2. GTP-U (UDP 2152): Machine 2 host → UPF container
    # -------------------------------------------------------
    print_info ""
    print_info "--- Edge UPF GTP-U (N3/N9) UDP [3GPP TS 29.281] ---"

    # Remove any existing GTP-U DNAT rules for port 2152
    print_info "  Cleaning old GTP-U DNAT rules..."
    nft_remove_all_matching "ip nat" "PREROUTING" "udp dport 2152"

    # INSERT GTP-U DNAT
    sudo nft insert rule ip nat PREROUTING ip daddr ${MACHINE2_IP} udp dport 2152 counter dnat to ${UPF1_CORE_IP}:2152
    print_info "  ✓ GTP-U DNAT: ${MACHINE2_IP}:2152/udp → ${UPF1_CORE_IP}:2152"

    # INSERT FORWARD accept for GTP-U
    print_info "  Cleaning old GTP-U FORWARD rules..."
    nft_remove_all_matching "ip filter" "FORWARD" "udp dport 2152"
    sudo nft insert rule ip filter FORWARD oifname "br-core" udp dport 2152 counter accept
    sudo nft insert rule ip filter FORWARD iifname "br-core" udp sport 2152 counter accept
    print_info "  ✓ GTP-U FORWARD rules added"

    # -------------------------------------------------------
    # 3. Ensure MASQUERADE for return traffic
    # -------------------------------------------------------
    print_info ""
    print_info "--- MASQUERADE for return traffic ---"

    if ! sudo nft list chain ip nat POSTROUTING 2>/dev/null | grep -q "oifname.*br-core.*masquerade"; then
        sudo nft add rule ip nat POSTROUTING oifname "br-core" counter masquerade 2>/dev/null || true
        print_info "  ✓ MASQUERADE added for br-core"
    else
        print_info "  ✓ MASQUERADE already exists for br-core"
    fi

    # -------------------------------------------------------
    # 4. Verify UPF is listening
    # -------------------------------------------------------
    print_info ""
    print_info "--- Verifying Edge UPF sockets ---"
    local pfcp_listen=$(docker exec upf_1 ss -ulnp 2>/dev/null | grep ":8805" || echo "")
    local gtpu_listen=$(docker exec upf_1 ss -ulnp 2>/dev/null | grep ":2152" || echo "")

    if [ -n "$pfcp_listen" ]; then
        print_info "  ✓ UPF PFCP socket: listening on port 8805"
    else
        print_warn "  ⚠ UPF PFCP socket not found (may still be starting)"
    fi

    if [ -n "$gtpu_listen" ]; then
        print_info "  ✓ UPF GTP-U socket: listening on port 2152"
    else
        print_warn "  ⚠ UPF GTP-U socket not found (may still be starting)"
    fi

    # -------------------------------------------------------
    # Summary
    # -------------------------------------------------------
    print_info ""
    print_info "Edge UPF PFCP/GTP-U routing complete!"
    print_info ""
    print_info "Traffic flow (SMF on Machine 1 → Edge UPF on Machine 2):"
    print_info "  1. SMF discovers UPF from NRF with IP ${UPF1_CORE_IP}"
    print_info "  2. Machine 1 intercepts ${UPF1_CORE_IP}:8805, DNATs to ${MACHINE2_IP}:8805"
    print_info "  3. Machine 2 receives on ${MACHINE2_IP}:8805, DNATs to ${UPF1_CORE_IP}:8805"
    print_info "  4. UPF container receives PFCP Association Request"
    print_info ""
    print_info "Configured routes:"
    print_info "  PFCP (N4):  ${MACHINE2_IP}:8805/udp  → ${UPF1_CORE_IP}:8805"
    print_info "  GTP-U (N3): ${MACHINE2_IP}:2152/udp → ${UPF1_CORE_IP}:2152"
}

verify_edge_upf_pfcp() {
    print_stage "Verifying Edge UPF PFCP/GTP-U routing..."

    echo ""
    print_info "=== NAT PREROUTING rules (UDP) ==="
    sudo nft -a list chain ip nat PREROUTING 2>/dev/null | grep -E "udp dport (8805|2152)" || print_warn "  No UDP DNAT rules found"

    echo ""
    print_info "=== Filter FORWARD rules (UDP) ==="
    sudo nft -a list chain ip filter FORWARD 2>/dev/null | grep -E "udp.*(8805|2152)" || print_warn "  No UDP FORWARD rules found"

    echo ""
    print_info "=== Edge UPF UDP listening sockets ==="
    docker exec upf_1 ss -ulnp 2>/dev/null | grep -E "8805|2152" || print_warn "  UPF sockets not found"

    echo ""
}

# ==========================================
# SCTP Routing Fix for Machine 2
# ==========================================
# Docker creates nftables DNAT rules for /sctp port mappings, but:
# 1. May DNAT to the wrong container IP (first network vs actual bind)
# 2. Uses 'nft add' which appends AFTER catch-all DROP rules
# 3. docker-proxy cannot handle SCTP (but kernel nftables can)
# 4. Machine 2 may have DOCKER-ISOLATION-STAGE-1/2 chains that
#    block cross-bridge SCTP traffic
#
# The DU exposes port 500/sctp for F1-C (inbound from CU-CP on Machine 1)
# The Edge CU-UP initiates outbound E1 SCTP to Machine 1 (no inbound DNAT needed)

setup_edge_sctp_routing() {
    print_stage "Setting up SCTP routing rules for Edge components..."

    # -------------------------------------------------------
    # Ensure SCTP kernel module is loaded
    # -------------------------------------------------------
    if ! lsmod | grep -q "^sctp"; then
        sudo modprobe sctp
    fi
    print_info "✓ SCTP kernel module loaded"

    # Disable conntrack checksum for SCTP compatibility
    if [ -f /proc/sys/net/netfilter/nf_conntrack_checksum ]; then
        sudo sysctl -w net.netfilter.nf_conntrack_checksum=0 > /dev/null 2>&1
        print_info "✓ Conntrack checksum disabled for SCTP"
    fi

    # -------------------------------------------------------
    # Detect container IPs
    # -------------------------------------------------------
    local PROJECT_PREFIX="distributed_deployment_"

    local DU_F1C_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}f1c_net.IPAddress}}" du_1 2>/dev/null || echo "")
    local CUUP1_CORE_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}core_net.IPAddress}}" cuup_1 2>/dev/null || echo "")
    local CUUP1_E1_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}e1_net.IPAddress}}" cuup_1 2>/dev/null || echo "")

    # Fallback without prefix
    [ -z "$DU_F1C_IP" ] && DU_F1C_IP=$(docker inspect -f '{{.NetworkSettings.Networks.f1c_net.IPAddress}}' du_1 2>/dev/null || echo "")
    [ -z "$CUUP1_CORE_IP" ] && CUUP1_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' cuup_1 2>/dev/null || echo "")
    [ -z "$CUUP1_E1_IP" ] && CUUP1_E1_IP=$(docker inspect -f '{{.NetworkSettings.Networks.e1_net.IPAddress}}' cuup_1 2>/dev/null || echo "")

    # Last resort: parse from docker inspect JSON
    [ -z "$DU_F1C_IP" ] && DU_F1C_IP=$(docker inspect du_1 2>/dev/null | grep -A5 'f1c_net' | grep 'IPAddress' | head -1 | grep -oP '"\K[0-9.]+' || echo "")
    [ -z "$CUUP1_E1_IP" ] && CUUP1_E1_IP=$(docker inspect cuup_1 2>/dev/null | grep -A5 'e1_net' | grep 'IPAddress' | head -1 | grep -oP '"\K[0-9.]+' || echo "")

    # Auto-detect actual DU F1-C listening port
    local DU_F1C_PORT=""
    if [ -n "$DU_F1C_IP" ]; then
        DU_F1C_PORT=$(docker exec du_1 ss -Slnp 2>/dev/null | grep "${DU_F1C_IP}" | awk '{print $5}' | cut -d: -f2 | head -1 || echo "")
    fi
    [ -z "$DU_F1C_PORT" ] && DU_F1C_PORT="500"

    print_info "Container IPs and ports detected:"
    print_info "  DU     (f1c_net):  ${DU_F1C_IP:-NOT FOUND}:${DU_F1C_PORT}"
    print_info "  CU-UP  (core_net): ${CUUP1_CORE_IP:-NOT FOUND}"
    print_info "  CU-UP  (e1_net):   ${CUUP1_E1_IP:-NOT FOUND}"

    # -------------------------------------------------------
    # 1. DU F1-C: Machine2:500/sctp → DU on f1c_net
    # -------------------------------------------------------
    if [ -n "$DU_F1C_IP" ]; then
        print_info ""
        print_info "--- DU F1-C (F1AP) SCTP [3GPP TS 38.472] ---"

        # Remove ALL existing DU F1-C DNAT rules (any target IP/port)
        print_info "  Cleaning old DU F1-C DNAT rules..."
        nft_remove_all_matching "ip nat" "DOCKER" "sctp dport 500"

        # INSERT correct DNAT at TOP of chain
        sudo nft insert rule ip nat DOCKER iifname != "br-f1c" meta l4proto sctp ip daddr ${MACHINE2_IP} sctp dport 500 counter dnat to ${DU_F1C_IP}:${DU_F1C_PORT}
        print_info "  ✓ DU F1-C DNAT INSERTED: ${MACHINE2_IP}:500 → ${DU_F1C_IP}:${DU_F1C_PORT}"

        # Remove ALL existing DU F1-C FORWARD rules
        print_info "  Cleaning old DU F1-C FORWARD rules..."
        nft_remove_all_matching "ip filter" "DOCKER" "br-f1c.*sctp"

        # INSERT FORWARD accept BEFORE the catch-all DROP for br-f1c
        local F1C_DROP=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep 'iifname != "br-f1c" oifname "br-f1c" counter.*drop' | grep -oP 'handle \K\d+' | head -1 || echo "")
        if [ -n "$F1C_DROP" ]; then
            sudo nft insert rule ip filter DOCKER position $F1C_DROP iifname != "br-f1c" oifname "br-f1c" meta l4proto sctp ip daddr ${DU_F1C_IP} sctp dport ${DU_F1C_PORT} counter accept
            print_info "  ✓ DU F1-C FORWARD accept INSERTED before drop (position $F1C_DROP)"
        else
            sudo nft insert rule ip filter DOCKER iifname != "br-f1c" oifname "br-f1c" meta l4proto sctp ip daddr ${DU_F1C_IP} sctp dport ${DU_F1C_PORT} counter accept
            print_info "  ✓ DU F1-C FORWARD accept INSERTED at top"
        fi

        # Ensure DOCKER-BRIDGE jumps to DOCKER for br-f1c
        if ! sudo nft list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep -q 'oifname "br-f1c".*jump DOCKER'; then
            sudo nft add rule ip filter DOCKER-BRIDGE oifname "br-f1c" counter jump DOCKER
            print_info "  ✓ Added DOCKER-BRIDGE jump for br-f1c"
        fi

        print_info "  ✓ DU F1-C routing: ${MACHINE2_IP}:500/sctp → ${DU_F1C_IP}:${DU_F1C_PORT} (br-f1c)"
    else
        print_warn "  DU f1c_net IP not found — skipping DU F1-C SCTP routing"
    fi

    # -------------------------------------------------------
    # 2. Edge CU-UP E1: Outbound SCTP to Machine 1 (192.168.0.193:38462)
    # -------------------------------------------------------
    if [ -n "$CUUP1_E1_IP" ]; then
        print_info ""
        print_info "--- Edge CU-UP E1AP SCTP (outbound to Machine 1) [3GPP TS 38.463] ---"

        # Verify the CU-UP can reach Machine 1
        if docker exec cuup_1 ping -c 1 -W 2 ${MACHINE1_IP} > /dev/null 2>&1; then
            print_info "  ✓ Edge CU-UP can reach Machine 1 (${MACHINE1_IP})"
        else
            print_warn "  ✗ Edge CU-UP cannot ping Machine 1 — checking routing..."
            local CUUP_GW=$(docker exec cuup_1 ip route show default 2>/dev/null | awk '{print $3}' | head -1)
            if [ -n "$CUUP_GW" ]; then
                print_info "  CU-UP default gateway: $CUUP_GW"
            else
                print_warn "  CU-UP has no default route — adding one via e1_net gateway..."
                docker exec cuup_1 ip route add default via 192.168.75.129 2>/dev/null || true
            fi
        fi

        # Ensure MASQUERADE exists for e1_net outbound traffic
        # Check both field orderings Docker might use
        if sudo nft list chain ip nat POSTROUTING 2>/dev/null | grep -q '192.168.75.128/26.*masquerade'; then
            print_info "  ✓ MASQUERADE rule exists for e1_net outbound traffic"
        else
            print_warn "  Adding MASQUERADE for e1_net outbound traffic..."
            sudo nft add rule ip nat POSTROUTING oifname != "br-e1" ip saddr 192.168.75.128/26 counter masquerade
        fi

        print_info "  ✓ Edge CU-UP E1: ${CUUP1_E1_IP} → ${MACHINE1_IP}:38462/sctp (outbound)"
    else
        print_warn "  Edge CU-UP e1_net IP not found — skipping E1 routing check"
    fi

    # -------------------------------------------------------
    # 3. Handle Docker inter-network isolation (DOCKER-ISOLATION-STAGE-1/2)
    # -------------------------------------------------------
    print_info ""
    print_info "--- Docker isolation chain handling ---"

    if sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null | grep -q "jump DOCKER-ISOLATION-STAGE-2"; then
        print_info "  Docker isolation chains detected"

        # Allow E1 SCTP from br-e1 to leave (outbound to Machine 1 CU-CP)
        if ! sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null | grep -q 'iifname "br-e1" meta l4proto sctp.*accept'; then
            print_info "  Adding SCTP bypass for br-e1 (E1AP outbound)..."
            sudo nft insert rule ip filter DOCKER-ISOLATION-STAGE-1 \
                iifname "br-e1" meta l4proto sctp counter accept
        else
            print_info "  ✓ SCTP bypass for br-e1 already exists"
        fi

        # Allow F1-C SCTP from br-f1c to leave (outbound to Machine 1 CU-CP)
        if ! sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null | grep -q 'iifname "br-f1c" meta l4proto sctp.*accept'; then
            print_info "  Adding SCTP bypass for br-f1c (F1-C outbound)..."
            sudo nft insert rule ip filter DOCKER-ISOLATION-STAGE-1 \
                iifname "br-f1c" meta l4proto sctp counter accept
        else
            print_info "  ✓ SCTP bypass for br-f1c already exists"
        fi

        print_info "  ✓ Docker isolation SCTP bypass rules configured"
    else
        print_info "  ✓ No Docker isolation chains found — no bypass needed"
    fi

    # -------------------------------------------------------
    # 4. Verify raw table doesn't block our traffic
    # -------------------------------------------------------
    print_info ""
    print_info "--- Raw table verification ---"

    if sudo nft list chain ip raw PREROUTING 2>/dev/null | grep -q "ip daddr ${MACHINE2_IP}.*drop"; then
        print_warn "  Raw table has DROP rule for ${MACHINE2_IP} — removing..."
        nft_remove_all_matching "ip raw" "PREROUTING" "ip daddr ${MACHINE2_IP}.*drop"
    else
        print_info "  ✓ Raw table does not block external IP"
    fi

    # -------------------------------------------------------
    # Summary
    # -------------------------------------------------------
    print_info ""
    print_info "Edge SCTP routing setup complete!"
    print_info ""
    print_info "SCTP connection summary:"
    print_info "  DU F1-C (inbound):        ${MACHINE2_IP}:500/sctp → ${DU_F1C_IP:-?}:${DU_F1C_PORT} (br-f1c) [TS 38.472]"
    print_info "  CU-UP E1 (outbound):      ${CUUP1_E1_IP:-?} → ${MACHINE1_IP}:38462/sctp [TS 38.463]"
    print_info "  DU F1-C (outbound to M1): ${DU_F1C_IP:-?} → ${MACHINE1_IP}:38472/sctp [TS 38.472]"
}

verify_edge_sctp_routing() {
    print_stage "Verifying Edge SCTP routing rules..."

    echo ""
    print_info "=== NAT DNAT rules (SCTP) on Machine 2 ==="
    sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep sctp || print_warn "  No SCTP DNAT rules found"

    echo ""
    print_info "=== Filter FORWARD rules (SCTP) on Machine 2 ==="
    sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep sctp || print_warn "  No SCTP FORWARD rules found"

    echo ""
    print_info "=== DU SCTP listening sockets ==="
    docker exec du_1 ss -Slnp 2>/dev/null || print_warn "  Could not check DU sockets (DU may still be starting)"

    echo ""
    print_info "=== Edge CU-UP SCTP sockets ==="
    docker exec cuup_1 ss -Slnp 2>/dev/null || print_warn "  Could not check CU-UP sockets"

    echo ""
    print_info "=== Testing SCTP connectivity to Machine 1 ==="

    if command -v ncat &> /dev/null; then
        if timeout 3 ncat --sctp ${MACHINE1_IP} 38472 < /dev/null 2>/dev/null; then
            print_info "  ✓ F1-C SCTP to Machine 1 CU-CP (${MACHINE1_IP}:38472) — REACHABLE"
        else
            print_warn "  ✗ F1-C SCTP to Machine 1 CU-CP (${MACHINE1_IP}:38472) — NOT REACHABLE"
            print_warn "    Ensure deploy-centraloffice.sh ran setup_sctp_routing on Machine 1"
        fi

        if timeout 3 ncat --sctp ${MACHINE1_IP} 38462 < /dev/null 2>/dev/null; then
            print_info "  ✓ E1 SCTP to Machine 1 CU-CP (${MACHINE1_IP}:38462) — REACHABLE"
        else
            print_warn "  ✗ E1 SCTP to Machine 1 CU-CP (${MACHINE1_IP}:38462) — NOT REACHABLE"
            print_warn "    Ensure deploy-centraloffice.sh ran setup_sctp_routing on Machine 1"
        fi
    else
        print_warn "  ncat not installed — skipping SCTP connectivity test"
        print_warn "  Install with: sudo apt install ncat"
    fi

    echo ""
}

# ==========================================
# Pre-deployment checks
# ==========================================
print_stage "Running pre-flight checks..."

if ! docker ps &> /dev/null; then
    print_error "Docker is not running"
    exit 1
fi

if docker compose ps -q 2>/dev/null | grep -q .; then
    print_warn "Some containers are already running"
    read -p "Do you want to stop them and restart? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Stopping existing containers..."
        docker compose -f docker-compose-edge.yml down
    else
        print_info "Continuing with existing containers..."
    fi
fi

CURRENT_IP=""
ip_addresses=$(hostname -I)
for ip in $ip_addresses; do
    if [ "$ip" == "$MACHINE2_IP" ]; then
        CURRENT_IP="$ip"
        break
    fi
done

if [ "$CURRENT_IP" != "$MACHINE2_IP" ]; then
    print_warn "Expected IP $MACHINE2_IP not found"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

if [ ! -f "docker-compose-edge.yml" ]; then
    print_error "docker-compose-edge.yml not found"
    exit 1
fi

if [ ! -d "configs" ]; then
    print_error "configs directory not found"
    exit 1
fi

if ! lsmod | grep -q "^sctp"; then
    print_info "Loading SCTP kernel module..."
    sudo modprobe sctp
fi
print_info "✓ SCTP kernel module loaded"

# CRITICAL: Check network connectivity to Machine 1
if ! ping -c 3 -W 2 $MACHINE1_IP &> /dev/null; then
    print_error "✗ Cannot reach Machine 1 ($MACHINE1_IP)"
    print_error "Machine 2 requires connectivity to Machine 1 Core Network"
    exit 1
fi
print_info "✓ Can reach Machine 1 ($MACHINE1_IP)"

# Test core network reachability (NRF on TCP as proxy for core health)
print_info "Testing core network reachability on Machine 1..."
if timeout 2 bash -c "echo > /dev/tcp/$MACHINE1_IP/9090" 2>/dev/null; then
    print_info "✓ Can reach NRF on $MACHINE1_IP:9090 — Core network is up"
else
    print_error "✗ Cannot reach NRF on $MACHINE1_IP:9090"
    print_error "Make sure Machine 1 is deployed and deploy-centraloffice.sh completed successfully"
    exit 1
fi

# Test SCTP connectivity to Machine 1 CU-CP (non-blocking warning)
print_info "Testing SCTP connectivity to Machine 1 CU-CP..."
if command -v ncat &> /dev/null; then
    if timeout 3 ncat --sctp ${MACHINE1_IP} 38472 < /dev/null 2>/dev/null; then
        print_info "✓ F1-C SCTP reachable on $MACHINE1_IP:38472"
    else
        print_warn "✗ F1-C SCTP NOT reachable on $MACHINE1_IP:38472"
        print_warn "  Ensure deploy-centraloffice.sh ran setup_sctp_routing() on Machine 1"
        print_warn "  Continuing anyway — DU will retry F1 Setup..."
    fi
    if timeout 3 ncat --sctp ${MACHINE1_IP} 38462 < /dev/null 2>/dev/null; then
        print_info "✓ E1 SCTP reachable on $MACHINE1_IP:38462"
    else
        print_warn "✗ E1 SCTP NOT reachable on $MACHINE1_IP:38462"
        print_warn "  Ensure deploy-centraloffice.sh ran setup_sctp_routing() on Machine 1"
        print_warn "  Continuing anyway — Edge CU-UP will retry E1 Setup..."
    fi
else
    print_warn "ncat not installed — skipping SCTP pre-flight test"
fi

print_info "Pre-flight checks passed!"
echo ""

# ==========================================
# Start Deployment
# ==========================================

print_stage "Creating Docker networks and preparing containers..."
docker compose -f docker-compose-edge.yml up --no-start
echo ""

# Stage 1: Edge UPF
print_stage "Stage 1/8: Starting Edge UPF and External DN..."
docker compose -f docker-compose-edge.yml up -d upf_1 ext_dn_1
wait_for_service "upf_1" 30
wait_for_service "ext_dn_1" 30
print_info "Waiting for UPF initialization..."
sleep 10

# Setup PFCP/GTP-U routing for cross-machine SMF → UPF
setup_edge_upf_pfcp
verify_edge_upf_pfcp
echo ""

# Stage 2: Edge CU-UP
print_stage "Stage 2/8: Starting Edge CU-UP..."
docker compose -f docker-compose-edge.yml up -d cuup_1
wait_for_service "cuup_1" 30
sleep 10
echo ""

# Stage 3: DU with RFSimulator
print_stage "Stage 3/8: Starting DU with RFSimulator..."
docker compose -f docker-compose-edge.yml up -d du_1
wait_for_service "du_1" 30
print_info "Waiting for DU to initialize SCTP sockets..."
sleep 15

# Check DU RFSimulator status
if docker logs du_1 2>&1 | grep -q "Running as server"; then
    print_info "✓ DU RFSimulator server is listening"
else
    print_warn "⚠ DU RFSimulator status unclear — check logs"
fi
echo ""

# ==========================================
# Stage 4: SCTP Routing Fix (THE KEY FIX)
# ==========================================
print_stage "Stage 4/8: Configuring SCTP routing for Edge components..."
echo ""
setup_edge_sctp_routing
echo ""

# Verify SCTP routing
verify_edge_sctp_routing
echo ""

# Stage 5: FlexRIC
print_stage "Stage 5/8: Starting FlexRIC (Near-RT RIC)..."
docker compose -f docker-compose-edge.yml up -d flexric
wait_for_service "flexric" 30
sleep 10
echo ""

# Stage 6: User Equipment (10 UEs)
print_stage "Stage 6/8: Starting 10 User Equipment instances..."
docker compose -f docker-compose-edge.yml up -d ue_1
wait_for_service "ue_1" 30
echo ""

# Stage 7: Wait for UE connections
print_stage "Stage 7/8: Waiting for UE connections..."
print_info "Waiting 30 seconds for UEs to connect and register..."
sleep 30
echo ""

# Stage 8: Check UE connections
print_stage "Stage 8/8: Verifying UE connections..."
if check_ue_connections; then
    print_info "✓ All 10 UEs successfully connected!"
    echo ""
else
    print_warn "Only $CONNECTED_UES out of 10 UEs are connected."
    echo ""

    while true; do
        echo "Options:"
        echo "  [w] Wait 10 seconds and check again"
        echo "  [p] Proceed with $CONNECTED_UES UEs"
        echo "  [q] Quit and check logs"
        echo ""
        read -p "Choose an option (w/p/q): " -n 1 -r
        echo ""
        echo ""

        case $REPLY in
            [Ww])
                print_info "Waiting 10 seconds for more UEs to connect..."
                sleep 10
                if check_ue_connections; then
                    print_info "✓ All 10 UEs are now connected!"
                    break
                else
                    print_warn "Still only $CONNECTED_UES UEs connected."
                    echo ""
                    continue
                fi
                ;;
            [Pp])
                print_info "Proceeding with $CONNECTED_UES connected UE(s)..."
                break
                ;;
            [Qq])
                print_info "Exiting. Check logs with:"
                echo "  docker logs ue_1 | grep -i 'attach\|registration\|rrc'"
                echo "  docker logs du_1 | grep -i 'ue\|rfsim\|f1ap'"
                echo "  docker logs cuup_1 | grep -i 'e1ap\|sctp'"
                exit 0
                ;;
            *)
                print_error "Invalid option. Please choose w, p, or q."
                echo ""
                ;;
        esac
    done
fi

# Final status check
echo ""
print_stage "Checking final status..."
echo ""
docker compose -f docker-compose-edge.yml ps
echo ""

print_info "================================================"
print_info "Machine 2 Deployment Complete!"
print_info "================================================"
echo ""

print_info "Services running:"
print_info "  - Edge UPF (upf_1):     PFCP to SMF on Machine 1"
print_info "  - Ext DN (ext_dn_1):    Data network gateway"
print_info "  - Edge CU-UP (cuup_1):  E1 to CU-CP on Machine 1"
print_info "  - DU (du_1):            F1 to CU-CP on Machine 1, RFSim server"
print_info "  - FlexRIC:              Near-RT RIC"
print_info "  - UE (ue_1):            $CONNECTED_UES UE(s) connected"
echo ""

print_info "Key Endpoints:"
print_info "  - Edge UPF PFCP:  ${MACHINE2_IP}:8805/udp → SMF on ${MACHINE1_IP}"
print_info "  - Edge UPF GTP-U: ${MACHINE2_IP}:2152/udp"
print_info "  - DU F1-C:        ${MACHINE2_IP}:500/sctp → CU-CP on ${MACHINE1_IP}:38472"
print_info "  - CU-UP E1:       outbound to CU-CP on ${MACHINE1_IP}:38462"
echo ""

print_info "Useful commands:"
echo "  - Check UE connections:  docker exec ue_1 ip addr | grep oaitun"
echo "  - Check Edge UPF logs:   docker logs upf_1 | grep -i pfcp"
echo "  - Check DU logs:         docker logs du_1 | grep -i f1ap"
echo "  - Check CU-UP logs:      docker logs cuup_1 | grep -i e1ap"
echo "  - Stop deployment:       ./stop.sh"
echo ""

read -p "Show live logs? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker compose -f docker-compose-edge.yml logs -f
fi
