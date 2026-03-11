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

check_ue_connections() {
    local total_ues=10
    local connected_ues=0
    local ues_with_ip=0
    
    # Use global arrays so they're accessible outside function
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

    # Export for use outside function
    export CONNECTED_UES=$connected_ues
    export UES_WITH_IP=$ues_with_ip
    
    # Return 0 if all 10 connected, 1 otherwise
    if [ $connected_ues -eq 10 ]; then
        return 0
    else
        return 1
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
wait_for_service "cucp" 10


print_info "Starting CU-UP..."
docker-compose up -d cuup
wait_for_service "cuup" 10
sleep 2

print_info "Starting DU..."
docker-compose up -d du_1
wait_for_service "du_1" 10
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

# Wait for UE connections with initial delay
print_info "Waiting 30 seconds for UEs to connect and register..."
sleep 30
echo ""

# Check UE connections - function returns 0 if all 10 connected, 1 otherwise
if check_ue_connections; then
    # All 10 UEs connected - auto-proceed
    print_info "✓ All 10 UEs successfully connected!"
    echo ""
else
    # Fewer than 10 UEs connected - ask user what to do
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
                
                # Check again
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
                echo "  docker logs amf | grep -i 'registration'"
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

# Final connectivity test
echo ""
print_info "================================================"
print_info "Final Status"
print_info "================================================"

if [ $UES_WITH_IP -gt 0 ]; then
    print_info "✓ $UES_WITH_IP UE(s) with IP addresses are ready for testing"
    echo ""
    print_info "Test connectivity with:"
    echo "  docker exec -it ue_1 ping -I oaitun_ue1 -c 3 192.168.72.135"
    
    if [ $CONNECTED_UES -gt 1 ]; then
        echo "  docker exec -it ue_1 ping -I oaitun_ue2 -c 3 192.168.72.135"
        echo "  # ... and so on for other interfaces"
    fi
    
    # Automatic connectivity test for first UE
    echo ""
    print_info "Running automatic connectivity test..."
    if docker exec ue_1 ping -I oaitun_ue1 -c 3 -W 2 192.168.72.135 &>/dev/null; then
        print_info "✓ Connectivity test PASSED for oaitun_ue1"
    else
        print_warn "✗ Connectivity test FAILED for oaitun_ue1"
        echo "  Check UPF routing and External DN configuration"
    fi
else
    print_warn "No UEs have obtained IP addresses yet."
    echo ""
    print_info "Troubleshooting steps:"
    echo "  1. Check UE attachment: docker logs ue_1 | grep -i 'attach\|pdu'"
    echo "  2. Check AMF registration: docker logs amf | grep -i 'registration'"
    echo "  3. Check SMF session: docker logs smf | grep -i 'session'"
    echo "  4. Verify IMSI/keys in database match UE config"
fi

echo ""
print_info "Setup complete! Monitor logs to verify all components are working correctly."