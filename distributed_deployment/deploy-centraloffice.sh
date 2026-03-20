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
            # No healthcheck defined, just check if running
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
# SCTP Routing Fix Functions
# ==========================================

setup_sctp_routing() {
    # This function adds nftables rules to properly route SCTP traffic
    # to containers that bind SCTP on non-primary Docker network interfaces.
    #
    # Problem: Docker creates DNAT rules pointing to the container's IP on
    # the FIRST network listed in docker-compose. But SCTP services may
    # bind to a DIFFERENT network interface inside the container.
    # Additionally, docker-proxy (userland) cannot handle SCTP at all.
    #
    # Solution: We replace Docker's incorrect DNAT rules with correct ones
    # that point to the right container IP and port.

    print_stage "Setting up SCTP routing rules for cross-machine connectivity..."

    # -------------------------------------------------------
    # Get container IPs from Docker inspect
    # -------------------------------------------------------
    local AMF_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.distributed_deployment_core_net.IPAddress}}' amf 2>/dev/null || echo "")
    local CUCP_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.distributed_deployment_core_net.IPAddress}}' cucp 2>/dev/null || echo "")
    local CUCP_F1C_IP=$(docker inspect -f '{{.NetworkSettings.Networks.distributed_deployment_f1c_net.IPAddress}}' cucp 2>/dev/null || echo "")
    local CUCP_E1_IP=$(docker inspect -f '{{.NetworkSettings.Networks.distributed_deployment_e1_net.IPAddress}}' cucp 2>/dev/null || echo "")

    # Fallback: try without project prefix
    if [ -z "$AMF_CORE_IP" ]; then
        AMF_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' amf 2>/dev/null || echo "")
    fi
    if [ -z "$CUCP_CORE_IP" ]; then
        CUCP_CORE_IP=$(docker inspect -f '{{.NetworkSettings.Networks.core_net.IPAddress}}' cucp 2>/dev/null || echo "")
    fi
    if [ -z "$CUCP_F1C_IP" ]; then
        CUCP_F1C_IP=$(docker inspect -f '{{.NetworkSettings.Networks.f1c_net.IPAddress}}' cucp 2>/dev/null || echo "")
    fi
    if [ -z "$CUCP_E1_IP" ]; then
        CUCP_E1_IP=$(docker inspect -f '{{.NetworkSettings.Networks.e1_net.IPAddress}}' cucp 2>/dev/null || echo "")
    fi

    print_info "Container IPs detected:"
    print_info "  AMF  (core_net): ${AMF_CORE_IP:-NOT FOUND}"
    print_info "  CU-CP (core_net): ${CUCP_CORE_IP:-NOT FOUND}"
    print_info "  CU-CP (f1c_net):  ${CUCP_F1C_IP:-NOT FOUND}"
    print_info "  CU-CP (e1_net):   ${CUCP_E1_IP:-NOT FOUND}"

    if [ -z "$CUCP_F1C_IP" ] || [ -z "$CUCP_E1_IP" ] || [ -z "$AMF_CORE_IP" ]; then
        print_error "Could not detect container IPs. SCTP routing setup failed."
        print_error "Make sure containers are running and network names are correct."
        return 1
    fi

    # -------------------------------------------------------
    # 1. AMF N2/NGAP: 192.168.0.193:38412 → AMF container on core_net
    #    AMF binds NGAP to its core_net IP (eth0), so Docker's default
    #    DNAT is actually correct here. But we need to ensure the raw
    #    table doesn't interfere and docker-proxy bypass works.
    # -------------------------------------------------------
    print_info "Configuring AMF NGAP (N2) SCTP routing..."
    
    # The AMF binds to core_net IP, and Docker's DNAT already points there.
    # We just need to make sure the kernel handles SCTP without docker-proxy.
    # Docker's nftables DNAT rule: 192.168.0.193:38412 → ${AMF_CORE_IP}:38412
    # This is correct, so we leave it. But we verify it exists:
    if sudo nft list chain ip nat DOCKER 2>/dev/null | grep -q "sctp dport 38412.*dnat to ${AMF_CORE_IP}:38412"; then
        print_info "  ✓ AMF NGAP DNAT rule exists and is correct"
    else
        print_warn "  Adding AMF NGAP DNAT rule..."
        sudo nft add rule ip nat DOCKER iifname != "br-core" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 38412 counter dnat to ${AMF_CORE_IP}:38412
    fi

    # -------------------------------------------------------
    # 2. CU-CP F1-C: 192.168.0.193:38472 → CU-CP on f1c_net:501
    #    CU-CP binds F1-C SCTP to f1c_net IP (192.168.73.140) port 501
    #    Docker's DNAT incorrectly points to core_net IP port 38472
    # -------------------------------------------------------
    print_info "Configuring CU-CP F1-C SCTP routing..."

    # Remove Docker's incorrect DNAT rule (points to core_net IP:38472)
    # We need to delete the rule that DNATs to the wrong IP
    local WRONG_F1C_RULE=$(sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep "sctp dport 38472.*dnat to ${CUCP_CORE_IP}:38472" | grep -oP 'handle \K\d+')
    if [ -n "$WRONG_F1C_RULE" ]; then
        print_info "  Removing incorrect F1-C DNAT rule (handle $WRONG_F1C_RULE)..."
        sudo nft delete rule ip nat DOCKER handle $WRONG_F1C_RULE
    fi

    # Add correct DNAT rule: external:38472 → f1c_net_IP:501
    print_info "  Adding correct F1-C DNAT: ${MACHINE1_IP}:38472 → ${CUCP_F1C_IP}:501"
    sudo nft add rule ip nat DOCKER iifname != "br-f1c" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 38472 counter dnat to ${CUCP_F1C_IP}:501

    # Remove Docker's incorrect FORWARD accept rule (for core_net)
    local WRONG_F1C_FWD=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep "sctp.*daddr ${CUCP_CORE_IP}.*sctp dport 38472" | grep -oP 'handle \K\d+')
    if [ -n "$WRONG_F1C_FWD" ]; then
        print_info "  Removing incorrect F1-C FORWARD rule (handle $WRONG_F1C_FWD)..."
        sudo nft delete rule ip filter DOCKER handle $WRONG_F1C_FWD
    fi

    # Add correct FORWARD accept rule for f1c_net
    print_info "  Adding F1-C FORWARD accept rule for br-f1c..."
    sudo nft add rule ip filter DOCKER iifname != "br-f1c" oifname "br-f1c" meta l4proto sctp ip daddr ${CUCP_F1C_IP} sctp dport 501 counter accept

    # Add DOCKER-BRIDGE jump for br-f1c (if not already present)
    if ! sudo nft list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep -q 'oifname "br-f1c".*jump DOCKER'; then
        print_info "  Adding DOCKER-BRIDGE jump for br-f1c..."
        sudo nft add rule ip filter DOCKER-BRIDGE oifname "br-f1c" counter jump DOCKER
    fi

    # -------------------------------------------------------
    # 3. CU-CP E1AP: 192.168.0.193:38462 → CU-CP on e1_net:38462
    #    CU-CP binds E1AP SCTP to e1_net IP (192.168.75.140) port 38462
    #    Docker's DNAT incorrectly points to core_net IP
    # -------------------------------------------------------
    print_info "Configuring CU-CP E1AP SCTP routing..."

    # Remove Docker's incorrect DNAT rule
    local WRONG_E1_RULE=$(sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep "sctp dport 38462.*dnat to ${CUCP_CORE_IP}:38462" | grep -oP 'handle \K\d+')
    if [ -n "$WRONG_E1_RULE" ]; then
        print_info "  Removing incorrect E1 DNAT rule (handle $WRONG_E1_RULE)..."
        sudo nft delete rule ip nat DOCKER handle $WRONG_E1_RULE
    fi

    # Add correct DNAT rule: external:38462 → e1_net_IP:38462
    print_info "  Adding correct E1 DNAT: ${MACHINE1_IP}:38462 → ${CUCP_E1_IP}:38462"
    sudo nft add rule ip nat DOCKER iifname != "br-e1" meta l4proto sctp ip daddr ${MACHINE1_IP} sctp dport 38462 counter dnat to ${CUCP_E1_IP}:38462

    # Remove Docker's incorrect FORWARD accept rule
    local WRONG_E1_FWD=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep "sctp.*daddr ${CUCP_CORE_IP}.*sctp dport 38462" | grep -oP 'handle \K\d+')
    if [ -n "$WRONG_E1_FWD" ]; then
        print_info "  Removing incorrect E1 FORWARD rule (handle $WRONG_E1_FWD)..."
        sudo nft delete rule ip filter DOCKER handle $WRONG_E1_FWD
    fi

    # Add correct FORWARD accept rule for e1_net
    print_info "  Adding E1 FORWARD accept rule for br-e1..."
    sudo nft add rule ip filter DOCKER iifname != "br-e1" oifname "br-e1" meta l4proto sctp ip daddr ${CUCP_E1_IP} sctp dport 38462 counter accept

    # Add DOCKER-BRIDGE jump for br-e1 (if not already present)
    if ! sudo nft list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep -q 'oifname "br-e1".*jump DOCKER'; then
        print_info "  Adding DOCKER-BRIDGE jump for br-e1..."
        sudo nft add rule ip filter DOCKER-BRIDGE oifname "br-e1" counter jump DOCKER
    fi

    # -------------------------------------------------------
    # 4. Handle raw table — Docker adds DROP rules in raw PREROUTING
    #    that block packets to container IPs from non-bridge interfaces.
    #    We need to add ACCEPT rules BEFORE the drops for DNAT'd SCTP.
    # -------------------------------------------------------
    print_info "Configuring raw table exceptions for SCTP DNAT..."

    # For F1-C: packets after DNAT will have dst=CUCP_F1C_IP
    # But raw runs BEFORE nat, so dst is still MACHINE1_IP at raw stage.
    # The raw rules match on container IPs, which only appear AFTER DNAT.
    # Since raw priority (-300) < nat priority (-100), raw sees the ORIGINAL
    # destination (192.168.0.193), NOT the DNAT'd destination.
    # Therefore, the raw DROP rules should NOT affect DNAT'd traffic.
    #
    # HOWEVER: For return traffic and conntrack, we should ensure
    # established/related SCTP flows are not dropped.
    
    # Verify raw rules don't match our external IP
    if sudo nft list chain ip raw PREROUTING 2>/dev/null | grep -q "ip daddr ${MACHINE1_IP}.*drop"; then
        print_warn "  WARNING: Raw table has DROP rule for ${MACHINE1_IP} — removing it"
        local RAW_HANDLE=$(sudo nft -a list chain ip raw PREROUTING 2>/dev/null | grep "ip daddr ${MACHINE1_IP}.*drop" | grep -oP 'handle \K\d+')
        if [ -n "$RAW_HANDLE" ]; then
            sudo nft delete rule ip raw PREROUTING handle $RAW_HANDLE
        fi
    else
        print_info "  ✓ Raw table does not block external IP — DNAT will work"
    fi

    # -------------------------------------------------------
    # 5. Ensure SCTP kernel module is loaded
    # -------------------------------------------------------
    if ! lsmod | grep -q "^sctp"; then
        print_info "Loading SCTP kernel module..."
        sudo modprobe sctp
    fi
    print_info "  ✓ SCTP kernel module is loaded"

    # -------------------------------------------------------
    # 6. Ensure conntrack handles SCTP properly
    # -------------------------------------------------------
    # Enable SCTP conntrack checksum verification bypass (some implementations
    # don't compute checksums correctly)
    if [ -f /proc/sys/net/netfilter/nf_conntrack_checksum ]; then
        sudo sysctl -w net.netfilter.nf_conntrack_checksum=0 > /dev/null 2>&1
        print_info "  ✓ Disabled conntrack checksum verification for SCTP compatibility"
    fi

    # -------------------------------------------------------
    # 7. Add MASQUERADE for return traffic from f1c_net and e1_net
    #    When external SCTP arrives, it gets DNAT'd to the container.
    #    The container responds to the source IP (Machine 2's IP).
    #    But the container's default gateway is the bridge gateway,
    #    which routes back through the host. We need SNAT so the
    #    return packet's source matches what the DNAT expects.
    # -------------------------------------------------------
    
    # Check if MASQUERADE already exists for these bridges
    if ! sudo nft list chain ip nat POSTROUTING 2>/dev/null | grep -q 'oifname "br-f1c".*masquerade'; then
        # Actually, Docker already adds masquerade for outbound traffic.
        # For inbound DNAT'd traffic, the return path uses conntrack
        # to reverse the DNAT, so no additional SNAT is needed.
        print_info "  ✓ Return path uses conntrack (no additional SNAT needed)"
    fi

    print_info ""
    print_info "SCTP routing setup complete!"
    print_info ""
    print_info "SCTP port mapping summary:"
    print_info "  AMF  NGAP:  ${MACHINE1_IP}:38412/sctp → ${AMF_CORE_IP}:38412 (core_net)"
    print_info "  CU-CP F1-C: ${MACHINE1_IP}:38472/sctp → ${CUCP_F1C_IP}:501 (f1c_net)"
    print_info "  CU-CP E1:   ${MACHINE1_IP}:38462/sctp → ${CUCP_E1_IP}:38462 (e1_net)"
}

verify_sctp_routing() {
    print_stage "Verifying SCTP routing rules..."
    
    echo ""
    print_info "NAT DNAT rules for SCTP:"
    sudo nft list chain ip nat DOCKER 2>/dev/null | grep sctp || print_warn "  No SCTP DNAT rules found"
    
    echo ""
    print_info "Filter FORWARD rules for SCTP:"
    sudo nft list chain ip filter DOCKER 2>/dev/null | grep sctp || print_warn "  No SCTP FORWARD rules found"
    
    echo ""
    print_info "Checking CU-CP SCTP sockets inside container..."
    docker exec cucp ss -Slnp 2>/dev/null | head -20 || print_warn "  Could not check CU-CP sockets"
    
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

# Check for running containers
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

# Check current IP
if [ "$CURRENT_IP" != "$MACHINE1_IP" ]; then
    print_warn "Current IP is $CURRENT_IP, expected $MACHINE1_IP"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check docker-compose file exists
if [ ! -f "docker-compose-centraloffice.yml" ]; then
    print_error "docker-compose-centraloffice.yml not found"
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

# Check network connectivity to Machine 2
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

# Create networks and prepare containers
print_stage "Creating Docker networks..."
docker compose -f docker-compose-centraloffice.yml up --no-start
echo ""

# Stage 1: MySQL
print_stage "Stage 1/6: Starting MySQL database..."
docker compose -f docker-compose-centraloffice.yml up -d mysql
wait_for_healthy "mysql" 60
echo ""

# Stage 2: Core Network Functions
print_stage "Stage 2/6: Starting 5G Core Network Functions..."
docker compose -f docker-compose-centraloffice.yml up -d nrf smf pcf nssf amf udm udr ausf

# Wait for critical services
wait_for_service "nrf" 30
wait_for_service "amf" 30
wait_for_service "smf" 30

print_info "Waiting for services to initialize..."
sleep 5
echo ""

# Stage 3: User Plane Functions
print_stage "Stage 3/6: Starting Primary UPF and External DN..."
docker compose -f docker-compose-centraloffice.yml up -d upf ext_dn

wait_for_service "upf" 30
wait_for_service "ext_dn" 30

print_info "Waiting for UPF initialization..."
sleep 5
echo ""

# Stage 4: CU-CP
print_stage "Stage 4/6: Starting CU-CP (Central Unit Control Plane)..."
docker compose -f docker-compose-centraloffice.yml up -d cucp
wait_for_service "cucp" 30
sleep 10
echo ""

# Stage 5: CU-UP
print_stage "Stage 5/6: Starting CU-UP (Central Unit User Plane)..."
docker compose -f docker-compose-centraloffice.yml up -d cuup
wait_for_service "cuup" 30
sleep 5
echo ""

# ==========================================
# Stage 6: SCTP Routing Fix (THE KEY FIX)
# ==========================================
print_stage "Stage 6/6: Configuring SCTP routing for cross-machine access..."
setup_sctp_routing
echo ""

# Verify
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

# Check critical ports
print_info "Checking critical services..."

# Check NRF HTTP port
if timeout 3 bash -c "echo > /dev/tcp/${MACHINE1_IP}/9090" 2>/dev/null; then
    print_info "✓ NRF is reachable on ${MACHINE1_IP}:9090"
else
    print_warn "✗ NRF is NOT reachable on ${MACHINE1_IP}:9090"
fi

# Check CU-CP SCTP sockets
print_info "CU-CP SCTP listening sockets:"
docker exec cucp ss -Slnp 2>/dev/null | grep -E "501|38462" || print_warn "  CU-CP SCTP sockets not found"

# Check AMF SCTP socket
print_info "AMF SCTP listening sockets:"
docker exec amf ss -Slnp 2>/dev/null | grep "38412" || print_warn "  AMF SCTP socket not found"

echo ""
print_info "Next Steps:"
echo "  1. From Machine 2, test SCTP connectivity:"
echo "     ncat --sctp ${MACHINE1_IP} 38472    # F1-C to CU-CP"
echo "     ncat --sctp ${MACHINE1_IP} 38462    # E1 to CU-CP"
echo
