#!/bin/bash

# start.sh - Script to start the 5G network with proper sequencing

set -e

echo "================================================"
echo "5G Network Emulation - Startup Script"
echo "================================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
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

# Function to wait for service to be healthy
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

# Function to check if containers are running
check_running() {
    local containers=("$@")
    for container in "${containers[@]}"; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            return 1
        fi
    done
    return 0
}

wait_for_radio(){

if docker logs du_1 2>&1 | grep -q "Command line parameters for OAI UE"; then
    print_info "DU is configured for OAI UE!"
else
    print_info "Radio rfsim not yet up"
    sleep 10
    wait_for_radio
fi
}

# Parse command line arguments
SKIP_CHECKS=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-checks)
            SKIP_CHECKS=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-checks    Skip pre-flight checks"
            echo "  --verbose, -v    Show detailed output"
            echo "  --help, -h       Show this help message"
            echo ""
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Pre-flight checks
if [ "$SKIP_CHECKS" = false ]; then
    print_stage "Running pre-flight checks..."
    
    # Check if docker-compose.yml exists
    if [ ! -f "docker-compose.yml" ]; then
        print_error "docker-compose.yml not found in current directory"
        exit 1
    fi
    
    # Check if config directories exist
    if [ ! -d "configs" ]; then
        print_error "configs directory not found. Run ./setup.sh first"
        exit 1
    fi
    
    # Check if any containers are already running
    if docker-compose ps -q 2>/dev/null | grep -q .; then
        print_warn "Some containers are already running"
        read -p "Do you want to stop them and restart? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Stopping existing containers..."
            docker-compose down
        else
            print_info "Continuing with existing containers..."
        fi
    fi
    
    print_info "Pre-flight checks passed!"
    echo ""
fi

# Start network creation
print_stage "Creating Docker networks..."
docker-compose up --no-start
echo ""

# Stage 1: MySQL
print_stage "Stage 1/5: Starting MySQL database..."
docker-compose up -d mysql
wait_for_service "mysql" 30
echo ""

# Stage 2: Core Network Functions
print_stage "Stage 2/5: Starting 5G Core Network Functions..."
docker-compose up -d nrf smf pcf nssf amf udm udr ausf

# Wait for critical services
wait_for_service "nrf" 30
wait_for_service "amf" 30
wait_for_service "smf" 30

print_info "Waiting for services to initialize..."
echo ""

# Stage 3: User Plane Functions
print_stage "Stage 3/5: Starting UPF and External DN..."
docker-compose up -d upf ext_dn 

wait_for_service "upf" 30
wait_for_service "ext_dn" 30

print_info "Waiting for UPF initialization..."
echo ""

# Stage 4: Central RAN Components
print_stage "Stage 4/5: Starting RAN Components..."

print_info "Starting FlexRIC..."
docker-compose up -d flexric
wait_for_service "flexric" 30
sleep 10

print_info "Starting CU-CP..."
docker-compose up -d cucp
wait_for_service "cucp" 30


print_info "Starting CU-UP..."
docker-compose up -d cuup
wait_for_service "cuup" 30
sleep 2

print_info "Starting DU..."
docker-compose up -d du_1
wait_for_service "du_1" 30
sleep 10
echo ""

wait_for_radio 

# Stage 5: User Equipment and DU
print_stage "Stage 5/5: Starting User Equipment..."
docker-compose up -d ue_1
wait_for_service "ue_1" 30
echo ""

# Final status check
print_stage "Checking final status..."
echo ""

if [ "$VERBOSE" = true ]; then
    docker-compose ps
else
    docker-compose ps --format table
fi

echo ""
print_info "================================================"
print_info "5G Network startup complete!"
print_info "================================================"
echo ""

# Show some useful commands
echo "Useful commands:"
echo "  View all logs:          docker-compose logs -f"
echo "  View specific service:  docker logs -f <service-name>"
echo "  Check status:           docker-compose ps"
echo "  Access container:       docker exec -it <container-name> bash"
echo "  Stop network:           docker-compose down"
echo ""

# Check if UE is connected
print_info "Checking UE connectivity..."
sleep 30

ue_count=0
ue_with_ip=0

echo ""
for i in {1..10}; do
    interface="oaitun_ue$i"
    if docker exec ue_1 ip addr show 2>/dev/null | grep -q "$interface"; then
        ip_addr=$(docker exec ue_1 ip addr show "$interface" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "no IP")
        if [ "$ip_addr" != "no IP" ] && [ -n "$ip_addr" ]; then
            print_info "✓ $interface detected - IP: $ip_addr"
            ((ue_with_ip++))
        else
            print_warn "✓ $interface detected but no IP assigned"
        fi
        ((ue_count++))
    fi
done


if docker exec ue_1 ip addr show 2>/dev/null | grep -q "oaitun_ue1"; then
    print_info "UE interface (oaitun_ue1) detected!"
    print_info "You can test connectivity with:"
    echo "  docker exec -it ue_1 ping -I oaitun_ue1 192.168.72.135"
else
    print_warn "UE interface not yet available. Check logs for more details:"
    echo "  docker logs ue_1"
fi

echo ""
print_info "Setup complete! Monitor logs to verify all components are working correctly."
