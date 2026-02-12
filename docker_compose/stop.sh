#!/bin/bash

# stop.sh - Script to stop the 5G network gracefully

set -e

echo "================================================"
echo "5G Network Emulation - Shutdown Script"
echo "================================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse command line arguments
REMOVE_VOLUMES=false
REMOVE_NETWORKS=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --volumes|-v)
            REMOVE_VOLUMES=true
            shift
            ;;
        --networks|-n)
            REMOVE_NETWORKS=true
            shift
            ;;
        --force|-f)
            FORCE=true
            shift
            ;;
        --all|-a)
            REMOVE_VOLUMES=true
            REMOVE_NETWORKS=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --volumes, -v     Remove volumes (database data will be lost)"
            echo "  --networks, -n    Remove networks"
            echo "  --all, -a         Remove everything (volumes and networks)"
            echo "  --force, -f       Force stop without confirmation"
            echo "  --help, -h        Show this help message"
            echo ""
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml not found in current directory"
    exit 1
fi

# Confirmation prompt if not forced
if [ "$FORCE" = false ]; then
    read -p "Are you sure you want to stop the 5G network? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Shutdown cancelled"
        exit 0
    fi
fi

# Additional warning for volume removal
if [ "$REMOVE_VOLUMES" = true ] && [ "$FORCE" = false ]; then
    print_warn "This will remove volumes and DELETE all database data!"
    read -p "Are you absolutely sure? (yes/N): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_info "Volume removal cancelled. Stopping containers only..."
        REMOVE_VOLUMES=false
    fi
fi

print_info "Stopping 5G network components..."
echo ""

# Graceful shutdown in reverse order
print_info "Stopping User Equipment..."
docker-compose stop ue_1 2>/dev/null || true

print_info "Stopping L2 Proxy..."
docker-compose stop l2_proxy 2>/dev/null || true

print_info "Stopping FlexRIC..."
docker-compose stop flexric 2>/dev/null || true

print_info "Stopping RAN components..."
docker-compose stop du_1 cuup cucp 2>/dev/null || true

print_info "Stopping UPF and External DN..."
docker-compose stop upf ext_dn upf_1 ext_dn_1 2>/dev/null || true

print_info "Stopping Core Network Functions..."
docker-compose stop amf smf pcf nssf udm udr ausf nrf 2>/dev/null || true

print_info "Stopping MySQL..."
docker-compose stop mysql 2>/dev/null || true

echo ""
print_info "All services stopped"

# Remove containers
print_info "Removing containers..."
docker-compose rm -f

# Build the down command
DOWN_CMD="docker-compose down"

if [ "$REMOVE_VOLUMES" = true ]; then
    DOWN_CMD="$DOWN_CMD -v"
    print_warn "Removing volumes (database data will be lost)..."
fi

if [ "$REMOVE_NETWORKS" = true ]; then
    print_info "Networks will be removed..."
fi

# Execute down command
eval $DOWN_CMD

# Cleanup orphaned containers
print_info "Cleaning up orphaned containers..."
docker-compose down --remove-orphans 2>/dev/null || true

# Additional cleanup if needed
if [ "$REMOVE_VOLUMES" = true ]; then
    print_info "Pruning unused volumes..."
    docker volume prune -f 2>/dev/null || true
fi

echo ""
print_info "================================================"
print_info "5G Network shutdown complete!"
print_info "================================================"
echo ""

# Show remaining Docker resources
REMAINING_CONTAINERS=$(docker ps -a --filter "name=5g" --format "{{.Names}}" 2>/dev/null | wc -l)
REMAINING_NETWORKS=$(docker network ls --filter "name=5g" --format "{{.Name}}" 2>/dev/null | wc -l)
REMAINING_VOLUMES=$(docker volume ls --filter "name=5g" --format "{{.Name}}" 2>/dev/null | wc -l)

if [ $REMAINING_CONTAINERS -gt 0 ] || [ $REMAINING_NETWORKS -gt 0 ] || [ $REMAINING_VOLUMES -gt 0 ]; then
    print_warn "Some resources may still exist:"
    [ $REMAINING_CONTAINERS -gt 0 ] && echo "  Containers: $REMAINING_CONTAINERS"
    [ $REMAINING_NETWORKS -gt 0 ] && echo "  Networks: $REMAINING_NETWORKS"
    [ $REMAINING_VOLUMES -gt 0 ] && echo "  Volumes: $REMAINING_VOLUMES"
    echo ""
    echo "To forcefully clean up all Docker resources:"
    echo "  docker system prune -a --volumes"
else
    print_info "All 5G network resources have been removed"
fi

echo ""
print_info "To restart the network, run: ./start.sh"
