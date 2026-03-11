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

# Pre-deployment checks
print_stage "Running pre-flight checks..."

# Check Docker is running
if ! docker ps &> /dev/null; then
    print_error "Docker is not running"
    exit 1
fi

if docker-compose ps -q 2>/dev/null | grep -q .; then
    print_warn "Some containers are already running"
    read -p "Do you want to stop them and restart? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Stopping existing containers..."
        docker-compose -f docker-compose-centraloffice.yml down
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

# Check network connectivity to Machine 2
if ping -c 1 -W 2 $MACHINE2_IP &> /dev/null; then
    print_info "✓ Can reach Machine 2 ($MACHINE2_IP)"
else
    print_warn "✗ Cannot reach Machine 2 ($MACHINE2_IP)"
    print_warn "Machine 2 components will not be able to connect"
fi

print_info "Pre-flight checks passed!"
echo ""

# Start network creation
print_stage "Creating Docker networks..."
docker-compose -f docker-compose-centraloffice.yml up --no-start
echo ""

# Stage 1: MySQL
print_stage "Stage 1/5: Starting MySQL database..."
docker-compose -f docker-compose-centraloffice.yml up -d mysql
wait_for_service "mysql" 30
echo ""

# Stage 2: Core Network Functions
print_stage "Stage 2/5: Starting 5G Core Network Functions..."
docker-compose -f docker-compose-centraloffice.yml up -d nrf smf pcf nssf amf udm udr ausf

# Wait for critical services
wait_for_service "nrf" 30
wait_for_service "amf" 30
wait_for_service "smf" 30

print_info "Waiting for services to initialize..."
sleep 5
echo ""

# Stage 3: User Plane Functions
print_stage "Stage 3/5: Starting Primary UPF and External DN..."
docker-compose -f docker-compose-centraloffice.yml up -d upf ext_dn 

wait_for_service "upf" 30
wait_for_service "ext_dn" 30

print_info "Waiting for UPF initialization..."
sleep 5
echo ""

# Stage 4: CU-CP
print_stage "Stage 4/5: Starting CU-CP (Central Unit Control Plane)..."
docker-compose -f docker-compose-centraloffice.yml up -d cucp
wait_for_service "cucp" 30
sleep 10
echo ""

# Stage 5: CU-UP
print_stage "Stage 5/5: Starting CU-UP (Central Unit User Plane)..."
docker-compose -f docker-compose-centraloffice.yml up -d cuup
wait_for_service "cuup" 30
sleep 5
echo ""

# Final status check
print_stage "Checking final status..."
echo ""
docker-compose -f docker-compose-centraloffice.yml ps
echo ""

print_info "================================================"
print_info "Machine 1 Deployment Complete!"
print_info "================================================"
echo ""

# Check critical ports
print_info "Checking critical services..."

# Check AMF NGAP port
if sudo netstat -tulpn 2>/dev/null | grep -q ":38412"; then
    print_info "✓ AMF NGAP port 38412 is listening (for Machine 2 CU-CP)"
else
    print_warn "✗ AMF NGAP port 38412 is NOT listening"
fi

# Check NRF HTTP port
if docker exec nrf wget -q -O- http://localhost/nnrf-nfm/v1/nf-instances &>/dev/null; then
    print_info "✓ NRF is responding on HTTP"
else
    print_warn "✗ NRF is NOT responding"
fi

# Check CU-CP connection to AMF
if docker logs cucp 2>&1 | grep -qi "amf\|ng setup"; then
    print_info "✓ CU-CP is attempting AMF connection"
else
    print_warn "⚠ CU-CP AMF connection unclear"
fi

echo ""
print_info "Next Steps:"
echo "  1. Verify all services are healthy:"
echo "     docker-compose -f docker-compose-machine1.yml logs -f"
echo ""
echo "  2. Check specific service logs:"
echo "     docker logs -f amf"
echo "     docker logs -f cucp"
echo ""
echo "  3. Deploy Machine 2 (Edge RAN) on $MACHINE2_IP:"
echo "     ./deploy-machine2.sh"
echo ""

print_info "To stop: docker-compose -f docker-compose-centraloffice.yml down"
echo ""

# Offer to show logs
read -p "Show live logs? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker-compose -f docker-compose-centraloffice.yml logs -f
fi
