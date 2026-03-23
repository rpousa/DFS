#!/bin/bash

# stop.sh - Script to stop the 5G network gracefully
# Cleans up Docker containers AND custom nftables SCTP routing rules

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

# ==========================================
# Clean up custom nftables SCTP routing rules
# ==========================================
cleanup_sctp_rules() {
    print_stage "Cleaning up custom SCTP nftables rules..."

    # -------------------------------------------------------
    # Clean NAT DOCKER chain — remove all SCTP DNAT rules
    # These are the custom rules added by deploy scripts for
    # F1-C (port 38472), E1 (port 38462), and NGAP (port 38412)
    # Docker's own rules will be removed when containers go down
    # -------------------------------------------------------
    local sctp_ports=("38472" "38462" "38412" "500")

    for port in "${sctp_ports[@]}"; do
        while true; do
            local HANDLE=$(sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep "sctp dport ${port}" | head -1 | grep -oP 'handle \K\d+' || echo "")
            if [ -z "$HANDLE" ]; then
                break
            fi
            print_info "  Removing SCTP DNAT rule for port $port (handle $HANDLE)..."
            sudo nft delete rule ip nat DOCKER handle $HANDLE 2>/dev/null || true
        done
    done

    # -------------------------------------------------------
    # Clean filter DOCKER chain — remove all SCTP FORWARD rules
    # Match on "sctp" keyword to catch all custom SCTP accept rules
    # -------------------------------------------------------
    while true; do
        local HANDLE=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep "sctp" | head -1 | grep -oP 'handle \K\d+' || echo "")
        if [ -z "$HANDLE" ]; then
            break
        fi
        print_info "  Removing SCTP FORWARD rule (handle $HANDLE)..."
        sudo nft delete rule ip filter DOCKER handle $HANDLE 2>/dev/null || true
    done

    # -------------------------------------------------------
    # Clean DOCKER-BRIDGE chain — remove custom bridge jumps
    # Only remove jumps for br-f1c and br-e1 that we added
    # (Docker adds its own for br-core, etc.)
    # -------------------------------------------------------
    for bridge in "br-f1c" "br-e1"; do
        # Count how many jump rules exist for this bridge
        local COUNT=$(sudo nft -a list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep "oifname \"${bridge}\".*jump DOCKER" | wc -l || echo "0")
        if [ "$COUNT" -gt 1 ]; then
            # Docker creates one, we may have added extras — remove all extras
            local EXTRA=$((COUNT - 1))
            print_info "  Removing $EXTRA extra DOCKER-BRIDGE jump(s) for $bridge..."
            for i in $(seq 1 $EXTRA); do
                local HANDLE=$(sudo nft -a list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep "oifname \"${bridge}\".*jump DOCKER" | tail -1 | grep -oP 'handle \K\d+' || echo "")
                if [ -n "$HANDLE" ]; then
                    sudo nft delete rule ip filter DOCKER-BRIDGE handle $HANDLE 2>/dev/null || true
                fi
            done
        fi
    done

    # -------------------------------------------------------
    # Clean DOCKER-ISOLATION-STAGE-1 — remove SCTP bypass rules
    # (Only present on Machine 2 if isolation chains exist)
    # -------------------------------------------------------
    if sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null | grep -q "sctp"; then
        while true; do
            local HANDLE=$(sudo nft -a list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null | grep "sctp" | head -1 | grep -oP 'handle \K\d+' || echo "")
            if [ -z "$HANDLE" ]; then
                break
            fi
            print_info "  Removing SCTP isolation bypass rule (handle $HANDLE)..."
            sudo nft delete rule ip filter DOCKER-ISOLATION-STAGE-1 handle $HANDLE 2>/dev/null || true
        done
    fi

    # -------------------------------------------------------
    # Re-enable conntrack checksum (restore default)
    # -------------------------------------------------------
    if [ -f /proc/sys/net/netfilter/nf_conntrack_checksum ]; then
        sudo sysctl -w net.netfilter.nf_conntrack_checksum=1 > /dev/null 2>&1 || true
        print_info "  ✓ Restored conntrack checksum verification"
    fi

    print_info "✓ SCTP nftables rules cleaned up"
}

# ==========================================
# Auto-detect compose file
# ==========================================
COMPOSE_FILE=""

print_info "Detecting deployment configuration..."

SAMPLE_CONTAINERS=("mysql" "amf" "nrf" "upf" "upf_1" "du_1" "ue_1" "cucp" "cuup" "cuup_1" "flexric")
DETECTED_COMPOSE_FILE=""

for container in "${SAMPLE_CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        DETECTED_COMPOSE_FILE=$(docker inspect "$container" 2>/dev/null | grep -oP '"com.docker.compose.project.config_files":\s*"\K[^"]+' | head -1)
        if [ -n "$DETECTED_COMPOSE_FILE" ]; then
            print_info "Detected compose file from container '$container': $DETECTED_COMPOSE_FILE"
            COMPOSE_FILE="$DETECTED_COMPOSE_FILE"
            break
        fi
    fi
done

if [ -z "$COMPOSE_FILE" ]; then
    print_warn "Could not detect compose file from running containers"
    print_info "Checking for available compose files..."

    if [ -f "docker-compose-centraloffice.yml" ]; then
        COMPOSE_FILE="docker-compose-centraloffice.yml"
        print_info "Found: docker-compose-centraloffice.yml"
    elif [ -f "docker-compose-edge.yml" ]; then
        COMPOSE_FILE="docker-compose-edge.yml"
        print_info "Found: docker-compose-edge.yml"
    elif [ -f "docker-compose.yml" ]; then
        COMPOSE_FILE="docker-compose.yml"
        print_info "Found: docker-compose.yml"
    else
        print_error "No docker-compose file found in current directory"
        exit 1
    fi

    if [ "$FORCE" = false ]; then
        echo ""
        read -p "Use $COMPOSE_FILE? (Y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            print_info "Shutdown cancelled"
            exit 0
        fi
    fi
fi

print_info "Using compose file: $COMPOSE_FILE"
echo ""

# Confirmation
if [ "$FORCE" = false ]; then
    read -p "Are you sure you want to stop the 5G network? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Shutdown cancelled"
        exit 0
    fi
fi

if [ "$REMOVE_VOLUMES" = true ] && [ "$FORCE" = false ]; then
    print_warn "This will remove volumes and DELETE all database data!"
    read -p "Are you absolutely sure? (yes/N): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_info "Volume removal cancelled. Stopping containers only..."
        REMOVE_VOLUMES=false
    fi
fi

# ==========================================
# Step 1: Clean SCTP rules BEFORE stopping containers
# ==========================================
cleanup_sctp_rules
echo ""

# ==========================================
# Step 2: Graceful shutdown in reverse order
# ==========================================
print_stage "Stopping 5G network components..."
echo ""

print_info "Stopping User Equipment..."
docker compose -f "$COMPOSE_FILE" stop ue_1 2>/dev/null || true

print_info "Stopping L2 Proxy..."
docker compose -f "$COMPOSE_FILE" stop l2_proxy 2>/dev/null || true

print_info "Stopping FlexRIC..."
docker compose -f "$COMPOSE_FILE" stop flexric 2>/dev/null || true

print_info "Stopping RAN components..."
docker compose -f "$COMPOSE_FILE" stop du_1 cuup cuup_1 cucp 2>/dev/null || true

print_info "Stopping UPF and External DN..."
docker compose -f "$COMPOSE_FILE" stop upf ext_dn upf_1 ext_dn_1 2>/dev/null || true

print_info "Stopping Core Network Functions..."
docker compose -f "$COMPOSE_FILE" stop amf smf pcf nssf udm udr ausf nrf 2>/dev/null || true

print_info "Stopping MySQL..."
docker compose -f "$COMPOSE_FILE" stop mysql 2>/dev/null || true

echo ""
print_info "All services stopped"

# ==========================================
# Step 3: Remove containers and networks
# ==========================================
print_info "Removing containers..."
docker compose -f "$COMPOSE_FILE" rm -f 2>/dev/null || true

DOWN_CMD="docker compose -f \"$COMPOSE_FILE\" down"

if [ "$REMOVE_VOLUMES" = true ]; then
    DOWN_CMD="$DOWN_CMD -v"
    print_warn "Removing volumes (database data will be lost)..."
fi

eval $DOWN_CMD 2>/dev/null || true

# Cleanup orphaned containers
print_info "Cleaning up orphaned containers..."
docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true

if [ "$REMOVE_VOLUMES" = true ]; then
    print_info "Pruning unused volumes..."
    docker volume prune -f 2>/dev/null || true
fi

echo ""
print_info "================================================"
print_info "5G Network shutdown complete!"
print_info "Compose file used: $COMPOSE_FILE"
print_info "================================================"
echo ""

# Show remaining Docker resources
REMAINING_CONTAINERS=$(docker ps -a --format "{{.Names}}" 2>/dev/null | wc -l)

if [ "$REMAINING_CONTAINERS" -gt 0 ]; then
    print_warn "Some containers may still exist:"
    docker ps -a --format "  {{.Names}} ({{.Status}})" 2>/dev/null
    echo ""
    echo "To forcefully clean up all Docker resources:"
    echo "  docker system prune -a --volumes"
else
    print_info "All containers have been removed"
fi

echo ""
if [[ "$COMPOSE_FILE" == *"centraloffice"* ]]; then
    print_info "To restart: ./deploy-centraloffice.sh"
elif [[ "$COMPOSE_FILE" == *"edge"* ]]; then
    print_info "To restart: ./deploy-edge.sh"
fi
