#!/bin/bash

# deploy-centraloffice.sh - Deploy Core Network + CU-CP + CU-UP on Machine 1
# Deploy on PC: 192.168.0.193

set -e

MACHINE1_IP="192.168.0.193"
MACHINE2_IP="192.168.0.243"

echo "================================================"
echo "Machine 1: Core Network + Central RAN Deployment"
echo "================================================"
echo "Machine 1 (This PC): $MACHINE1_IP"
echo "Machine 2 (Edge PC): $MACHINE2_IP"
echo ""
echo "Components on this machine:"
echo "  - 5G Core Network (MySQL, NRF, AMF, SMF, UDM, UDR, AUSF, PCF, NSSF)"
echo "  - Primary UPF + Ext DN"
echo "  - CU-CP (Central Unit Control Plane)"
echo "  - CU-UP (Central Unit User Plane - Primary)"
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
# SCTP Routing Fix
# ==========================================
# Docker creates nftables DNAT rules for /sctp port mappings, but:
# 1. DNATs to the container's IP on the FIRST network (core_net)
#    instead of the network where SCTP actually binds (f1c_net, e1_net)
# 2. Uses 'nft add' which appends AFTER catch-all DROP rules
# 3. docker-proxy cannot handle SCTP (but kernel nftables can)
#
# This function:
# - Removes ALL old/incorrect SCTP rules (including duplicates from reruns)
# - Auto-detects actual container IPs and listening ports
# - INSERTs correct rules at the TOP of chains / BEFORE catch-all DROPs

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
    # Detect container IPs
    # -------------------------------------------------------
    local PROJECT_PREFIX="distributed_deployment_"
    local AMF_CORE_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}core_net.IPAddress}}" amf 2>/dev/null || echo "")
    local CUCP_CORE_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}core_net.IPAddress}}" cucp 2>/dev/null || echo "")
    local CUCP_F1C_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}f1c_net.IPAddress}}" cucp 2>/dev/null || echo "")
    local CUCP_E1_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}e1_net.IPAddress}}" cucp 2>/dev/null || echo "")

    # Fallback without prefix
    [ -z "$AMF_CORE_IP" ] && AMF_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' amf 2>/dev/null || echo "")
    [ -z "$CUCP_CORE_IP" ] && CUCP_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' cucp 2>/dev/null || echo "")
    [ -z "$CUCP_F1C_IP" ] && CUCP_F1C_IP=$(docker inspect -f '{{.NetworkSettings.Networks.f1c_net.IPAddress}}' cucp 2>/dev/null || echo "")
    [ -z "$CUCP_E1_IP" ] && CUCP_E1_IP=$(docker inspect -f '{{.NetworkSettings.Networks.e1_net.IPAddress}}' cucp 2>/dev/null || echo "")

    # Auto-detect actual listening ports from CU-CP container
    local CUCP_F1C_PORT=$(docker exec cucp ss -Slnp 2>/dev/null \
        | grep "LISTEN" \
        | grep "${CUCP_F1C_IP}" \
        | awk '{print $5}' \
        | grep -o '[0-9]*$' \
        | head -1)
    [ -z "$CUCP_F1C_PORT" ] && CUCP_F1C_PORT="38472"

    local CUCP_E1_PORT=$(docker exec cucp ss -Slnp 2>/dev/null \
        | grep "LISTEN" \
        | grep "${CUCP_E1_IP}" \
        | awk '{print $5}' \
        | grep -o '[0-9]*$' \
        | head -1)
    [ -z "$CUCP_E1_PORT" ] && CUCP_E1_PORT="38462"

    [ -z "$CUCP_F1C_PORT" ] && CUCP_F1C_PORT="38472"
    [ -z "$CUCP_E1_PORT" ] && CUCP_E1_PORT="38462"

    print_info "Container IPs and ports detected:"
    print_info "  AMF   (core_net): ${AMF_CORE_IP:-NOT FOUND}"
    print_info "  CU-CP (core_net): ${CUCP_CORE_IP:-NOT FOUND}"
    print_info "  CU-CP (f1c_net):  ${CUCP_F1C_IP:-NOT FOUND}:${CUCP_F1C_PORT}"
    print_info "  CU-CP (e1_net):   ${CUCP_E1_IP:-NOT FOUND}:${CUCP_E1_PORT}"

    if [ -z "$CUCP_F1C_IP" ] || [ -z "$CUCP_E1_IP" ] || [ -z "$AMF_CORE_IP" ]; then
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
        sudo nft insert rule ip nat DOCKER iifname != "br-core" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 38412 counter dnat to ${AMF_CORE_IP}:38412
    fi

    # -------------------------------------------------------
    # 2. CU-CP F1-C — Remove ALL old, insert correct at TOP
    # -------------------------------------------------------
    print_info ""
    print_info "--- CU-CP F1-C (F1AP) SCTP [TS 38.472] ---"

    # Remove ALL existing F1-C DNAT rules (any target IP/port including port 501)
    while true; do
        local H=$(sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep "sctp dport 38472" | head -1 | grep -oP 'handle \K\d+' || echo "")
        [ -z "$H" ] && break
        print_info "  Removing old F1-C DNAT rule (handle $H)..."
        sudo nft delete rule ip nat DOCKER handle $H
    done

    # INSERT correct DNAT at TOP of chain
    sudo nft insert rule ip nat DOCKER iifname != "br-f1c" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 38472 counter dnat to ${CUCP_F1C_IP}:${CUCP_F1C_PORT}
    print_info "  ✓ F1-C DNAT INSERTED: ${MACHINE1_IP}:38472 → ${CUCP_F1C_IP}:${CUCP_F1C_PORT}"

    # Remove ALL existing F1-C FORWARD rules (port 501 AND port 38472)
    while true; do
        local H=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep "br-f1c.*sctp" | head -1 | grep -oP 'handle \K\d+' || echo "")
        [ -z "$H" ] && break
        print_info "  Removing old F1-C FORWARD rule (handle $H)..."
        sudo nft delete rule ip filter DOCKER handle $H
    done

    # INSERT FORWARD accept BEFORE the catch-all DROP for br-f1c
    local F1C_DROP=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep 'iifname != "br-f1c" oifname "br-f1c" counter.*drop' | grep -oP 'handle \K\d+' | head -1 || echo "")
    if [ -n "$F1C_DROP" ]; then
        sudo nft insert rule ip filter DOCKER position $F1C_DROP iifname != "br-f1c" oifname "br-f1c" meta l4proto sctp ip daddr ${CUCP_F1C_IP} sctp dport ${CUCP_F1C_PORT} counter accept
        print_info "  ✓ F1-C FORWARD accept INSERTED before drop (position $F1C_DROP)"
    else
        sudo nft insert rule ip filter DOCKER iifname != "br-f1c" oifname "br-f1c" meta l4proto sctp ip daddr ${CUCP_F1C_IP} sctp dport ${CUCP_F1C_PORT} counter accept
        print_info "  ✓ F1-C FORWARD accept INSERTED at top"
    fi

    # Ensure DOCKER-BRIDGE jumps to DOCKER for br-f1c
    if ! sudo nft list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep -q 'oifname "br-f1c".*jump DOCKER'; then
        sudo nft add rule ip filter DOCKER-BRIDGE oifname "br-f1c" counter jump DOCKER
        print_info "  ✓ Added DOCKER-BRIDGE jump for br-f1c"
    fi

    # -------------------------------------------------------
    # 3. CU-CP E1AP — Remove ALL old, insert correct at TOP
    # -------------------------------------------------------
    print_info ""
    print_info "--- CU-CP E1AP SCTP [TS 38.463] ---"

    # Remove ALL existing E1 DNAT rules
    while true; do
        local H=$(sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep "sctp dport 38462" | head -1 | grep -oP 'handle \K\d+' || echo "")
        [ -z "$H" ] && break
        print_info "  Removing old E1 DNAT rule (handle $H)..."
        sudo nft delete rule ip nat DOCKER handle $H
    done

    # INSERT correct DNAT at TOP
    sudo nft insert rule ip nat DOCKER iifname != "br-e1" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 38462 counter dnat to ${CUCP_E1_IP}:${CUCP_E1_PORT}
    print_info "  ✓ E1 DNAT INSERTED: ${MACHINE1_IP}:38462 → ${CUCP_E1_IP}:${CUCP_E1_PORT}"

    # Remove ALL existing E1 FORWARD rules
    while true; do
        local H=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep "br-e1.*sctp" | head -1 | grep -oP 'handle \K\d+' || echo "")
        [ -z "$H" ] && break
        print_info "  Removing old E1 FORWARD rule (handle $H)..."
        sudo nft delete rule ip filter DOCKER handle $H
    done

    # INSERT FORWARD accept BEFORE the catch-all DROP for br-e1
    local E1_DROP=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep 'iifname != "br-e1" oifname "br-e1" counter.*drop' | grep -oP 'handle \K\d+' | head -1 || echo "")
    if [ -n "$E1_DROP" ]; then
        sudo nft insert rule ip filter DOCKER position $E1_DROP iifname != "br-e1" oifname "br-e1" meta l4proto sctp ip daddr ${CUCP_E1_IP} sctp dport ${CUCP_E1_PORT} counter accept
        print_info "  ✓ E1 FORWARD accept INSERTED before drop (position $E1_DROP)"
    else
        sudo nft insert rule ip filter DOCKER iifname != "br-e1" oifname "br-e1" meta l4proto sctp ip daddr ${CUCP_E1_IP} sctp dport ${CUCP_E1_PORT} counter accept
        print_info "  ✓ E1 FORWARD accept INSERTED at top"
    fi

    # Ensure DOCKER-BRIDGE jumps to DOCKER for br-e1
    if ! sudo nft list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep -q 'oifname "br-e1".*jump DOCKER'; then
        sudo nft add rule ip filter DOCKER-BRIDGE oifname "br-e1" counter jump DOCKER
        print_info "  ✓ Added DOCKER-BRIDGE jump for br-e1"
    fi

    # -------------------------------------------------------
    # 4. Raw table check
    # -------------------------------------------------------
    print_info ""
    if sudo nft list chain ip raw PREROUTING 2>/dev/null | grep -q "ip daddr ${MACHINE1_IP}.*drop"; then
        print_warn "  Raw table has DROP for ${MACHINE1_IP} — removing..."
        local RAW_H=$(sudo nft -a list chain ip raw PREROUTING 2>/dev/null | grep "ip daddr ${MACHINE1_IP}.*drop" | grep -oP 'handle \K\d+')
        [ -n "$RAW_H" ] && sudo nft delete rule ip raw PREROUTING handle $RAW_H
    else
        print_info "  ✓ Raw table OK"
    fi

    # -------------------------------------------------------
    # Summary
    # -------------------------------------------------------
    print_info ""
    print_info "SCTP routing setup complete!"
    print_info "  AMF  NGAP:  ${MACHINE1_IP}:38412 → ${AMF_CORE_IP}:38412 (br-core)"
    print_info "  CU-CP F1-C: ${MACHINE1_IP}:38472 → ${CUCP_F1C_IP}:${CUCP_F1C_PORT} (br-f1c)"
    print_info "  CU-CP E1:   ${MACHINE1_IP}:38462 → ${CUCP_E1_IP}:${CUCP_E1_PORT} (br-e1)"
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
    print_info "=== CU-CP SCTP listening sockets ==="
    docker exec cucp ss -Slnp 2>/dev/null || print_warn "  Could not check CU-CP sockets"
    echo ""
    print_info "=== AMF SCTP listening sockets ==="
    docker exec amf ss -Slnp 2>/dev/null || print_warn "  Could not check AMF sockets"
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

print_stage "Stage 1/6: Starting MySQL database..."
docker compose -f docker-compose-centraloffice.yml up -d mysql
wait_for_healthy "mysql" 60
echo ""

print_stage "Stage 2/6: Starting 5G Core Network Functions..."
docker compose -f docker-compose-centraloffice.yml up -d nrf smf pcf nssf amf udm udr ausf
wait_for_service "nrf" 30
wait_for_service "amf" 30
wait_for_service "smf" 30
print_info "Waiting for services to initialize..."
sleep 5
echo ""

print_stage "Stage 3/6: Starting Primary UPF and External DN..."
docker compose -f docker-compose-centraloffice.yml up -d upf ext_dn
wait_for_service "upf" 30
wait_for_service "ext_dn" 30
print_info "Waiting for UPF initialization..."
sleep 5
echo ""

print_stage "Stage 4/6: Starting CU-CP (Central Unit Control Plane)..."
docker compose -f docker-compose-centraloffice.yml up -d cucp
wait_for_service "cucp" 30
print_info "Waiting for CU-CP to initialize SCTP sockets..."
sleep 15
echo ""

print_stage "Stage 5/6: Starting CU-UP (Central Unit User Plane)..."
docker compose -f docker-compose-centraloffice.yml up -d cuup
wait_for_service "cuup" 30
sleep 5
echo ""

# ==========================================
# Stage 6: SCTP Routing Fix (THE KEY FIX)
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

if timeout 3 bash -c "echo > /dev/tcp/${MACHINE1_IP}/9090" 2>/dev/null; then
    print_info "✓ NRF is reachable on ${MACHINE1_IP}:9090"
else
    print_warn "✗ NRF is NOT reachable on ${MACHINE1_IP}:9090"
fi

print_info "CU-CP SCTP listening sockets:"
docker exec cucp ss -Slnp 2>/dev/null | grep -E "38472|38462" || print_warn "  CU-CP SCTP sockets not found"

print_info "AMF SCTP listening sockets:"
docker exec amf ss -Slnp 2>/dev/null | grep "38412" || print_warn "  AMF SCTP socket not found"

echo ""
print_info "Next Steps:"
echo "  1. From Machine 2, test SCTP connectivity:"
echo "     ncat --sctp ${MACHINE1_IP} 38472    # F1-C to CU-CP"
echo "     ncat --sctp ${MACHINE1_IP} 38462    # E1 to CU-CP"
echo ""
echo "  2. Deploy Machine 2 (Edge RAN) on $MACHINE2_IP:"
echo "     ./deploy-edge.sh"
echo ""
echo "  To stop: ./stop.sh"
echo ""

read -p "Show live logs? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker compose -f docker-compose-centraloffice.yml logs -f
fi
