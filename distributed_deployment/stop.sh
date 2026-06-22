#!/bin/bash

# stop.sh - Stop 5G deployment and clean ALL custom nftables rules
# Works on ALL THREE machines: Core (200), Centraloffice (193), Edge (243)
# Fully dynamic — parses compose files for subnets, bridges, and port mappings.

set -u

echo "================================================"
echo "5G Network Emulation - Shutdown Script (3-machine)"
echo "================================================"
echo ""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_stage() { echo -e "${BLUE}[STAGE]${NC} $1"; }
print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==========================================
# Parse args
# ==========================================
REMOVE_VOLUMES=false
FORCE=false
COMPOSE_FILE_ARG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --volumes|-v)  REMOVE_VOLUMES=true; shift ;;
        --force|-f)    FORCE=true; shift ;;
        --all|-a)      REMOVE_VOLUMES=true; shift ;;
        --file|-c)     COMPOSE_FILE_ARG="$2"; shift 2 ;;
        --help|-h)
            cat <<EOF
Usage: $0 [OPTIONS]
  --file, -c FILE   Specific compose file (otherwise auto-detects)
  --volumes, -v     Remove volumes (DB data loss)
  --all, -a         Same as --volumes
  --force, -f       Skip confirmation prompts
  --help, -h        Show this help
EOF
            exit 0 ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ==========================================
# Auto-detect compose file
# ==========================================
COMPOSE_FILE=""
print_info "Detecting deployment configuration..."

if [ -n "$COMPOSE_FILE_ARG" ]; then
    COMPOSE_FILE="$COMPOSE_FILE_ARG"
else
    # Try detecting from running containers (any of the new names)
    for container in mysql nrf amf smf cucp \
                     cuup_co cuup_e \
                     upf_core upf_co upf_e \
                     ext_dn_core ext_dn_co ext_dn_e \
                     du_co du_e1 du_e2 \
                     ue_1 flexric; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            COMPOSE_FILE=$(docker inspect "$container" 2>/dev/null \
                | grep -o '"com.docker.compose.project.config_files": "[^"]*"' \
                | head -1 | cut -d'"' -f4)
            if [ -n "$COMPOSE_FILE" ]; then
                print_info "Detected via container '$container': $COMPOSE_FILE"
                break
            fi
        fi
    done

    # Fallback: pick whichever compose file is present in CWD
    if [ -z "$COMPOSE_FILE" ]; then
        for f in docker-compose-core.yml docker-compose-centraloffice.yml docker-compose-edge.yml; do
            if [ -f "$f" ]; then
                COMPOSE_FILE="$f"
                print_info "Using local file: $COMPOSE_FILE"
                break
            fi
        done
    fi
fi

if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    print_error "No docker-compose file found or specified"
    print_error "Use: $0 --file <compose-file>"
    exit 1
fi

# Identify which machine this is (for logging)
MACHINE_ROLE="unknown"
case "$COMPOSE_FILE" in
    *core*)          MACHINE_ROLE="CORE (192.168.0.200)" ;;
    *centraloffice*) MACHINE_ROLE="CENTRALOFFICE (192.168.0.193)" ;;
    *edge*)          MACHINE_ROLE="EDGE (192.168.0.243)" REMOVE_VOLUMES=true ;;
esac
print_info "Machine role: $MACHINE_ROLE"
echo ""

# ==========================================
# Confirmations
# ==========================================
if [ "$FORCE" = false ]; then
    read -p "Stop deployment using $COMPOSE_FILE? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; exit 0; }
fi

if [ "$REMOVE_VOLUMES" = true ] && [ "$FORCE" = false ]; then
    print_warn "This will DELETE all persistent volume data (MySQL DB, logs, etc.)"
    read -p "Type 'yes' to confirm: " -r; echo
    [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]] && REMOVE_VOLUMES=false && print_info "Volumes will be kept"
fi

# ==========================================
# Helper: Extract from compose file
# ==========================================
_extract_subnets() {
    grep -oP 'subnet:\s*\K[0-9./]+' "$COMPOSE_FILE" 2>/dev/null | sort -u
}

_extract_bridges() {
    grep -oP 'com\.docker\.network\.bridge\.name:\s*\K\S+' "$COMPOSE_FILE" 2>/dev/null | sort -u
}

_extract_host_ip() {
    # Extract any IP used as host binding in port mappings
    grep -oP '"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?=:\d+:\d+/(sctp|udp|tcp))' "$COMPOSE_FILE" 2>/dev/null \
        | sort -u | head -1
}

_extract_sctp_ports() {
    grep -oP '\d+(?=/sctp)' "$COMPOSE_FILE" 2>/dev/null | sort -u
}

_extract_udp_ports() {
    grep -oP '\d+(?=/udp)' "$COMPOSE_FILE" 2>/dev/null | sort -u
}

_extract_service_names() {
    # 2-space-indented keys under `services:` (simple heuristic)
    awk '/^services:/{s=1;next} s==1 && /^  [a-zA-Z_][a-zA-Z0-9_-]*:$/{gsub(/[: ]/,""); print}' "$COMPOSE_FILE"
}

HOST_IP=$(_extract_host_ip)
SUBNETS=$(_extract_subnets)
BRIDGES=$(_extract_bridges)
SCTP_PORTS=$(_extract_sctp_ports)
UDP_PORTS=$(_extract_udp_ports)
SERVICES=$(_extract_service_names)

print_info "Parsed from $COMPOSE_FILE:"
print_info "  Host IP:    ${HOST_IP:-<none>}"
print_info "  Subnets:    $(echo $SUBNETS | tr '\n' ' ')"
print_info "  Bridges:    $(echo $BRIDGES | tr '\n' ' ')"
print_info "  SCTP ports: $(echo $SCTP_PORTS | tr '\n' ' ')"
print_info "  UDP ports:  $(echo $UDP_PORTS | tr '\n' ' ')"
echo ""

# ==========================================
# nftables cleanup helper
# ==========================================
nft_remove_all_matching() {
    local table=$1 chain=$2 pattern=$3 removed=0
    sudo nft list chain ${table} ${chain} > /dev/null 2>&1 || return 0
    while true; do
        local H
        H=$(sudo nft -a list chain ${table} ${chain} 2>/dev/null \
            | grep "${pattern}" | head -1 \
            | grep -oP 'handle \K\d+' || echo "")
        [ -z "$H" ] && break
        sudo nft delete rule ${table} ${chain} handle "$H" 2>/dev/null && removed=$((removed + 1)) || break
    done
    echo "$removed"
}

# ==========================================
# Bulletproof dynamic cleanup
# ==========================================
cleanup_custom_nft_rules() {
    print_stage "Cleaning dynamic nftables rules (SCTP + UDP + MASQUERADE)..."
    local total_cleaned=0

    # --- 1. NAT DOCKER: SCTP DNAT rules ---
    print_info "  [1/7] NAT DOCKER: SCTP DNAT rules"
    local n
    n=$(nft_remove_all_matching "ip nat" "DOCKER" "sctp")
    [ "${n:-0}" -gt 0 ] && print_info "    Removed $n SCTP DNAT rule(s)" && total_cleaned=$((total_cleaned + n))

    # --- 2. NAT DOCKER: UDP DNAT rules for ports in compose ---
    print_info "  [2/7] NAT DOCKER: UDP DNAT rules (compose ports)"
    for port in $UDP_PORTS; do
        n=$(nft_remove_all_matching "ip nat" "DOCKER" "udp dport ${port}")
        [ "${n:-0}" -gt 0 ] && print_info "    Removed $n UDP/${port} DNAT rule(s)" && total_cleaned=$((total_cleaned + n))
    done

    # --- 3. NAT PREROUTING: stray UDP rules (PFCP, GTP-U) ---
    print_info "  [3/7] NAT PREROUTING: UDP DNAT rules"
    for port in $UDP_PORTS; do
        n=$(nft_remove_all_matching "ip nat" "PREROUTING" "udp dport ${port}")
        [ "${n:-0}" -gt 0 ] && print_info "    Removed $n PREROUTING UDP/${port} rule(s)" && total_cleaned=$((total_cleaned + n))
    done

    # --- 4. NAT POSTROUTING: MASQUERADE for each compose subnet ---
    print_info "  [4/7] NAT POSTROUTING: MASQUERADE rules for compose subnets"
    for subnet in $SUBNETS; do
        # Escape the subnet for regex
        local esc_subnet
        esc_subnet=$(echo "$subnet" | sed 's/\./\\./g')
        n=$(nft_remove_all_matching "ip nat" "POSTROUTING" "${esc_subnet}.*masquerade")
        [ "${n:-0}" -gt 0 ] && print_info "    Removed $n MASQUERADE rule(s) for ${subnet}" && total_cleaned=$((total_cleaned + n))
    done

    # Also clean any host-IP-scoped MASQUERADE for our SCTP/UDP ports
    if [ -n "$HOST_IP" ]; then
        for port in $SCTP_PORTS $UDP_PORTS; do
            local esc_host
            esc_host=$(echo "$HOST_IP" | sed 's/\./\\./g')
            n=$(nft_remove_all_matching "ip nat" "POSTROUTING" "${esc_host}.*${port}")
            [ "${n:-0}" -gt 0 ] && print_info "    Removed $n MASQUERADE rule(s) for ${HOST_IP}:${port}" && total_cleaned=$((total_cleaned + n))
        done
    fi

    # --- 5. Filter DOCKER: SCTP FORWARD rules ---
    print_info "  [5/7] Filter DOCKER: SCTP FORWARD rules"
    n=$(nft_remove_all_matching "ip filter" "DOCKER" "sctp")
    [ "${n:-0}" -gt 0 ] && print_info "    Removed $n SCTP FORWARD rule(s)" && total_cleaned=$((total_cleaned + n))

    # Also UDP FORWARD rules for our ports
    for port in $UDP_PORTS; do
        n=$(nft_remove_all_matching "ip filter" "DOCKER" "udp.*${port}")
        [ "${n:-0}" -gt 0 ] && print_info "    Removed $n UDP/${port} FORWARD rule(s)" && total_cleaned=$((total_cleaned + n))
    done

    # --- 6. DOCKER-BRIDGE: duplicate jumps per bridge ---
    print_info "  [6/7] DOCKER-BRIDGE: duplicate jump cleanup"
    if sudo nft list chain ip filter DOCKER-BRIDGE > /dev/null 2>&1; then
        for bridge in $BRIDGES; do
            local count
            count=$(sudo nft -a list chain ip filter DOCKER-BRIDGE 2>/dev/null \
                | grep -c "oifname \"${bridge}\".*jump DOCKER")
            while [ "$count" -gt 1 ]; do
                local H
                H=$(sudo nft -a list chain ip filter DOCKER-BRIDGE 2>/dev/null \
                    | grep "oifname \"${bridge}\".*jump DOCKER" | tail -1 \
                    | grep -oP 'handle \K\d+' || echo "")
                [ -z "$H" ] && break
                sudo nft delete rule ip filter DOCKER-BRIDGE handle "$H" 2>/dev/null \
                    && print_info "    Removed duplicate DOCKER-BRIDGE jump for ${bridge}" \
                    && total_cleaned=$((total_cleaned + 1))
                count=$((count - 1))
            done
        done
    fi

    # --- 7. DOCKER-ISOLATION-STAGE-1: SCTP bypass rules per bridge ---
    print_info "  [7/7] DOCKER-ISOLATION-STAGE-1: SCTP bypass rules"
    if sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 > /dev/null 2>&1; then
        n=$(nft_remove_all_matching "ip filter" "DOCKER-ISOLATION-STAGE-1" "sctp.*accept")
        [ "${n:-0}" -gt 0 ] && print_info "    Removed $n SCTP isolation bypass rule(s)" && total_cleaned=$((total_cleaned + n))
    fi

    print_info "  [8/8] Cross-host UDP DNAT (UDPFIX rules)"
    for chain in PREROUTING OUTPUT POSTROUTING; do
        n=$(nft_remove_all_matching "ip nat" "$chain" 'comment "UDPFIX')
        [ "${n:-0}" -gt 0 ] && print_info "    Removed $n UDPFIX rule(s) from $chain" \
                    && total_cleaned=$((total_cleaned + n))
    done

    # --- IP aliases cleanup (if any added by setup scripts) ---
    for bridge in $BRIDGES; do
        # Remove /32 aliases matching any of our subnets on this bridge (rare but possible)
        local aliases
        aliases=$(ip addr show "$bridge" 2>/dev/null | grep -oP 'inet \K[0-9.]+/32' || echo "")
        for a in $aliases; do
            sudo ip addr del "$a" dev "$bridge" 2>/dev/null \
                && print_info "    Removed IP alias $a from $bridge"
        done
    done

    # --- Restore conntrack checksum ---
    if [ -f /proc/sys/net/netfilter/nf_conntrack_checksum ]; then
        sudo sysctl -w net.netfilter.nf_conntrack_checksum=1 > /dev/null 2>&1 || true
    fi

    print_info ""
    if [ "$total_cleaned" -gt 0 ]; then
        print_info "✓ Cleaned $total_cleaned custom nftables rule(s) total"
    else
        print_info "✓ No custom rules found to clean"
    fi
}

# ==========================================
# STEP 1: Clean rules FIRST (before Docker tears chains down)
# ==========================================
cleanup_custom_nft_rules
echo ""

# ==========================================
# STEP 2: Graceful stop in dependency-aware order
# ==========================================
print_stage "Stopping containers gracefully..."

# Stop in reverse-dependency order, using whichever services exist in this compose file
# Tier 1: UEs + xApps first (top of stack)
for svc in ue_1 xapp l2_proxy flexric; do
    echo "$SERVICES" | grep -q "^${svc}$" && \
        docker compose -f "$COMPOSE_FILE" stop "$svc" 2>/dev/null || true
done

# Tier 2: DUs
for svc in du_co du_e1 du_e2; do
    echo "$SERVICES" | grep -q "^${svc}$" && \
        docker compose -f "$COMPOSE_FILE" stop "$svc" 2>/dev/null || true
done

# Tier 3: CU-UPs
for svc in cuup_co cuup_e; do
    echo "$SERVICES" | grep -q "^${svc}$" && \
        docker compose -f "$COMPOSE_FILE" stop "$svc" 2>/dev/null || true
done

# Tier 4: CU-CP
for svc in cucp; do
    echo "$SERVICES" | grep -q "^${svc}$" && \
        docker compose -f "$COMPOSE_FILE" stop "$svc" 2>/dev/null || true
done

# Tier 5: UPFs + ext_dns
for svc in ext_dn_core ext_dn_co ext_dn_e upf_core upf_co upf_e; do
    echo "$SERVICES" | grep -q "^${svc}$" && \
        docker compose -f "$COMPOSE_FILE" stop "$svc" 2>/dev/null || true
done

# Tier 6: 5G Core NFs
for svc in amf smf pcf nssf udm udr ausf nrf; do
    echo "$SERVICES" | grep -q "^${svc}$" && \
        docker compose -f "$COMPOSE_FILE" stop "$svc" 2>/dev/null || true
done

# Tier 7: MySQL last
for svc in mysql; do
    echo "$SERVICES" | grep -q "^${svc}$" && \
        docker compose -f "$COMPOSE_FILE" stop "$svc" 2>/dev/null || true
done

print_info "All services stopped"
echo ""

# ==========================================
# STEP 3: Remove containers, networks, (optionally) volumes
# ==========================================
print_stage "Removing containers and networks..."
if [ "$REMOVE_VOLUMES" = true ]; then
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    print_info "Volumes removed"
else
    docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
fi
echo ""

# ==========================================
# STEP 4: Final verification (dynamic)
# ==========================================
print_stage "Final rule verification..."
echo ""
print_info "=== Remaining custom nftables rules (should be empty) ==="

verification_fail=0

# Helper: safe count (always returns a single integer, even on 0 matches)
nft_count() {
    # $1 = table, $2 = chain, $3 = pattern (extended regex)
    sudo nft list chain "$1" "$2" 2>/dev/null | grep -Ec "$3" || true
}

# --- Check NAT DOCKER for SCTP ---
remaining=$(sudo nft list chain ip nat DOCKER 2>/dev/null | grep -c sctp)
remaining=${remaining:-0}
if [ "$remaining" -gt 0 ] 2>/dev/null; then
    print_warn "  ⚠ $remaining SCTP DNAT rule(s) still in NAT DOCKER"
    verification_fail=$((verification_fail + 1))
else
    print_info "  ✓ NAT DOCKER clean (SCTP)"
fi

# --- Check NAT POSTROUTING for each subnet ---
postrouting_fail=0
for subnet in $SUBNETS; do
    esc=$(echo "$subnet" | sed 's/\./\\./g')
    remaining=$(sudo nft list chain ip nat POSTROUTING 2>/dev/null | grep -cE "${esc}.*masquerade")
    remaining=${remaining:-0}
    if [ "$remaining" -gt 0 ] 2>/dev/null; then
        print_warn "  ⚠ $remaining MASQUERADE rule(s) remain for ${subnet}"
        postrouting_fail=$((postrouting_fail + 1))
        verification_fail=$((verification_fail + 1))
    fi
done
[ "$postrouting_fail" -eq 0 ] && print_info "  ✓ NAT POSTROUTING clean (all compose subnets)"

# --- Check DOCKER-ISOLATION for SCTP bypass ---
remaining=$(sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null | grep -cE "sctp.*accept")
remaining=${remaining:-0}
if [ "$remaining" -gt 0 ] 2>/dev/null; then
    print_warn "  ⚠ $remaining SCTP isolation bypass rule(s) remain"
    verification_fail=$((verification_fail + 1))
else
    print_info "  ✓ DOCKER-ISOLATION-STAGE-1 clean (SCTP)"
fi

echo ""
print_info "================================================"
print_info "Shutdown complete for: $MACHINE_ROLE"
print_info "Compose file: $COMPOSE_FILE"
print_info "================================================"
echo ""

# ==========================================
# Remaining containers summary
# ==========================================
REMAINING=$(docker ps -a --format "{{.Names}}" 2>/dev/null | wc -l)
if [ "$REMAINING" -gt 0 ]; then
    print_warn "Other containers still exist on this host (not from this compose):"
    docker ps -a --format "  {{.Names}} ({{.Status}})" 2>/dev/null
fi

echo ""
# Machine-specific restart hint
case "$COMPOSE_FILE" in
    *core*)          print_info "To restart: ./deploy-core.sh" ;;
    *centraloffice*) print_info "To restart: ./deploy-centraloffice.sh" ;;
    *edge*)          print_info "To restart: ./deploy-edge.sh" ;;
esac
echo ""
