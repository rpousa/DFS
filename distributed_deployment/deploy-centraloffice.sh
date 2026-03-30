#!/bin/bash

# deploy-centraloffice.sh - Deploy Core Network + Unified CU on Machine 1
# Deploy on PC: 192.168.0.193
#
# ARCHITECTURE: Single unified CU replaces separate CU-CP + CU-UP
# The CU handles F1-C, F1-U, E1, NGAP, and GTP-U internally on core_net.
# No more f1c_net, f1u_net, or e1_net on Machine 1.

set -e

MACHINE1_IP="192.168.0.193"
MACHINE2_IP="192.168.0.243"

echo "================================================"
echo "Machine 1: Core Network + Unified CU Deployment"
echo "================================================"
echo "Machine 1 (This PC): $MACHINE1_IP"
echo "Machine 2 (Edge PC): $MACHINE2_IP"
echo ""
echo "Components on this machine:"
echo "  - 5G Core Network (MySQL, NRF, AMF, SMF, UDM, UDR, AUSF, PCF, NSSF)"
echo "  - Primary UPF + Ext DN"
echo "  - CU (Unified Central Unit: Control + User Plane)"
echo "  - FlexRIC (Near-RT RIC + xApp)"
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
# SCTP Routing Fix for Unified CU Architecture
# ==========================================
# With a unified CU, all interfaces (F1-C, NGAP, E2AP, GTP-U) are on core_net.
# Docker creates nftables DNAT rules for /sctp port mappings, but:
# 1. May DNAT to the wrong container IP
# 2. Uses 'nft add' which appends AFTER catch-all DROP rules
# 3. docker-proxy cannot handle SCTP (but kernel nftables can)
#
# The CU exposes on core_net (192.168.71.140):
#   - 38472/sctp for F1-C (inbound from DU on Machine 2)
#   - 2153/udp for F1-U GTP-U (inbound from DU on Machine 2)
# The CU initiates (outbound, no DNAT needed):
#   - NGAP to AMF (192.168.71.132:38412) — internal
#   - GTP-U to UPF (192.168.71.134:2152) — internal
#   - E2AP to FlexRIC (192.168.71.150:36421) — internal

setup_sctp_routing() {
    print_stage "Setting up SCTP routing rules for cross-machine connectivity..."

    # Ensure SCTP kernel module
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
    # Detect container IPs on core_net
    # -------------------------------------------------------
    local PROJECT_PREFIX="distributed_deployment_"

    local AMF_CORE_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}core_net.IPAddress}}" amf 2>/dev/null || echo "")
    local CU_CORE_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}core_net.IPAddress}}" cu 2>/dev/null || echo "")
    local FLEXRIC_CORE_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}core_net.IPAddress}}" flexric 2>/dev/null || echo "")

    # Fallback without prefix
    [ -z "$AMF_CORE_IP" ] && AMF_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' amf 2>/dev/null || echo "")
    [ -z "$CU_CORE_IP" ] && CU_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' cu 2>/dev/null || echo "")
    [ -z "$FLEXRIC_CORE_IP" ] && FLEXRIC_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' flexric 2>/dev/null || echo "")

    # Last resort: parse from docker inspect JSON
    [ -z "$CU_CORE_IP" ] && CU_CORE_IP=$(docker inspect cu 2>/dev/null | grep -A5 'core_net' | grep 'IPAddress' | head -1 | grep -oP '"\K[0-9.]+' || echo "")
    [ -z "$FLEXRIC_CORE_IP" ] && FLEXRIC_CORE_IP=$(docker inspect flexric 2>/dev/null | grep -A5 'core_net' | grep 'IPAddress' | head -1 | grep -oP '"\K[0-9.]+' || echo "")

    # Auto-detect actual CU F1-C listening port
    local CU_F1C_PORT=""
    if [ -n "$CU_CORE_IP" ]; then
        CU_F1C_PORT=$(docker exec cu ss -Slnp 2>/dev/null | grep "${CU_CORE_IP}" | grep -oP ':\K[0-9]+' | head -1 || echo "")
    fi
    [ -z "$CU_F1C_PORT" ] && CU_F1C_PORT="38472"

    # Auto-detect FlexRIC E2AP listening port
    local FLEXRIC_PORT=""
    if [ -n "$FLEXRIC_CORE_IP" ]; then
        FLEXRIC_PORT=$(docker exec flexric ss -Slnp 2>/dev/null | grep "${FLEXRIC_CORE_IP}" | grep -oP ':\K[0-9]+' | head -1 || echo "")
    fi
    [ -z "$FLEXRIC_PORT" ] && FLEXRIC_PORT="36421"

    print_info "Container IPs and ports detected:"
    print_info "  AMF     (core_net): ${AMF_CORE_IP:-NOT FOUND}"
    print_info "  CU      (core_net): ${CU_CORE_IP:-NOT FOUND}:${CU_F1C_PORT}"
    print_info "  FlexRIC (core_net): ${FLEXRIC_CORE_IP:-NOT FOUND}:${FLEXRIC_PORT}"

    if [ -z "$CU_CORE_IP" ] || [ -z "$AMF_CORE_IP" ]; then
        print_error "Could not detect container IPs. SCTP routing setup failed."
        return 1
    fi

    # -------------------------------------------------------
    # 1. AMF NGAP — Docker's rule is correct (AMF on core_net)
    # -------------------------------------------------------
    print_info ""
    print_info "--- AMF NGAP (N2) SCTP [TS 38.413] ---"
    if sudo nft list chain ip nat DOCKER 2>/dev/null | grep -q "sctp dport 38412.*dnat to ${AMF_CORE_IP}:38412"; then
        print_info "  ✓ AMF NGAP DNAT rule correct"
    else
        print_warn "  Adding AMF NGAP DNAT rule..."
        nft_remove_all_matching "ip nat" "DOCKER" "sctp dport 38412"
        sudo nft insert rule ip nat DOCKER iifname != "br-core" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 38412 counter dnat to ${AMF_CORE_IP}:38412
        print_info "  ✓ AMF NGAP DNAT INSERTED"
    fi

    # -------------------------------------------------------
    # 2. CU F1-C — For Machine 2 DU to connect
    #    All on core_net now (no more br-f1c)
    # -------------------------------------------------------
    print_info ""
    print_info "--- CU F1-C (F1AP) SCTP [TS 38.472] ---"

    # Remove ALL existing F1-C DNAT rules
    print_info "  Cleaning old F1-C DNAT rules..."
    nft_remove_all_matching "ip nat" "DOCKER" "sctp dport 38472"

    # INSERT correct DNAT at TOP of chain — CU is on core_net
    sudo nft insert rule ip nat DOCKER iifname != "br-core" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 38472 counter dnat to ${CU_CORE_IP}:${CU_F1C_PORT}
    print_info "  ✓ F1-C DNAT INSERTED: ${MACHINE1_IP}:38472 → ${CU_CORE_IP}:${CU_F1C_PORT}"

    # Remove ALL existing F1-C FORWARD rules on br-core for this port
    print_info "  Cleaning old F1-C FORWARD rules..."
    nft_remove_all_matching "ip filter" "DOCKER" "br-core.*sctp.*${CU_F1C_PORT}"

    # INSERT FORWARD accept BEFORE the catch-all DROP for br-core
    local CORE_DROP=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep 'iifname != "br-core" oifname "br-core" counter.*drop' | grep -oP 'handle \K\d+' | head -1 || echo "")
    if [ -n "$CORE_DROP" ]; then
        sudo nft insert rule ip filter DOCKER position $CORE_DROP iifname != "br-core" oifname "br-core" meta l4proto sctp ip daddr ${CU_CORE_IP} sctp dport ${CU_F1C_PORT} counter accept
        print_info "  ✓ F1-C FORWARD accept INSERTED before drop (position $CORE_DROP)"
    else
        sudo nft insert rule ip filter DOCKER iifname != "br-core" oifname "br-core" meta l4proto sctp ip daddr ${CU_CORE_IP} sctp dport ${CU_F1C_PORT} counter accept
        print_info "  ✓ F1-C FORWARD accept INSERTED at top"
    fi

    # Ensure DOCKER-BRIDGE jumps to DOCKER for br-core
    if ! sudo nft list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep -q 'oifname "br-core".*jump DOCKER'; then
        sudo nft add rule ip filter DOCKER-BRIDGE oifname "br-core" counter jump DOCKER
        print_info "  ✓ Added DOCKER-BRIDGE jump for br-core"
    fi

    # -------------------------------------------------------
    # 3. FlexRIC E2AP — Port 36421 (primary)
    # -------------------------------------------------------
    print_info ""
    print_info "--- FlexRIC E2AP SCTP [O-RAN E2AP] ---"

    if [ -z "$FLEXRIC_CORE_IP" ]; then
        print_error "  Could not detect FlexRIC IP. Skipping E2AP routing."
    else
        # --- Port 36421 (primary E2AP) ---
        print_info "  Cleaning old E2AP 36421 DNAT rules..."
        nft_remove_all_matching "ip nat" "DOCKER" "sctp dport 36421"

        sudo nft insert rule ip nat DOCKER iifname != "br-core" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 36421 counter dnat to ${FLEXRIC_CORE_IP}:36421
        print_info "  ✓ E2AP DNAT INSERTED: ${MACHINE1_IP}:36421 → ${FLEXRIC_CORE_IP}:36421"

        print_info "  Cleaning old E2AP 36421 FORWARD rules..."
        nft_remove_all_matching "ip filter" "DOCKER" "br-core.*sctp.*36421"

        # Re-fetch CORE_DROP handle (may have changed after previous inserts)
        CORE_DROP=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep 'iifname != "br-core" oifname "br-core" counter.*drop' | grep -oP 'handle \K\d+' | head -1 || echo "")
        if [ -n "$CORE_DROP" ]; then
            sudo nft insert rule ip filter DOCKER position $CORE_DROP iifname != "br-core" oifname "br-core" meta l4proto sctp ip daddr ${FLEXRIC_CORE_IP} sctp dport 36421 counter accept
            print_info "  ✓ E2AP 36421 FORWARD accept INSERTED before drop (position $CORE_DROP)"
        else
            sudo nft insert rule ip filter DOCKER iifname != "br-core" oifname "br-core" meta l4proto sctp ip daddr ${FLEXRIC_CORE_IP} sctp dport 36421 counter accept
            print_info "  ✓ E2AP 36421 FORWARD accept INSERTED at top"
        fi

        # --- Port 36422 (secondary E2AP) ---
        print_info "  Cleaning old E2AP 36422 DNAT rules..."
        nft_remove_all_matching "ip nat" "DOCKER" "sctp dport 36422"

        sudo nft insert rule ip nat DOCKER iifname != "br-core" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 36422 counter dnat to ${FLEXRIC_CORE_IP}:36422
        print_info "  ✓ E2AP DNAT INSERTED: ${MACHINE1_IP}:36422 → ${FLEXRIC_CORE_IP}:36422"

        print_info "  Cleaning old E2AP 36422 FORWARD rules..."
        nft_remove_all_matching "ip filter" "DOCKER" "br-core.*sctp.*36422"

        CORE_DROP=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep 'iifname != "br-core" oifname "br-core" counter.*drop' | grep -oP 'handle \K\d+' | head -1 || echo "")
        if [ -n "$CORE_DROP" ]; then
            sudo nft insert rule ip filter DOCKER position $CORE_DROP iifname != "br-core" oifname "br-core" meta l4proto sctp ip daddr ${FLEXRIC_CORE_IP} sctp dport 36422 counter accept
            print_info "  ✓ E2AP 36422 FORWARD accept INSERTED before drop (position $CORE_DROP)"
        else
            sudo nft insert rule ip filter DOCKER iifname != "br-core" oifname "br-core" meta l4proto sctp ip daddr ${FLEXRIC_CORE_IP} sctp dport 36422 counter accept
            print_info "  ✓ E2AP 36422 FORWARD accept INSERTED at top"
        fi
    fi

    # -------------------------------------------------------
    # 4. Raw table check
    # -------------------------------------------------------
    print_info ""
    if sudo nft list chain ip raw PREROUTING 2>/dev/null | grep -q "ip daddr ${MACHINE1_IP}.*drop"; then
        print_warn "  Raw table has DROP for ${MACHINE1_IP} — removing..."
        nft_remove_all_matching "ip raw" "PREROUTING" "ip daddr ${MACHINE1_IP}.*drop"
    else
        print_info "  ✓ Raw table OK"
    fi

    # -------------------------------------------------------
    # Summary
    # -------------------------------------------------------
    print_info ""
    print_info "SCTP routing setup complete!"
    print_info "  AMF  NGAP:    ${MACHINE1_IP}:38412 → ${AMF_CORE_IP}:38412 (br-core)"
    print_info "  CU   F1-C:    ${MACHINE1_IP}:38472 → ${CU_CORE_IP}:${CU_F1C_PORT} (br-core)"
    print_info "  FlexRIC E2AP: ${MACHINE1_IP}:36421 → ${FLEXRIC_CORE_IP:-?}:36421 (br-core)"
    print_info "  FlexRIC E2AP: ${MACHINE1_IP}:36422 → ${FLEXRIC_CORE_IP:-?}:36422 (br-core)"
}

verify_sctp_routing() {
    print_stage "Verifying SCTP routing rules..."
    echo ""
    print_info "=== NAT DNAT rules (SCTP) ==="
    sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep sctp || print_warn "  No SCTP DNAT rules found"
    echo ""
    print_info "=== Filter FORWARD rules (SCTP) ==="
    sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep sctp || print_warn "  No SCTP FORWARD rules found"
    echo ""
    print_info "=== CU SCTP listening sockets ==="
    docker exec cu ss -Slnp 2>/dev/null || print_warn "  Could not check CU sockets"
    echo ""
    print_info "=== AMF SCTP listening sockets ==="
    docker exec amf ss -Slnp 2>/dev/null || print_warn "  Could not check AMF sockets"
    echo ""
    print_info "=== FlexRIC SCTP listening sockets ==="
    docker exec flexric ss -Slnp 2>/dev/null || print_warn "  Could not check FlexRIC sockets"
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
        docker compose -f docker-compose-centraloffice.yml down
    else
        print_info "Continuing with existing containers..."
    fi
fi

CURRENT_IP=""
ip_addresses=$(hostname -I)
for ip in $ip_addresses; do
    if [ "$ip" == "$MACHINE1_IP" ]; then
        CURRENT_IP="$ip"
        break
    fi
done

if [ "$CURRENT_IP" != "$MACHINE1_IP" ]; then
    print_warn "Current IP is $CURRENT_IP, expected $MACHINE1_IP"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

if [ ! -f "docker-compose-centraloffice.yml" ]; then
    print_error "docker-compose-centraloffice.yml not found"
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

if ping -c 1 -W 2 $MACHINE2_IP &> /dev/null; then
    print_info "✓ Can reach Machine 2 ($MACHINE2_IP)"
else
    print_warn "✗ Cannot reach Machine 2 ($MACHINE2_IP)"
    print_warn "Machine 2 components will not be able to connect"
fi

print_info "Pre-flight checks passed!"
echo ""

# ==========================================
# Start Deployment
# ==========================================

print_stage "Creating Docker networks and preparing containers..."
docker compose -f docker-compose-centraloffice.yml up --no-start
echo ""

# ==========================================
# Stage 1/6: MySQL
# ==========================================
print_stage "Stage 1/6: Starting MySQL database..."
docker compose -f docker-compose-centraloffice.yml up -d mysql
wait_for_healthy "mysql" 60
echo ""

# ==========================================
# Stage 2/6: 5G Core Network Functions
# ==========================================
print_stage "Stage 2/6: Starting 5G Core Network Functions..."
docker compose -f docker-compose-centraloffice.yml up -d nrf smf pcf nssf amf udm udr ausf
wait_for_service "nrf" 30
wait_for_service "amf" 30
wait_for_service "smf" 30
print_info "Waiting for services to initialize..."
sleep 5
echo ""

# ==========================================
# Stage 3/6: Primary UPF and External DN
# ==========================================
print_stage "Stage 3/6: Starting Primary UPF and External DN..."
docker compose -f docker-compose-centraloffice.yml up -d upf ext_dn
wait_for_service "upf" 30
wait_for_service "ext_dn" 30
print_info "Waiting for UPF initialization..."
sleep 5
echo ""

# ==========================================
# Stage 4/6: Unified CU (replaces CU-CP + CU-UP)
# ==========================================
print_stage "Stage 4/6: Starting Unified CU (Central Unit)..."
docker compose -f docker-compose-centraloffice.yml up -d cu
wait_for_service "cu" 30
print_info "Waiting for CU to initialize SCTP sockets (NGAP + F1-C)..."
sleep 15

# Verify CU is listening
print_info "CU SCTP listening sockets:"
docker exec cu ss -Slnp 2>/dev/null | grep -E "38472|38412" || print_warn "  CU SCTP sockets not yet ready"
echo ""

# ==========================================
# Stage 5/6: FlexRIC (Near-RT RIC)
# ==========================================
print_stage "Stage 5/6: Starting FlexRIC (Near-RT RIC)..."
docker compose -f docker-compose-centraloffice.yml up -d flexric
wait_for_service "flexric" 30
print_info "Waiting for FlexRIC to initialize..."
sleep 10
echo ""

# ==========================================
# Stage 6/6: SCTP Routing Fix (THE KEY FIX)
# ==========================================
print_stage "Stage 6/6: Configuring SCTP routing for cross-machine access..."
echo ""
setup_sctp_routing
echo ""
verify_sctp_routing
echo ""

# ==========================================
# Final status check
# ==========================================
print_stage "Checking final status..."
echo ""
docker compose -f docker-compose-centraloffice.yml ps
echo ""

print_info "================================================"
print_info "Machine 1 Deployment Complete!"
print_info "================================================"
echo ""

# --- Service reachability checks ---
if timeout 3 bash -c "echo > /dev/tcp/${MACHINE1_IP}/9090" 2>/dev/null; then
    print_info "✓ NRF is reachable on ${MACHINE1_IP}:9090"
else
    print_warn "✗ NRF is NOT reachable on ${MACHINE1_IP}:9090"
fi

print_info ""
print_info "CU SCTP listening sockets:"
docker exec cu ss -Slnp 2>/dev/null | grep -E "38472|38462|38412" || print_warn "  CU SCTP sockets not found"

print_info ""
print_info "AMF SCTP listening sockets:"
docker exec amf ss -Slnp 2>/dev/null | grep "38412" || print_warn "  AMF SCTP socket not found"

print_info ""
print_info "FlexRIC SCTP listening sockets:"
docker exec flexric ss -Slnp 2>/dev/null | grep -E "36422|36421" || print_warn "  FlexRIC SCTP socket not found"

echo ""
print_info "Next Steps:"
echo "  1. From Machine 2, test SCTP connectivity:"
echo "     ncat -v --sctp ${MACHINE1_IP} 38472    # F1-C to CU"
echo "     ncat -v --sctp ${MACHINE1_IP} 38412    # NGAP to AMF"
echo "     ncat -v --sctp ${MACHINE1_IP} 36421    # E2AP to FlexRIC"
echo "     ncat -v --sctp ${MACHINE1_IP} 36422    # E2AP to FlexRIC"
echo ""
echo "  2. Deploy Machine 2 (Edge RAN) on $MACHINE2_IP:"
echo "     ./deploy-edge.sh"
echo ""
echo "  To stop: docker compose -f docker-compose-centraloffice.yml down"
echo ""

read -p "Show live logs? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker compose -f docker-compose-centraloffice.yml logs -f
fi
