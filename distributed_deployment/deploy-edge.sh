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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_stage() {
    echo -e "${BLUE}[STAGE]${NC} $1"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

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
# SCTP Routing Fix Functions for Machine 2
# ==========================================
# The DU exposes port 500/sctp for F1-C. Docker creates a DNAT rule
# pointing to the DU's IP on the FIRST network listed in docker-compose
# (f1c_net). For the DU, this is actually correct since the DU binds
# F1-C to its f1c_net IP. However, docker-proxy cannot handle SCTP,
# so we need to verify the kernel nftables rules are correct and
# fix them if Docker's DNAT target IP/port is wrong.
#
# Additionally, the Edge CU-UP initiates an outbound E1 SCTP connection
# to Machine 1's CU-CP (192.168.0.193:38462). Since it's client-side
# (outbound), it doesn't need inbound SCTP port mapping — it just needs
# a route to Machine 1, which exists via the default gateway.

setup_edge_sctp_routing() {
    print_stage "Setting up SCTP routing rules for Edge components..."

    # -------------------------------------------------------
    # Ensure SCTP kernel module is loaded
    # -------------------------------------------------------
    if ! lsmod | grep -q "^sctp"; then
        print_info "Loading SCTP kernel module..."
        sudo modprobe sctp
    fi
    print_info "✓ SCTP kernel module is loaded"

    # Disable conntrack checksum verification for SCTP compatibility
    if [ -f /proc/sys/net/netfilter/nf_conntrack_checksum ]; then
        sudo sysctl -w net.netfilter.nf_conntrack_checksum=0 > /dev/null 2>&1
        print_info "✓ Disabled conntrack checksum verification for SCTP compatibility"
    fi

    # -------------------------------------------------------
    # Detect container IPs from Docker inspect
    # -------------------------------------------------------
    local PROJECT_PREFIX="distributed_deployment_"

    # DU IPs
    local DU_F1C_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}f1c_net.IPAddress}}" du_1 2>/dev/null || echo "")
    local DU_CORE_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}core_net.IPAddress}}" du_1 2>/dev/null || echo "")

    # Edge CU-UP IPs
    local CUUP1_CORE_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}core_net.IPAddress}}" cuup_1 2>/dev/null || echo "")
    local CUUP1_E1_IP=$(docker inspect -f "{{.NetworkSettings.Networks.${PROJECT_PREFIX}e1_net.IPAddress}}" cuup_1 2>/dev/null || echo "")

    # Fallback: try without project prefix
    if [ -z "$DU_F1C_IP" ]; then
        DU_F1C_IP=$(docker inspect -f '{{.NetworkSettings.Networks.f1c_net.IPAddress}}' du_1 2>/dev/null || echo "")
    fi
    if [ -z "$DU_CORE_IP" ]; then
        # DU is NOT on core_net — this is expected
        DU_CORE_IP=""
    fi
    if [ -z "$CUUP1_CORE_IP" ]; then
        CUUP1_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' cuup_1 2>/dev/null || echo "")
    fi
    if [ -z "$CUUP1_E1_IP" ]; then
        CUUP1_E1_IP=$(docker inspect -f '{{.NetworkSettings.Networks.e1_net.IPAddress}}' cuup_1 2>/dev/null || echo "")
    fi

    # Last resort: parse from docker inspect JSON
    if [ -z "$DU_F1C_IP" ]; then
        DU_F1C_IP=$(docker inspect du_1 2>/dev/null | grep -A5 'f1c_net' | grep 'IPAddress' | head -1 | grep -oP '"\K[0-9.]+' || echo "")
    fi
    if [ -z "$CUUP1_E1_IP" ]; then
        CUUP1_E1_IP=$(docker inspect cuup_1 2>/dev/null | grep -A5 'e1_net' | grep 'IPAddress' | head -1 | grep -oP '"\K[0-9.]+' || echo "")
    fi

    print_info "Container IPs detected:"
    print_info "  DU     (f1c_net):  ${DU_F1C_IP:-NOT FOUND}"
    print_info "  CU-UP  (core_net): ${CUUP1_CORE_IP:-NOT FOUND}"
    print_info "  CU-UP  (e1_net):   ${CUUP1_E1_IP:-NOT FOUND}"

    # -------------------------------------------------------
    # 1. DU F1-C: 192.168.0.243:500/sctp → DU on f1c_net:500
    # -------------------------------------------------------
    # The DU binds F1-C SCTP to its f1c_net IP (192.168.73.151) port 500.
    # Docker-compose maps 192.168.0.243:500:500/sctp.
    #
    # Docker creates DNAT to the DU's IP on the FIRST network listed.
    # In docker-compose-edge.yml, the DU's networks are listed as:
    #   f1c_net, f1u_net, ran_net
    # So Docker should DNAT to f1c_net IP:500 — which is CORRECT.
    #
    # However, we still need to verify because Docker may pick a
    # different primary IP. Also, docker-proxy doesn't handle SCTP,
    # but the kernel nftables DNAT rule does work for SCTP.

    if [ -n "$DU_F1C_IP" ]; then
        print_info ""
        print_info "--- DU F1-C (F1AP) SCTP [3GPP TS 38.472] ---"

        # Check if Docker created the correct DNAT rule
        if sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep -q "sctp dport 500.*dnat to ${DU_F1C_IP}:500"; then
            print_info "  ✓ DU F1-C DNAT rule exists and is correct"
            print_info "    ${MACHINE2_IP}:500/sctp → ${DU_F1C_IP}:500 (f1c_net/br-f1c)"
        else
            # Check if Docker created a DNAT to the wrong IP
            local WRONG_DU_HANDLES=$(sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep "sctp dport 500.*dnat to" | grep -v "dnat to ${DU_F1C_IP}:500" | grep -oP 'handle \K\d+')
            for handle in $WRONG_DU_HANDLES; do
                print_info "  Removing incorrect DU F1-C DNAT rule (handle $handle)..."
                sudo nft delete rule ip nat DOCKER handle $handle
            done

            # Add correct DNAT rule
            print_info "  Adding correct DU F1-C DNAT: ${MACHINE2_IP}:500 → ${DU_F1C_IP}:500"
            sudo nft add rule ip nat DOCKER iifname != "br-f1c" meta l4proto sctp ip daddr ${MACHINE2_IP} sctp dport 500 counter dnat to ${DU_F1C_IP}:500
        fi

        # Verify FORWARD accept rule exists for DU F1-C
        if ! sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep -q "oifname \"br-f1c\".*sctp.*daddr ${DU_F1C_IP}.*sctp dport 500.*accept"; then
            print_info "  Adding DU F1-C FORWARD accept: br-f1c → ${DU_F1C_IP}:500"
            sudo nft add rule ip filter DOCKER iifname != "br-f1c" oifname "br-f1c" meta l4proto sctp ip daddr ${DU_F1C_IP} sctp dport 500 counter accept
        else
            print_info "  ✓ DU F1-C FORWARD accept rule exists"
        fi

        # Ensure DOCKER-BRIDGE chain jumps to DOCKER for br-f1c traffic
        if ! sudo nft list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep -q 'oifname "br-f1c".*jump DOCKER'; then
            print_info "  Adding DOCKER-BRIDGE jump for br-f1c..."
            sudo nft add rule ip filter DOCKER-BRIDGE oifname "br-f1c" counter jump DOCKER
        fi

        print_info "  ✓ DU F1-C routing: ${MACHINE2_IP}:500/sctp → ${DU_F1C_IP}:500 (br-f1c)"
    else
        print_warn "  DU f1c_net IP not found — skipping DU F1-C SCTP routing"
    fi

    # -------------------------------------------------------
    # 2. Edge CU-UP E1: Outbound SCTP to Machine 1 (192.168.0.193:38462)
    # -------------------------------------------------------
    # The Edge CU-UP initiates an SCTP connection to CU-CP on Machine 1.
    # This is CLIENT-SIDE (outbound), so no inbound DNAT is needed.
    # We just need to ensure the CU-UP container can route to Machine 1.
    #
    # The CU-UP is on e1_net (192.168.75.144). Its default gateway is
    # the bridge gateway (192.168.75.129), which is the host. The host
    # has a route to 192.168.0.193 via the physical interface.
    #
    # However, Docker's POSTROUTING masquerade rule will SNAT the
    # CU-UP's source IP (192.168.75.144) to the host's physical IP
    # when the packet leaves via the physical interface. This is correct
    # for outbound connections.

    if [ -n "$CUUP1_E1_IP" ]; then
        print_info ""
        print_info "--- Edge CU-UP E1AP SCTP (outbound to Machine 1) [3GPP TS 38.463] ---"

        # Verify the CU-UP can reach Machine 1
        if docker exec cuup_1 ping -c 1 -W 2 ${MACHINE1_IP} > /dev/null 2>&1; then
            print_info "  ✓ Edge CU-UP can reach Machine 1 (${MACHINE1_IP})"
        else
            print_warn "  ✗ Edge CU-UP cannot ping Machine 1 — checking routing..."

            # Add a route inside the CU-UP container if needed
            # The container should already have a default route via the bridge gateway
            local CUUP_GW=$(docker exec cuup_1 ip route show default 2>/dev/null | awk '{print $3}' | head -1)
            if [ -n "$CUUP_GW" ]; then
                print_info "  CU-UP default gateway: $CUUP_GW"
            else
                print_warn "  CU-UP has no default route — adding one via e1_net gateway..."
                docker exec cuup_1 ip route add default via 192.168.75.129 2>/dev/null || true
            fi
        fi

        # Ensure MASQUERADE exists for e1_net outbound traffic
        if sudo nft list chain ip nat POSTROUTING 2>/dev/null | grep -q 'oifname != "br-e1".*192.168.75.128/26.*masquerade'; then
            print_info "  ✓ MASQUERADE rule exists for e1_net outbound traffic"
        else
            print_warn "  Adding MASQUERADE for e1_net outbound traffic..."
            sudo nft add rule ip nat POSTROUTING oifname != "br-e1" ip saddr 192.168.75.128/26 counter masquerade
        fi

        print_info "  ✓ Edge CU-UP E1: ${CUUP1_E1_IP} → ${MACHINE1_IP}:38462/sctp (outbound, via host routing)"
    else
        print_warn "  Edge CU-UP e1_net IP not found — skipping E1 routing check"
    fi

    # -------------------------------------------------------
    # 3. Verify raw table doesn't block our traffic
    # -------------------------------------------------------
    print_info ""
    print_info "--- Raw table verification ---"

    if sudo nft list chain ip raw PREROUTING 2>/dev/null | grep -q "ip daddr ${MACHINE2_IP}.*drop"; then
        print_warn "  WARNING: Raw table has DROP rule for ${MACHINE2_IP} — removing it"
        local RAW_HANDLES=$(sudo nft -a list chain ip raw PREROUTING 2>/dev/null | grep "ip daddr ${MACHINE2_IP}.*drop" | grep -oP 'handle \K\d+')
        for handle in $RAW_HANDLES; do
            sudo nft delete rule ip raw PREROUTING handle $handle
        done
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
    print_info "  DU F1-C (inbound):       ${MACHINE2_IP}:500/sctp → ${DU_F1C_IP:-?}:500 (br-f1c) [TS 38.472]"
    print_info "  CU-UP E1 (outbound):     ${CUUP1_E1_IP:-?} → ${MACHINE1_IP}:38462/sctp [TS 38.463]"
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

    # Test F1-C to CU-CP on Machine 1
    if command -v ncat &> /dev/null; then
        if timeout 3 ncat --sctp ${MACHINE1_IP} 38472 < /dev/null 2>/dev/null; then
            print_info "  ✓ F1-C SCTP to Machine 1 CU-CP (${MACHINE1_IP}:38472) — REACHABLE"
        else
            print_warn "  ✗ F1-C SCTP to Machine 1 CU-CP (${MACHINE1_IP}:38472) — NOT REACHABLE"
            print_warn "    Ensure deploy-centraloffice.sh ran setup_sctp_routing on Machine 1"
        fi

        # Test E1 to CU-CP on Machine 1
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

# Check Docker is running
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
# Check current IP
ip_addresses=$(hostname -I)
for ip in $ip_addresses; do
    if [ "$ip" == "$MACHINE2_IP" ]; then
        CURRENT_IP="$ip"
        break
    fi
done

if [ "$CURRENT_IP" != "$MACHINE2_IP" ]; then
    print_warn "Current IP is $CURRENT_IP, expected $MACHINE2_IP"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check docker-compose file exists
if [ ! -f "docker-compose-edge.yml" ]; then
    print_error "docker-compose-edge.yml not found"
    exit 1
fi

# Check if configs exist
if [ ! -d "configs" ]; then
    print_error "configs directory not found"
    exit 1
fi

# Check SCTP kernel module
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

# Create networks and prepare containers
print_stage "Creating Docker networks and preparing containers..."
docker compose -f docker-compose-edge.yml up --no-start
echo ""

# Stage 1: Edge UPF
print_stage "Stage 1/7: Starting Edge UPF and External DN..."
docker compose -f docker-compose-edge.yml up -d upf_1 ext_dn_1
wait_for_service "upf_1" 30
wait_for_service "ext_dn_1" 30
sleep 10
echo ""

# Stage 2: Edge CU-UP
print_stage "Stage 2/7: Starting Edge CU-UP..."
docker compose -f docker-compose-edge.yml up -d cuup_1
wait_for_service "cuup_1" 30
sleep 10
echo ""

# Stage 3: DU with RFSimulator
print_stage "Stage 3/7: Starting DU with RFSimulator..."
docker compose -f docker-compose-edge.yml up -d du_1
wait_for_service "du_1" 30
sleep 10

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
print_stage "Stage 4/7: Configuring SCTP routing for Edge components..."
echo ""
setup_edge_sctp_routing
echo ""

# Verify SCTP routing
verify_edge_sctp_routing
echo ""

# Stage 5: FlexRIC
print_stage "Stage 5/7: Starting FlexRIC (Near-RT RIC)..."
docker compose -f docker-compose-edge.yml up -d flexric
wait_for_service "flexric" 30
sleep 10
echo ""

# Stage 6: User Equipment (10 UEs)
print_stage "Stage 6/7: Starting 10 User Equipment instances..."
docker compose -f docker-compose-edge.yml up -d ue_1
wait_for_service "ue_1" 30
echo ""

# Stage 7: Wait for UE connections
print_stage "Stage 7/7: Waiting for UE connections..."
print_info "Waiting 30 seconds for UEs to connect and register..."
sleep 30
echo ""

# Check UE connections
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
print_stage
