#!/bin/bash

# fix-sctp-routing.sh — Dynamic SCTP routing fixer for Docker containers
#
# Parses a docker-compose YAML file, finds all /sctp port mappings,
# detects the correct container IPs and bridge interfaces, and fixes
# Docker's broken nftables rules for SCTP.
#
# Docker's SCTP problems:
#   1. docker-proxy cannot handle SCTP — only kernel nftables can
#   2. Docker's 'nft add' appends DNAT rules AFTER catch-all DROP rules
#   3. DNAT may point to the wrong container IP (first network vs bind address)
#   4. Conntrack checksum issues with SCTP require disabling nf_conntrack_checksum
#   5. Docker isolation chains (DOCKER-ISOLATION-STAGE-1/2) block cross-bridge SCTP
#
# Usage:
#   ./fix-sctp-routing.sh <docker-compose-file> [host_ip]
#
# Can also be sourced:
#   source fix-sctp-routing.sh
#   fix_sctp_routing "docker-compose-core.yml" "192.168.0.200"

set -euo pipefail

# ==========================================
# Colors
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

_print_stage() { echo -e "${BLUE}[SCTP-FIX]${NC} $1"; }
_print_info()  { echo -e "${GREEN}[SCTP-FIX]${NC} $1"; }
_print_warn()  { echo -e "${YELLOW}[SCTP-FIX]${NC} $1"; }
_print_error() { echo -e "${RED}[SCTP-FIX]${NC} $1"; }
_print_detail(){ echo -e "${CYAN}[SCTP-FIX]${NC}   $1"; }

# ==========================================
# Helper: Remove ALL nftables rules matching a pattern
# ==========================================
_nft_remove_all_matching() {
    local table=$1
    local chain=$2
    local pattern=$3
    local removed=0
    while true; do
        local H
        H=$(sudo nft -a list chain ${table} ${chain} 2>/dev/null \
            | grep "${pattern}" | head -1 \
            | grep -oP 'handle \K\d+' || echo "")
        [ -z "$H" ] && break
        sudo nft delete rule ${table} ${chain} handle "$H"
        ((removed++))
    done
    [ $removed -gt 0 ] && _print_detail "Removed $removed old rule(s) matching: $pattern"
}

# ==========================================
# Parse docker-compose YAML for SCTP port mappings
# Returns lines of: container_name host_ip host_port container_port
#
# Handles formats:
#   - "192.168.0.200:38412:38412/sctp"
#   - "38412:38412/sctp"
#   - "38412/sctp"  (no host mapping — skip)
# ==========================================
_parse_sctp_ports() {
    local compose_file=$1
    local default_host_ip=$2

    # We use a simple awk parser rather than requiring yq/python
    # It tracks the current service name and extracts /sctp port lines
    awk -v default_ip="$default_host_ip" '
    /^  [a-zA-Z_][a-zA-Z0-9_-]*:/ {
        # Service definition (2-space indent, ends with colon)
        gsub(/^  /, ""); gsub(/:.*/, "");
        current_service = $0;
        in_ports = 0;
        next;
    }
    /^    ports:/ {
        in_ports = 1;
        next;
    }
    in_ports && /^    -/ && /\/sctp/ {
        line = $0;
        # Strip leading whitespace, dash, quotes
        gsub(/^[[:space:]]*-[[:space:]]*"?/, "", line);
        gsub(/"[[:space:]]*$/, "", line);
        # Remove trailing comments
        gsub(/#.*$/, "", line);
        # Remove /sctp suffix
        gsub(/\/sctp[[:space:]]*$/, "", line);

        # Count colons to determine format
        n = split(line, parts, ":");
        if (n == 3) {
            # "host_ip:host_port:container_port"
            print current_service " " parts[1] " " parts[2] " " parts[3];
        } else if (n == 2) {
            # "host_port:container_port"
            print current_service " " default_ip " " parts[1] " " parts[2];
        }
        # n==1 means no host mapping (internal only) — skip
        next;
    }
    in_ports && /^    [^ -]/ {
        # Exited ports block
        in_ports = 0;
    }
    in_ports && /^  [a-zA-Z]/ {
        # Exited to next top-level service key
        in_ports = 0;
    }
    ' "$compose_file"
}

# ==========================================
# Detect which Docker bridge a container's target IP is on
# Returns the bridge interface name (e.g., br-core)
# ==========================================
_detect_bridge_for_ip() {
    local container=$1
    local target_ip=$2

    # Iterate over all networks the container is attached to
    local networks
    networks=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$container" 2>/dev/null || echo "")

    for net in $networks; do
        local net_ip
        net_ip=$(docker inspect -f "{{.NetworkSettings.Networks.${net}.IPAddress}}" "$container" 2>/dev/null || echo "")
        if [ "$net_ip" = "$target_ip" ]; then
            # Get the bridge name for this Docker network
            local net_id
            net_id=$(docker network inspect -f '{{.Id}}' "$net" 2>/dev/null || echo "")
            if [ -n "$net_id" ]; then
                # Docker bridge name is either custom (from driver_opts) or br-<short_id>
                local bridge
                bridge=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$net" 2>/dev/null || echo "")
                if [ -z "$bridge" ]; then
                    bridge="br-${net_id:0:12}"
                fi
                echo "$bridge"
                return 0
            fi
        fi
    done

    # Fallback: try to find which bridge has a route to this IP
    local bridge
    bridge=$(ip route get "$target_ip" 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || echo "")
    [ -n "$bridge" ] && echo "$bridge" && return 0

    echo ""
    return 1
}

# ==========================================
# Get the actual container IP that a service is listening on
# for a given container port. Tries ss inside the container first,
# then falls back to inspecting all network IPs.
# ==========================================
_detect_container_listen_ip() {
    local container=$1
    local container_port=$2

    # Method 1: Check ss inside the container for SCTP listeners
    local listen_ip
    listen_ip=$(docker exec "$container" ss -Slnp 2>/dev/null \
        | grep ":${container_port}" \
        | awk '{print $5}' | cut -d: -f1 | head -1 || echo "")

    # If listening on 0.0.0.0 or *, we need to pick the right network IP
    if [ -n "$listen_ip" ] && [ "$listen_ip" != "0.0.0.0" ] && [ "$listen_ip" != "*" ]; then
        echo "$listen_ip"
        return 0
    fi

    # Method 2: If listening on all interfaces, pick the first non-default network IP
    # Prefer the network whose bridge matches the port's expected usage
    local networks
    networks=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}:{{$v.IPAddress}} {{end}}' "$container" 2>/dev/null || echo "")

    # Return the first IP found (caller can override with bridge detection)
    local first_ip=""
    for entry in $networks; do
        local ip="${entry#*:}"
        if [ -n "$ip" ]; then
            [ -z "$first_ip" ] && first_ip="$ip"
            echo "$ip"
            return 0
        fi
    done

    echo "$first_ip"
}

# ==========================================
# Get ALL IPs for a container across all networks
# Returns: "network_name:ip network_name:ip ..."
# ==========================================
_get_container_all_ips() {
    local container=$1
    docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}:{{$v.IPAddress}} {{end}}' "$container" 2>/dev/null || echo ""
}

# ==========================================
# Main: Fix SCTP routing for a docker-compose file
# ==========================================
fix_sctp_routing() {
    local compose_file="${1:?Usage: fix_sctp_routing <compose-file> [host_ip]}"
    local host_ip="${2:-}"

    if [ ! -f "$compose_file" ]; then
        _print_error "Compose file not found: $compose_file"
        return 1
    fi

    # Auto-detect host IP if not provided
    if [ -z "$host_ip" ]; then
        # Try to extract from the compose file (first "host_ip:port:port" pattern)
        host_ip=$(grep -oP '"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?=:\d+:\d+/sctp)' "$compose_file" | head -1 || echo "")
        if [ -z "$host_ip" ]; then
            host_ip=$(hostname -I | awk '{print $1}')
        fi
    fi

    echo ""
    _print_stage "═══════════════════════════════════════════════════════"
    _print_stage "Dynamic SCTP Routing Fix"
    _print_stage "  Compose file: $compose_file"
    _print_stage "  Host IP:      $host_ip"
    _print_stage "═══════════════════════════════════════════════════════"
    echo ""

    # -------------------------------------------------------
    # Step 0: Prerequisites
    # -------------------------------------------------------
    _print_stage "Step 0: Prerequisites"

    # Load SCTP kernel module
    if ! lsmod | grep -q "^sctp"; then
        sudo modprobe sctp
        _print_info "Loaded SCTP kernel module"
    else
        _print_info "✓ SCTP kernel module already loaded"
    fi

    # Disable conntrack checksum (SCTP checksums confuse conntrack)
    if [ -f /proc/sys/net/netfilter/nf_conntrack_checksum ]; then
        local current
        current=$(cat /proc/sys/net/netfilter/nf_conntrack_checksum)
        if [ "$current" != "0" ]; then
            sudo sysctl -w net.netfilter.nf_conntrack_checksum=0 > /dev/null 2>&1
            _print_info "Disabled conntrack checksum verification"
        else
            _print_info "✓ Conntrack checksum already disabled"
        fi
    fi
    echo ""

    # -------------------------------------------------------
    # Step 1: Parse SCTP ports from compose file
    # -------------------------------------------------------
    _print_stage "Step 1: Parsing SCTP port mappings from $compose_file"

    local sctp_mappings
    sctp_mappings=$(_parse_sctp_ports "$compose_file" "$host_ip")

    if [ -z "$sctp_mappings" ]; then
        _print_info "No SCTP port mappings found in $compose_file — nothing to fix"
        return 0
    fi

    local mapping_count
    mapping_count=$(echo "$sctp_mappings" | wc -l)
    _print_info "Found $mapping_count SCTP port mapping(s):"
    echo "$sctp_mappings" | while read -r svc hip hport cport; do
        _print_detail "$svc: ${hip}:${hport} → container:${cport}/sctp"
    done
    echo ""

    # -------------------------------------------------------
    # Step 2: For each SCTP mapping, fix DNAT + FORWARD rules
    # -------------------------------------------------------
    _print_stage "Step 2: Fixing nftables rules for each SCTP port"
    echo ""

    local fixed=0
    local failed=0

    echo "$sctp_mappings" | while read -r svc hip hport cport; do
        _print_info "━━━ $svc: ${hip}:${hport}/sctp → :${cport} ━━━"

        # Check if container is running
        if ! docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
            _print_warn "  Container '$svc' is not running — skipping"
            echo ""
            continue
        fi

        # Detect the container IP that's actually listening on this port
        local container_ip
        container_ip=$(_detect_container_listen_ip "$svc" "$cport")

        if [ -z "$container_ip" ]; then
            _print_warn "  Could not detect container IP for $svc:$cport — skipping"
            echo ""
            continue
        fi

        # Detect which bridge this IP is on
        local bridge
        bridge=$(_detect_bridge_for_ip "$svc" "$container_ip")

        if [ -z "$bridge" ]; then
            _print_warn "  Could not detect bridge for $container_ip — using best effort"
            # Try to get any bridge from the container
            bridge=$(docker inspect "$svc" 2>/dev/null \
                | grep -oP '"com.docker.network.bridge.name":"[^"]*"' \
                | head -1 | cut -d'"' -f4 || echo "")
        fi

        _print_detail "Container IP: $container_ip | Bridge: ${bridge:-unknown}"

        # --- Auto-detect actual listening port inside container ---
        local actual_listen_port
        actual_listen_port=$(docker exec "$svc" ss -Slnp 2>/dev/null \
            | grep -E "(${container_ip}|0\.0\.0\.0|\*):" \
            | grep -oP ":(${cport})\b" | tr -d ':' | head -1 || echo "")
        [ -z "$actual_listen_port" ] && actual_listen_port="$cport"

        # ===== FIX DNAT RULE =====
        _print_detail "Fixing DNAT: ${hip}:${hport} → ${container_ip}:${actual_listen_port}"

        # Remove ALL old DNAT rules for this host port
        _nft_remove_all_matching "ip nat" "DOCKER" "sctp dport ${hport}"

        # INSERT correct DNAT at TOP of DOCKER chain
        if [ -n "$bridge" ]; then
            sudo nft insert rule ip nat DOCKER \
                iifname != "\"${bridge}\"" meta l4proto sctp \
                ip daddr "${hip}" sctp dport "${hport}" \
                counter dnat to "${container_ip}:${actual_listen_port}"
        else
            sudo nft insert rule ip nat DOCKER \
                meta l4proto sctp ip daddr "${hip}" sctp dport "${hport}" \
                counter dnat to "${container_ip}:${actual_listen_port}"
        fi
        _print_detail "✓ DNAT inserted"

        # ===== FIX FORWARD RULE =====
        if [ -n "$bridge" ]; then
            _print_detail "Fixing FORWARD accept for bridge ${bridge}"

            # Remove old FORWARD rules for this port on this bridge
            _nft_remove_all_matching "ip filter" "DOCKER" "${bridge}.*sctp.*${actual_listen_port}"

            # Find the catch-all DROP rule for this bridge
            local drop_handle
            drop_handle=$(sudo nft -a list chain ip filter DOCKER 2>/dev/null \
                | grep "iifname != \"${bridge}\" oifname \"${bridge}\" counter.*drop" \
                | grep -oP 'handle \K\d+' | head -1 || echo "")

            if [ -n "$drop_handle" ]; then
                sudo nft insert rule ip filter DOCKER position "$drop_handle" \
                    iifname != "\"${bridge}\"" oifname "\"${bridge}\"" \
                    meta l4proto sctp ip daddr "${container_ip}" \
                    sctp dport "${actual_listen_port}" counter accept
                _print_detail "✓ FORWARD accept inserted before DROP (handle $drop_handle)"
            else
                sudo nft insert rule ip filter DOCKER \
                    iifname != "\"${bridge}\"" oifname "\"${bridge}\"" \
                    meta l4proto sctp ip daddr "${container_ip}" \
                    sctp dport "${actual_listen_port}" counter accept
                _print_detail "✓ FORWARD accept inserted at top (no DROP found for ${bridge})"
            fi

            # Ensure DOCKER-BRIDGE has a jump for this bridge
            if sudo nft list chain ip filter DOCKER-BRIDGE 2>/dev/null > /dev/null 2>&1; then
                if ! sudo nft list chain ip filter DOCKER-BRIDGE 2>/dev/null \
                    | grep -q "oifname \"${bridge}\".*jump DOCKER"; then
                    sudo nft add rule ip filter DOCKER-BRIDGE \
                        oifname "\"${bridge}\"" counter jump DOCKER
                    _print_detail "✓ Added DOCKER-BRIDGE jump for ${bridge}"
                fi
            fi
        fi

        echo ""
    done

    # -------------------------------------------------------
    # Step 3: Fix Docker isolation chains for SCTP
    # -------------------------------------------------------
    _print_stage "Step 3: Docker isolation chain SCTP bypass"

    if sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null | grep -q "jump DOCKER-ISOLATION-STAGE-2"; then
        _print_info "Docker isolation chains detected — adding SCTP bypass rules"

        # Collect all unique bridges from our SCTP mappings
        local bridges_seen=""
        echo "$sctp_mappings" | while read -r svc hip hport cport; do
            if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
                local cip
                cip=$(_detect_container_listen_ip "$svc" "$cport")
                [ -z "$cip" ] && continue
                local br
                br=$(_detect_bridge_for_ip "$svc" "$cip")
                [ -z "$br" ] && continue

                if ! echo "$bridges_seen" | grep -q "$br"; then
                    bridges_seen="$bridges_seen $br"

                    if ! sudo nft list chain ip filter DOCKER-ISOLATION-STAGE-1 2>/dev/null \
                        | grep -q "iifname \"${br}\" meta l4proto sctp.*accept"; then
                        sudo nft insert rule ip filter DOCKER-ISOLATION-STAGE-1 \
                            iifname "\"${br}\"" meta l4proto sctp counter accept
                        _print_detail "✓ SCTP bypass added for ${br} in ISOLATION-STAGE-1"
                    else
                        _print_detail "✓ SCTP bypass already exists for ${br}"
                    fi
                fi
            fi
        done
    else
        _print_info "✓ No Docker isolation chains found — no bypass needed"
    fi
    echo ""

    # -------------------------------------------------------
    # Step 4: Ensure outbound SCTP MASQUERADE for all container subnets
    # -------------------------------------------------------
    _print_stage "Step 4: Outbound MASQUERADE for container subnets"

    # Extract all subnet definitions from the compose file
    local subnets
    subnets=$(grep -oP 'subnet:\s*\K[0-9./]+' "$compose_file" 2>/dev/null || echo "")

    for subnet in $subnets; do
        if ! sudo nft list chain ip nat POSTROUTING 2>/dev/null | grep -q "${subnet}.*masquerade"; then
            # Determine the bridge for this subnet
            local sub_bridge=""
            # Try to find the bridge from Docker networks
            local net_name
            net_name=$(docker network ls --format '{{.Name}}' 2>/dev/null | while read -r n; do
                local ns
                ns=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$n" 2>/dev/null || echo "")
                if [ "$ns" = "$subnet" ]; then
                    echo "$n"
                    break
                fi
            done)
            if [ -n "$net_name" ]; then
                sub_bridge=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$net_name" 2>/dev/null || echo "")
            fi

            if [ -n "$sub_bridge" ]; then
                sudo nft add rule ip nat POSTROUTING \
                    oifname != "\"${sub_bridge}\"" ip saddr "${subnet}" counter masquerade
                _print_detail "✓ MASQUERADE added for ${subnet} (bridge: ${sub_bridge})"
            else
                _print_detail "MASQUERADE for ${subnet} — bridge unknown, skipping (Docker likely handles it)"
            fi
        else
            _print_detail "✓ MASQUERADE already exists for ${subnet}"
        fi
    done
    echo ""

    # -------------------------------------------------------
    # Step 5: Raw table check
    # -------------------------------------------------------
    _print_stage "Step 5: Raw table verification"
    if sudo nft list chain ip raw PREROUTING 2>/dev/null | grep -q "ip daddr ${host_ip}.*drop"; then
        _print_warn "Raw table has DROP for ${host_ip} — removing..."
        _nft_remove_all_matching "ip raw" "PREROUTING" "ip daddr ${host_ip}.*drop"
    else
        _print_info "✓ Raw table clean"
    fi
    echo ""

    # -------------------------------------------------------
    # Summary: Verify all rules
    # -------------------------------------------------------
    _print_stage "═══════════════════════════════════════════════════════"
    _print_stage "Verification Summary"
    _print_stage "═══════════════════════════════════════════════════════"
    echo ""

    _print_info "SCTP DNAT rules in ip nat DOCKER:"
    sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep sctp | while read -r line; do
        _print_detail "$line"
    done
    [ $? -ne 0 ] && _print_warn "  (none found)"
    echo ""

    _print_info "SCTP FORWARD rules in ip filter DOCKER:"
    sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep sctp | while read -r line; do
        _print_detail "$line"
    done
    [ $? -ne 0 ] && _print_warn "  (none found)"
    echo ""

    _print_info "SCTP listening sockets in containers:"
    echo "$sctp_mappings" | while read -r svc hip hport cport; do
        if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
            local sockets
            sockets=$(docker exec "$svc" ss -Slnp 2>/dev/null | grep -i sctp || echo "  (none)")
            _print_detail "$svc:"
            echo "$sockets" | while read -r s; do
                _print_detail "  $s"
            done
        fi
    done
    echo ""

    # -------------------------------------------------------
    # Optional: Test SCTP connectivity
    # -------------------------------------------------------
    if command -v ncat &> /dev/null; then
        _print_info "Testing SCTP port reachability (from host):"
        echo "$sctp_mappings" | while read -r svc hip hport cport; do
            if timeout 2 ncat --sctp "${hip}" "${hport}" < /dev/null 2>/dev/null; then
                _print_detail "✓ ${hip}:${hport}/sctp ($svc) — REACHABLE"
            else
                _print_detail "✗ ${hip}:${hport}/sctp ($svc) — not reachable (may need container to be listening)"
            fi
        done
    else
        _print_warn "ncat not installed — skipping SCTP connectivity test (apt install ncat)"
    fi
    echo ""

    _print_stage "SCTP routing fix complete for $compose_file"
    echo ""
}

# ==========================================
# Verify SCTP routing (standalone function)
# ==========================================
verify_sctp_routing() {
    local compose_file="${1:?Usage: verify_sctp_routing <compose-file> [host_ip]}"
    local host_ip="${2:-}"

    [ -z "$host_ip" ] && host_ip=$(grep -oP '"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?=:\d+:\d+/sctp)' "$compose_file" | head -1 || hostname -I | awk '{print $1}')

    echo ""
    _print_stage "SCTP Routing Verification for $compose_file"
    echo ""

    _print_info "=== NAT DNAT rules (SCTP) ==="
    sudo nft -a list chain ip nat DOCKER 2>/dev/null | grep sctp || _print_warn "  No SCTP DNAT rules found"
    echo ""

    _print_info "=== Filter FORWARD rules (SCTP) ==="
    sudo nft -a list chain ip filter DOCKER 2>/dev/null | grep sctp || _print_warn "  No SCTP FORWARD rules found"
    echo ""

    _print_info "=== Container SCTP sockets ==="
    local sctp_mappings
    sctp_mappings=$(_parse_sctp_ports "$compose_file" "$host_ip")
    echo "$sctp_mappings" | while read -r svc hip hport cport; do
        if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
            _print_info "  $svc:"
            docker exec "$svc" ss -Slnp 2>/dev/null | grep -i sctp | while read -r s; do
                _print_detail "    $s"
            done
        fi
    done
    echo ""

    if command -v ncat &> /dev/null; then
        _print_info "=== SCTP Connectivity Test ==="
        echo "$sctp_mappings" | while read -r svc hip hport cport; do
            if timeout 2 ncat --sctp "${hip}" "${hport}" < /dev/null 2>/dev/null; then
                _print_info "  ✓ ${hip}:${hport}/sctp ($svc) — REACHABLE"
            else
                _print_warn "  ✗ ${hip}:${hport}/sctp ($svc) — NOT REACHABLE"
            fi
        done
    fi
    echo ""
}

# ==========================================
# If run directly (not sourced), execute
# ==========================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <docker-compose-file> [host_ip]"
        echo ""
        echo "Dynamically parses the compose file for /sctp port mappings"
        echo "and fixes Docker's broken nftables rules."
        echo ""
        echo "Examples:"
        echo "  $0 docker-compose-core.yml 192.168.0.200"
        echo "  $0 docker-compose-centraloffice.yml 192.168.0.193"
        echo "  $0 docker-compose-edge.yml 192.168.0.243"
        exit 1
    fi

    fix_sctp_routing "$1" "${2:-}"
fi
