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

# Pre-deployment checks
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

# CRITICAL: Check network connectivity to Machine 1
if ! ping -c 3 -W 2 $MACHINE1_IP &> /dev/null; then
    print_error "✗ Cannot reach Machine 1 ($MACHINE1_IP)"
    print_error "Machine 2 requires connectivity to Machine 1 Core Network"
    exit 1
fi
print_info "✓ Can reach Machine 1 ($MACHINE1_IP)"

# Test core network reachability (NRF on TCP as proxy for AMF health)
print_info "Testing core network reachability on Machine 1..."
if timeout 2 bash -c "echo > /dev/tcp/$MACHINE1_IP/9090" 2>/dev/null; then
    print_info "✓ Can reach NRF on $MACHINE1_IP:9090 — Core network is up"
    print_info "  AMF connectivity will be verified when CU-CP establishes NGAP association"
else
    print_error "✗ Cannot reach NRF on $MACHINE1_IP:9090"
    print_error "Make sure Machine 1 is deployed and firewall allows connections"
    exit 1
fi

print_info "Pre-flight checks passed!"
echo ""

# Start network creation
print_stage "Creating Docker networks..."
docker compose -f docker-compose-edge.yml up --no-start
echo ""

# Stage 1: Edge UPF
print_stage "Stage 1/6: Starting Edge UPF and External DN..."
docker compose -f docker-compose-edge.yml up -d upf_1 ext_dn_1
wait_for_service "upf_1" 30
wait_for_service "ext_dn_1" 30
sleep 10
echo ""

# Stage 2: Edge CU-UP
print_stage "Stage 2/6: Starting Edge CU-UP..."
docker compose -f docker-compose-edge.yml up -d cuup_1
wait_for_service "cuup_1" 30
sleep 10
echo ""

# Stage 3: DU with RFSimulator
print_stage "Stage 3/6: Starting DU with RFSimulator..."
docker compose -f docker-compose-edge.yml up -d du_1
wait_for_service "du_1" 30
sleep 10

# Check DU RFSimulator status
if docker logs du_1 2>&1 | grep -q "Running as server"; then
    print_info "✓ DU RFSimulator server is listening"
else
    print_warn "⚠ DU RFSimulator status unclear"
fi
echo ""

# Stage 4: FlexRIC
print_stage "Stage 4/6: Starting FlexRIC (Near-RT RIC)..."
docker compose -f docker-compose-edge.yml up -d flexric
wait_for_service "flexric" 30
sleep 10
echo ""

# Stage 5: User Equipment (10 UEs)
print_stage "Stage 5/6: Starting 10 User Equipment instances..."
docker compose -f docker-compose-edge.yml up -d ue_1
wait_for_service "ue_1" 30
echo ""

# Stage 6: Wait for UE connections
print_stage "Stage 6/6: Waiting for UE connections..."
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
                echo "  docker logs du_1 | grep -i 'ue\|rfsim'"
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

# Final connectivity test
if [ $UES_WITH_IP -gt 0 ]; then
    print_info "✓ $UES_WITH_IP UE(s) with IP addresses are ready for testing"
    echo ""
    print_info "Test connectivity with:"
    echo "  docker exec -it ue_1 ping -I oaitun_ue1 -c 3 192.168.72.161"
    
    if [ $CONNECTED_UES -gt 1 ]; then
        echo "  docker exec -it ue_1 ping -I oaitun_ue2 -c 3 192.168.72.161"
        echo "  # ... and so on for other interfaces"
    fi
    
    # Automatic connectivity test
    echo ""
    print_info "Running automatic connectivity test..."
    if docker exec ue_1 ping -I oaitun_ue1 -c 3 -W 2 192.168.72.161 &>/dev/null; then
        print_info "✓ Connectivity test PASSED for oaitun_ue1"
    else
        print_warn "✗ Connectivity test FAILED for oaitun_ue1"
        echo "  Check Edge UPF routing and External DN configuration"
    fi
else
    print_warn "No UEs have obtained IP addresses yet."
    echo ""
    print_info "Troubleshooting steps:"
    echo "  1. Check UE attachment: docker logs ue_1 | grep -i 'attach\|pdu'"
    echo "  2. Check DU logs: docker logs du_1 | grep -i 'ue\|rfsim'"
    echo "  3. Check CU-CP on Machine 1: ssh $MACHINE1_IP 'docker logs cucp'"
    echo "  4. Verify IMSI/keys in database match UE config"
fi

echo ""
print_info "Useful Commands:"
echo "  View all logs:        docker compose -f docker-compose-edge.yml logs -f"
echo "  View DU logs:         docker logs -f du_1"
echo "  View UE logs:         docker logs -f ue_1"
echo "  Check UE interfaces:  docker exec ue_1 ip addr show | grep oaitun"
echo "  Stop deployment:      docker compose -f docker-compose-edge.yml down"
echo ""

print_info "Setup complete! Monitor logs to verify all components are working correctly."
echo ""

# Offer to show logs
read -p "Show live logs? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker compose -f docker-compose-edge.yml logs -f
fi
