#!/bin/bash

# deploy-ran.sh - Deploy RAN Components on PC 192.168.0.243

set -e

CORE_IP="192.168.0.193"
RAN_IP="192.168.0.243"

echo "================================================"
echo "5G RAN Components Deployment"
echo "================================================"
echo "Core PC: $CORE_IP"
echo "RAN PC: $RAN_IP"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running on correct PC
CURRENT_IP=$(hostname -I | awk '{print $1}')
if [ "$CURRENT_IP" != "$RAN_IP" ]; then
    print_warn "Current IP is $CURRENT_IP, expected $RAN_IP"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check docker-compose file exists
if [ ! -f "docker-compose-ran.yml" ]; then
    print_error "docker-compose-ran.yml not found"
    exit 1
fi

# Check if configs exist
if [ ! -d "configs" ]; then
    print_error "configs directory not found"
    print_info "Run ./generate-configs.sh first"
    exit 1
fi

print_info "Pre-deployment checks..."

# Check Docker is running
if ! docker ps &> /dev/null; then
    print_error "Docker is not running"
    exit 1
fi

# Check network connectivity to Core PC
if ! ping -c 3 -W 2 $CORE_IP &> /dev/null; then
    print_error "Cannot reach Core PC ($CORE_IP)"
    print_error "RAN components require connectivity to Core"
    exit 1
fi

# Test AMF connectivity
print_info "Testing AMF connectivity on Core PC..."
if timeout 2 bash -c "echo > /dev/tcp/$CORE_IP/38412" 2>/dev/null; then
    print_info "✓ Can reach AMF on $CORE_IP:38412"
else
    print_warn "✗ Cannot reach AMF on $CORE_IP:38412"
    print_warn "Check if Core PC is running and firewall is configured"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

print_info "Starting deployment..."
echo ""

# Stage 1: CU-CP
print_info "Stage 1/6: Starting CU-CP..."
docker-compose -f docker-compose-ran.yml up -d cucp
print_info "Waiting for CU-CP to initialize..."
sleep 15

# Check CU-CP logs
print_info "Checking CU-CP connection to AMF..."
if docker logs cucp 2>&1 | grep -qi "amf"; then
    print_info "CU-CP attempting AMF connection"
else
    print_warn "No AMF connection attempts seen yet"
fi

# Stage 2: CU-UP
print_info "Stage 2/6: Starting CU-UP..."
docker-compose -f docker-compose-ran.yml up -d cuup
print_info "Waiting for CU-UP to initialize..."
sleep 15

# Stage 3: DU
print_info "Stage 3/6: Starting DU..."
docker-compose -f docker-compose-ran.yml up -d du_1
print_info "Waiting for DU to initialize..."
sleep 15

# Stage 4: FlexRIC
print_info "Stage 4/6: Starting FlexRIC..."
docker-compose -f docker-compose-ran.yml up -d flexric
print_info "Waiting for FlexRIC to initialize..."
sleep 10

# Stage 5: L2 Proxy
print_info "Stage 5/6: Starting L2 Proxy..."
docker-compose -f docker-compose-ran.yml up -d l2_proxy
print_info "Waiting for L2 Proxy to initialize..."
sleep 10

# Stage 6: UE
print_info "Stage 6/6: Starting UE..."
docker-compose -f docker-compose-ran.yml up -d ue_1
print_info "Waiting for UE to attach..."
sleep 15

echo ""
print_info "================================================"
print_info "RAN Deployment Complete!"
print_info "================================================"
echo ""

# Status check
print_info "Service Status:"
docker-compose -f docker-compose-ran.yml ps

echo ""
print_info "Checking RAN connectivity..."

# Check CU-CP to AMF
print_info "CU-CP to AMF connection:"
if docker logs cucp 2>&1 | grep -qi "connected\|established\|registered"; then
    print_info "✓ CU-CP appears connected"
else
    print_warn "✗ CU-CP connection unclear - check logs"
fi

# Check UE attachment
print_info "UE attachment status:"
if docker logs ue_1 2>&1 | grep -qi "attach\|connected\|registered"; then
    print_info "✓ UE appears to be attaching"
    
    # Check if UE has IP
    sleep 5
    if docker exec ue_1 ip addr show 2>/dev/null | grep -q "oaitun_ue1"; then
        UE_IP=$(docker exec ue_1 ip addr show oaitun_ue1 2>/dev/null | grep "inet " | awk '{print $2}')
        print_info "✓ UE interface created: $UE_IP"
    else
        print_warn "✗ UE interface not yet created"
    fi
else
    print_warn "✗ UE attachment unclear - check logs"
fi

echo ""
print_info "Useful Commands:"
echo "  Check all logs:   docker-compose -f docker-compose-ran.yml logs -f"
echo "  Check CU-CP:      docker logs -f cucp"
echo "  Check UE:         docker logs -f ue_1"
echo "  Test UE ping:     docker exec ue_1 ping -I oaitun_ue1 8.8.8.8"
echo ""

print_info "To stop: docker-compose -f docker-compose-ran.yml down"

# Offer to show logs
echo ""
read -p "Show live logs? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker-compose -f docker-compose-ran.yml logs -f
fi
