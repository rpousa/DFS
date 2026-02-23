#!/bin/bash

# deploy-core.sh - Deploy Core Network on PC 192.168.0.193

set -e

CORE_IP="192.168.0.193"
RAN_IP="192.168.0.243"

echo "================================================"
echo "5G Core Network Deployment"
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
if [ "$CURRENT_IP" != "$CORE_IP" ]; then
    print_warn "Current IP is $CURRENT_IP, expected $CORE_IP"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Check docker-compose file exists
if [ ! -f "docker-compose-core.yml" ]; then
    print_error "docker-compose-core.yml not found"
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

# Check network connectivity to RAN PC
if ! ping -c 1 -W 2 $RAN_IP &> /dev/null; then
    print_warn "Cannot reach RAN PC ($RAN_IP)"
    print_warn "RAN components will not be able to connect"
fi

# Check if firewall might block
if command -v ufw &> /dev/null; then
    if sudo ufw status | grep -q "Status: active"; then
        print_warn "Firewall is active - may need to allow ports:"
        print_warn "  sudo ufw allow from $RAN_IP"
    fi
fi

print_info "Starting deployment..."
echo ""

# Stage 1: MySQL
print_info "Stage 1/3: Starting MySQL..."
docker-compose -f docker-compose-core.yml up -d mysql
sleep 10

# Wait for MySQL
print_info "Waiting for MySQL to be ready..."
for i in {1..30}; do
    if docker exec mysql mysqladmin ping -h localhost &> /dev/null; then
        print_info "MySQL is ready"
        break
    fi
    sleep 1
done

# Stage 2: Core Network Functions
print_info "Stage 2/3: Starting Core Network Functions..."
docker-compose -f docker-compose-core.yml up -d nrf smf pcf nssf amf udm udr ausf

print_info "Waiting for services to initialize..."
sleep 15

# Stage 3: UPF and External DN
print_info "Stage 3/3: Starting UPF and External DN..."
docker-compose -f docker-compose-core.yml up -d upf ext_dn upf_1 ext_dn_1

print_info "Waiting for UPF initialization..."
sleep 10

echo ""
print_info "================================================"
print_info "Core Network Deployment Complete!"
print_info "================================================"
echo ""

# Status check
print_info "Service Status:"
docker-compose -f docker-compose-core.yml ps

echo ""
print_info "Checking critical ports..."

# Check AMF port
if sudo netstat -tulpn 2>/dev/null | grep -q ":38412"; then
    print_info "✓ AMF NGAP port 38412 is listening"
else
    print_warn "✗ AMF NGAP port 38412 is NOT listening"
fi

# Check NRF port
if sudo netstat -tulpn 2>/dev/null | grep -q ":8080"; then
    print_info "✓ NRF HTTP port 8080 is listening"
else
    print_warn "✗ NRF HTTP port 8080 is NOT listening"
fi

echo ""
print_info "Next Steps:"
echo "  1. Check logs: docker-compose -f docker-compose-core.yml logs -f"
echo "  2. Verify NRF: curl http://localhost:8080/nnrf-nfm/v1/nf-instances"
echo "  3. Deploy RAN on $RAN_IP"
echo ""
print_info "To stop: docker-compose -f docker-compose-core.yml down"
