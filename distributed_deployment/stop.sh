#!/bin/bash

# stop.sh - Stop 5G network and clean ALL custom nftables rules (SCTP + UDP)
# Works on both Machine 1 (centraloffice) and Machine 2 (edge)

echo "================================================"
echo "5G Network Emulation - Shutdown Script"
echo "================================================"
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_stage() { echo -e "${BLUE}[STAGE]${NC} $1"; }
print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
REMOVE_VOLUMES=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --volumes|-v) REMOVE_VOLUMES=true; shift ;;
        --force|-f)   FORCE=true; shift ;;
        --all|-a)     REMOVE_VOLUMES=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "  --volumes, -v   Remove volumes"
            echo "  --all, -a       Remove everything"
            echo "  --force, -f     No confirmation"
            echo "  --help, -h      Show help"
            exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ==========================================
# Bulletproof SCTP and UDP rule cleanup
# ==========================================
cleanup_custom_nft_rules() {
    print_stage "Cleaning up ALL custom nftables rules (SCTP + UDP)..."

    local cleaned=0

    # -------------------------------------------------------
    # 1. Clean NAT DOCKER chain — ALL SCTP DNAT rules
    # -------------------------------------------------------
    if sudo nft list chain ip nat DOCKER > /dev/null 2>&1; then
        print_info "  Cleaning NAT DOCKER chain (SCTP DNAT rules)..."

        local i=0
        while [ $i -lt 50 ]; do
            local line=$(sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep "sctp" | head -1)
            if [ -z "$line" ]; then
                break
            fi
            local handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]*\)/\1/p')
            [ -z "$handle" ] && handle=$(echo "$line" | grep -o 'handle [0-9]*' | grep -o '[0-9]*')
            if [ -z "$handle" ]; then
                break
            fi
            sudo nft delete rule ip nat DOCKER handle $handle 2>/dev/null && cleaned=$((cleaned + 1))
            i=$((i + 1))
        done
        print_info "    Removed $cleaned SCTP DNAT rule(s) from NAT DOCKER"
    else
        print_info "  NAT DOCKER chain not found (networks already removed)"
    fi

    # -------------------------------------------------------
    # 2. Clean NAT PREROUTING chain — UDP DNAT rules (PFCP, GTP-U)
    # -------------------------------------------------------
    local cleaned_udp=0
    if sudo nft list chain ip nat PREROUTING > /dev/null 2>&1; then
        print_info "  Cleaning NAT PREROUTING chain (UDP DNAT rules)..."

        local i=0
        while [ $i -lt 50 ]; do
            local line=$(sudo nft -a list chain ip nat PREROUTING 2>/dev/null | grep -E "udp dport (8805|2152)" | head -1)
            if [ -z "$line" ]; then
                break
            fi
            local handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]*\)/\1/p')
            [ -z "$handle" ] && handle=$(echo "$line" | grep -o 'handle [0-9]*' | grep -o '[0-9]*')
            if [ -z "$handle" ]; then
                break
            fi
            sudo nft delete rule ip nat PREROUTING handle $handle 2>/dev/null && cleaned_udp=$((cleaned_udp + 1))
            i=$((i + 1))
        done
        print_info "    Removed $cleaned_udp UDP DNAT rule(s) from NAT PREROUTING"
    fi

    # -------------------------------------------------------
    # 3. Clean NAT POSTROUTING — MASQUERADE rules we added
    # -------------------------------------------------------
    local cleaned_masq=0
    if sudo nft list chain ip nat POSTROUTING > /dev/null 2>&1; then
        print_info "  Cleaning NAT POSTROUTING chain (custom MASQUERADE rules)..."

        for pattern in "192.168.0.243.*8805" "192.168.0.243.*2152" "192.168.0.193.*8805" "192.168.0.193.*2152" "192.168.71.160" "192.168.61.128/26.*masquerade" "192.168.75.128/26.*masquerade"; do
            local i=0
            while [ $i -lt 10 ]; do
                local line=$(sudo nft -a list chain ip nat POSTROUTING 2>/dev/null | grep "$pattern" | head -1)
                if [ -z "$line" ]; then
                    break
                fi
                local handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]*\)/\1/p')
                [ -z "$handle" ] && handle=$(echo "$line" | grep -o 'handle [0-9]*' | grep -o '[0-9]*')
                if [ -n "$handle" ]; then
                    sudo nft delete rule ip nat POSTROUTING handle $handle 2>/dev/null && cleaned_masq=$((cleaned_masq + 1))
                fi
                i=$((i + 1))
            done
        done
        [ $cleaned_masq -gt 0 ] && print_info "    Removed $cleaned_masq custom MASQUERADE rule(s)"
    fi

    # -------------------------------------------------------
    # 4. Clean filter DOCKER chain — ALL SCTP FORWARD rules
    # -------------------------------------------------------
    local cleaned_fwd=0
    if sudo nft list chain ip filter DOCKER > /dev/null 2>&1; then
        print_info "  Cleaning filter DOCKER chain (SCTP FORWARD rules)..."

        local i=0
        while [ $i -lt 50 ]; do
            local line=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep "sctp" | head -1)
            if [ -z "$line" ]; then
                break
            fi
            local handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]*\)/\1/p')
            [ -z "$handle" ] && handle=$(echo "$line" | grep -o 'handle [0-9]*' | grep -o '[0-9]*')
            if [ -z "$handle" ]; then
                break
            fi
            sudo nft delete rule ip filter DOCKER handle $handle 2>/dev/null && cleaned_fwd=$((cleaned_fwd + 1))
            i=$((i + 1))
        done
        print_info "    Removed $cleaned_fwd SCTP FORWARD rule(s) from filter DOCKER"
    fi

    # -------------------------------------------------------
    # 5. Clean filter FORWARD chain — UDP FORWARD rules (PFCP, GTP-U)
    # -------------------------------------------------------
    local cleaned_fwd_udp=0
    if sudo nft list chain ip filter FORWARD > /dev/null 2>&1; then
        print_info "  Cleaning filter FORWARD chain (UDP FORWARD rules)..."

        local i=0
        while [ $i -lt 50 ]; do
            local line=$(sudo nft -a list chain ip filter FORWARD 2>/dev/null | grep -E "udp.*(8805|2152)" | head -1)
            if [ -z "$line" ]; then
                break
            fi
            local handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]*\)/\1/p')
            [ -z "$handle" ] && handle=$(echo "$line" | grep -o 'handle [0-9]*' | grep -o '[0-9]*')
            if [ -z "$handle" ]; then
                break
            fi
            sudo nft delete rule ip filter FORWARD handle $handle 2>/dev/null && cleaned_fwd_udp=$((cleaned_fwd_udp + 1))
            i=$((i + 1))
        done
        print_info "    Removed $cleaned_fwd_udp UDP FORWARD rule(s) from filter FORWARD"
    fi

    # -------------------------------------------------------
    # 6. Clean DOCKER-BRIDGE — remove extra jumps
    # -------------------------------------------------------
    if sudo nft list chain ip filter DOCKER-BRIDGE > /dev/null 2>&1; then
        for bridge in "br-f1c" "br-e1" "br-core" "br-ran" "br-ext" "br-f1u" "br-n3" "br-sgi"; do
            local count=$(sudo nft -a list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep "oifname \"${bridge}\".*jump DOCKER" | wc -l)
            while [ "$count" -gt 1 ]; do
                local line=$(sudo nft -a list chain ip filter DOCKER-BRIDGE 2>/dev/null | grep "oifname \"${bridge}\".*jump DOCKER" | tail -1)
                local handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]*\)/\1/p')
                [ -z "$handle" ] && handle=$(echo "$line" | grep -o 'handle [0-9]*' | grep -o '[0-9]*')
                if [ -n "$handle" ]; then
                    sudo nft delete rule ip filter DOCKER-BRIDGE handle $handle 2>/dev/null
                    print_info "    Removed extra DOCKER-BRIDGE jump for $bridge"
                fi
                count=$((count - 1))
            done
        done
    fi

    # -------------------------------------------------------
    # 7. Clean DOCKER-ISOLATION-STAGE-1 — SCTP bypass rules
    # -------------------------------------------------------
    if sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 > /dev/null 2>&1; then
        local i=0
        while [ $i -lt 20 ]; do
            local line=$(sudo nft -a list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null | grep "sctp" | head -1)
            if [ -z "$line" ]; then
                break
            fi
            local handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]*\)/\1/p')
            [ -z "$handle" ] && handle=$(echo "$line" | grep -o 'handle [0-9]*' | grep -o '[0-9]*')
            if [ -n "$handle" ]; then
                sudo nft delete rule ip filter DOCKER-ISOLATION-STAGE-1 handle $handle 2>/dev/null
                print_info "    Removed SCTP isolation bypass rule"
            fi
            i=$((i + 1))
        done
    fi

    # -------------------------------------------------------
    # 8. Remove IP aliases for cross-machine UPF routing
    # -------------------------------------------------------
    print_info "  Checking for IP aliases to remove..."

    if ip addr show br-core 2>/dev/null | grep -q "192.168.71.160/32"; then
        sudo ip addr del 192.168.71.160/32 dev br-core 2>/dev/null || true
        print_info "    Removed IP alias 192.168.71.160/32 from br-core"
    fi

    # -------------------------------------------------------
    # 9. Restore conntrack checksum
    # -------------------------------------------------------
    if [ -f /proc/sys/net/netfilter/nf_conntrack_checksum ]; then
        sudo sysctl -w net.netfilter.nf_conntrack_checksum=1 > /dev/null 2>&1 || true
    fi

    # -------------------------------------------------------
    # 10. Verify cleanup
    # -------------------------------------------------------
    local remaining_sctp=0
    local remaining_udp=0

    if sudo nft list chain ip nat DOCKER > /dev/null 2>&1; then
        remaining_sctp=$(sudo nft list chain ip nat DOCKER 2>/dev/null | grep -c "sctp" || echo "0")
    fi
    if sudo nft list chain ip nat PREROUTING > /dev/null 2>&1; then
        remaining_udp=$(sudo nft list chain ip nat PREROUTING 2>/dev/null | grep -cE "udp dport (8805|2152)" || echo "0")
    fi

    if sudo nft list chain ip nat POSTROUTING > /dev/null 2>&1; then
        remaining_masq=$(sudo nft list chain ip nat POSTROUTING 2>/dev/null | grep -cE "192.168\.(61|75)\.128/26.*masquerade" || echo "0")
    fi

    if [ "$remaining_sctp" -eq 0 ] && [ "$remaining_udp" -eq 0 ] && [ "$remaining_masq" -eq 0 ]; then
        print_info "✓ ALL custom nftables rules cleaned up successfully"
    else
        print_warn "⚠ $remaining_sctp SCTP rules and $remaining_udp UDP rules still remain, and $remaining_masq MASQUERADE rules still remain"
    fi
}

# ==========================================
# Auto-detect compose file
# ==========================================
COMPOSE_FILE=""
print_info "Detecting deployment configuration..."

for container in mysql amf nrf upf upf_1 du_1 ue_1 cucp cuup cuup_1 flexric; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        COMPOSE_FILE=$(docker inspect "$container" 2>/dev/null | grep -o '"com.docker.compose.project.config_files": "[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -n "$COMPOSE_FILE" ]; then
            print_info "Detected compose file from container '$container': $COMPOSE_FILE"
            break
        fi
    fi
done

if [ -z "$COMPOSE_FILE" ]; then
    if [ -f "docker-compose-centraloffice.yml" ]; then
        COMPOSE_FILE="docker-compose-centraloffice.yml"
    elif [ -f "docker-compose-edge.yml" ]; then
        COMPOSE_FILE="docker-compose-edge.yml"
    else
        print_error "No docker-compose file found"
        exit 1
    fi
    print_info "Using: $COMPOSE_FILE"
fi

echo ""

# Confirmation
if [ "$FORCE" = false ]; then
    read -p "Stop 5G network using $COMPOSE_FILE? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; exit 0; }
fi

if [ "$REMOVE_VOLUMES" = true ] && [ "$FORCE" = false ]; then
    print_warn "This will DELETE all database data!"
    read -p "Are you sure? (yes/N): " -r
    echo
    [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]] && REMOVE_VOLUMES=false
fi

# ==========================================
# Step 1: Clean custom rules FIRST (while chains still exist)
# ==========================================
cleanup_custom_nft_rules
echo ""

# ==========================================
# Step 2: Stop containers gracefully
# ==========================================
print_stage "Stopping containers..."

docker compose -f "$COMPOSE_FILE" stop ue_1 l2_proxy flexric 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" stop du_1 cuup cuup_1 cucp 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" stop upf ext_dn upf_1 ext_dn_1 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" stop amf smf pcf nssf udm udr ausf nrf 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" stop mysql 2>/dev/null || true

print_info "All services stopped"
echo ""

# ==========================================
# Step 3: Remove containers and networks
# ==========================================
print_stage "Removing containers and networks..."

if [ "$REMOVE_VOLUMES" = true ]; then
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true
else
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
fi

echo ""

# ==========================================
# Step 4: Final cleanup verification
# ==========================================
print_stage "Final rule verification..."

echo ""
print_info "=== Remaining nftables rules (should be 0 custom rules) ==="
sudo nft list chain ip nat DOCKER 2>/dev/null | grep -E "sctp|udp dport 8805|udp dport 2152" || print_info "  ✓ No custom NAT DOCKER rules"
sudo nft list chain ip nat PREROUTING 2>/dev/null | grep -E "udp dport (8805|2152)" || print_info "  ✓ No custom NAT PREROUTING rules"
sudo nft list chain ip nat POSTROUTING 2>/dev/null | grep -E "192.168\.(61|75)\.128/26.*masquerade" || print_info "  ✓ No custom MASQUERADE rules"
sudo nft list chain ip filter DOCKER 2>/dev/null | grep sctp || print_info "  ✓ No custom SCTP FORWARD rules"
sudo nft list chain ip filter FORWARD 2>/dev/null | grep -E "udp.*(8805|2152)" || print_info "  ✓ No custom UDP FORWARD rules"
sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null | grep sctp || print_info "  ✓ No SCTP isolation bypass rules"

echo ""
print_info "================================================"
print_info "5G Network shutdown complete!"
print_info "Compose file: $COMPOSE_FILE"
print_info "================================================"
echo ""

REMAINING=$(docker ps -a --format "{{.Names}}" 2>/dev/null | wc -l)
if [ "$REMAINING" -gt 0 ]; then
    print_warn "Some containers still exist:"
    docker ps -a --format "  {{.Names}} ({{.Status}})" 2>/dev/null
else
    print_info "All containers removed"
fi

echo ""
if [[ "$COMPOSE_FILE" == *"centraloffice"* ]]; then
    print_info "To restart: ./deploy-centraloffice.sh"
elif [[ "$COMPOSE_FILE" == *"edge"* ]]; then
    print_info "To restart: ./deploy-edge.sh"
fi
