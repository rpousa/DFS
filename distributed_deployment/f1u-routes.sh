#!/bin/bash
# f1u-routes.sh - Cross-machine F1-U routing helper (idempotent, no teardown needed)

CO_F1U_SUBNET="192.168.74.128/26"
EDGE_F1U_SUBNET="192.168.84.128/26"
CO_N3_SUBNET="192.168.100.128/26"
EDGE_N3_SUBNET="192.168.101.128/26"

CORE_IP="${CORE_IP:-192.168.0.200}"
CO_IP="${CO_IP:-192.168.0.193}"
EDGE_IP="${EDGE_IP:-192.168.0.243}"

CUUP_CO_F1U_IP="192.168.74.140"
DU_E1_F1U_IP="192.168.84.151"

_RT_GREEN='\033[0;32m'; _RT_YELLOW='\033[1;33m'; _RT_RED='\033[0;31m'; _RT_NC='\033[0m'
_rt_info() { echo -e "${_RT_GREEN}[ROUTE]${_RT_NC} $*"; }
_rt_warn() { echo -e "${_RT_YELLOW}[ROUTE]${_RT_NC} $*"; }
_rt_err()  { echo -e "${_RT_RED}[ROUTE]${_RT_NC} $*"; }

# ─────────────────────────────────────────────────────────
# Idempotent route adder (uses ip route replace)
# ─────────────────────────────────────────────────────────
_rt_add_route() {
    local subnet="$1" gw="$2" desc="$3"
    if ip route show "$subnet" 2>/dev/null | grep -q "via $gw"; then
        _rt_info "✓ Route to $subnet via $gw already exists ($desc)"
        return 0                                   
    fi
    sudo ip route replace "$subnet" via "$gw" || {
        _rt_err "  ✗ Failed to set route $subnet → $gw"; return 1
    }
    _rt_info "✓ Set route to $subnet via $gw ($desc)"
}

# ─────────────────────────────────────────────────────────
# Idempotent DOCKER-USER rule adder
#   Docker reserves DOCKER-USER specifically for user rules:
#   it runs BEFORE the catch-all DROP in DOCKER-FORWARD.
# ─────────────────────────────────────────────────────────
_rt_add_docker_user() {
    local desc="$1"; shift
    if sudo iptables -C DOCKER-USER "$@" 2>/dev/null; then
        _rt_info "✓ DOCKER-USER rule already present ($desc)"
        return 0                                   
    fi
    sudo iptables -N DOCKER-USER 2>/dev/null || true
    if ! sudo iptables -I DOCKER-USER 1 "$@" 2>/dev/null; then
        # Re-check: another concurrent run may have created it
        if sudo iptables -C DOCKER-USER "$@" 2>/dev/null; then
            _rt_info "✓ DOCKER-USER rule appeared concurrently ($desc)"
            return 0
        fi
        _rt_err "  ✗ Failed to add DOCKER-USER rule ($desc)"
        return 1
    fi
    _rt_info "✓ Added DOCKER-USER rule ($desc)"
}

_rt_enable_forwarding() {
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] || \
        sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sudo sysctl -w net.ipv4.conf.all.rp_filter=2     >/dev/null
    sudo sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
    _rt_info "✓ IPv4 forwarding + loose rp_filter"
}

# ─────────────────────────────────────────────────────────
# Docker 28+ installs raw-table drops that block cross-host
# access to internal container IPs. Remove the specific
# drops for the IPs we deliberately want reachable from the LAN.
# ─────────────────────────────────────────────────────────
_rt_remove_raw_isolation_drop() {
    local target_ip="$1" desc="$2"
    local removed=0
    while true; do
        local H
        H=$(sudo nft -a list chain ip raw PREROUTING 2>/dev/null \
            | awk -v ip="$target_ip" '
                $0 ~ "ip daddr " ip " " && /drop/ {
                    for (i=1;i<=NF;i++) if ($i=="handle") { print $(i+1); exit }
                }' | head -1)
        [ -z "$H" ] && break
        sudo nft delete rule ip raw PREROUTING handle "$H" 2>/dev/null || break
        removed=$((removed + 1))
    done
    if [ "$removed" -gt 0 ]; then
        _rt_info "✓ Removed $removed raw-PREROUTING drop rule(s) for $target_ip ($desc)"
    else
        _rt_info "✓ No raw-PREROUTING drop rule for $target_ip ($desc)"
    fi
}

# ─────────────────────────────────────────────────────────
# Per-host entrypoints
# ─────────────────────────────────────────────────────────

setup_f1u_routes_core() {
    _rt_info "Core host: no F1-U routes required"
}

setup_f1u_routes_co() {
    _rt_info "Setting up F1-U cross-machine routing on Centraloffice..."
    _rt_enable_forwarding

    # Cross-bridge routes
    _rt_add_route "$EDGE_F1U_SUBNET" "$EDGE_IP" "Edge f1u_net (DL F1-U to DU_e1)"
    _rt_add_route "$EDGE_N3_SUBNET"  "$EDGE_IP" "Edge n3_net (future cross-machine N3)"

    # Inbound UL F1-U: DU_e1 -> CU-UP_co
    _rt_add_docker_user "UL F1-U to CU-UP_co" \
        -p udp -d "$CUUP_CO_F1U_IP" --dport 2153 -j ACCEPT
    _rt_add_docker_user "UL F1-U return from CU-UP_co" \
        -p udp -s "$CUUP_CO_F1U_IP" --sport 2153 -j ACCEPT

    # Outbound DL F1-U: CU-UP_co -> DU_e1 (forwarded out toward Edge)
    _rt_add_docker_user "DL F1-U to DU_e1" \
        -p udp -d "$DU_E1_F1U_IP" --dport 2152 -j ACCEPT
    _rt_add_docker_user "DL F1-U return from DU_e1" \
        -p udp -s "$DU_E1_F1U_IP" --sport 2152 -j ACCEPT

    _rt_remove_raw_isolation_drop "$CUUP_CO_F1U_IP" \
     "CU-UP_co f1u (UL F1-U from DU_e1)"
    _rt_remove_raw_isolation_drop "192.168.74.141" \
     "DU_co f1u (not strictly needed, kept symmetric)"

    _rt_info "Centraloffice F1-U routing ready"
}

setup_f1u_routes_edge() {
    _rt_info "Setting up F1-U cross-machine routing on Edge..."
    _rt_enable_forwarding

    _rt_add_route "$CO_F1U_SUBNET" "$CO_IP" "CO f1u_net (UL F1-U to CU-UP_co)"
    _rt_add_route "$CO_N3_SUBNET"  "$CO_IP" "CO n3_net (future cross-machine N3)"

    # DL F1-U arriving from CO into DU_e1
    _rt_add_docker_user "DL F1-U to DU_e1" \
        -p udp -d "$DU_E1_F1U_IP" --dport 2152 -j ACCEPT
    _rt_add_docker_user "DL F1-U return from DU_e1" \
        -p udp -s "$DU_E1_F1U_IP" --sport 2152 -j ACCEPT

    # UL F1-U being routed out toward CO
    _rt_add_docker_user "UL F1-U to CU-UP_co" \
        -p udp -d "$CUUP_CO_F1U_IP" --dport 2153 -j ACCEPT
    _rt_add_docker_user "UL F1-U return from CU-UP_co" \
        -p udp -s "$CUUP_CO_F1U_IP" --sport 2153 -j ACCEPT

    _rt_remove_raw_isolation_drop "$DU_E1_F1U_IP" \
       "DU_e1 f1u (DL F1-U from CU-UP_co)"
    _rt_remove_raw_isolation_drop "192.168.84.140" \
     "CU-UP_e f1u (in case of future cross-host)"


    _rt_info "Edge F1-U routing ready"
}

verify_f1u_routes() {
    local role="$1"
    _rt_info "Verifying F1-U cross-machine reachability (UDP, not ICMP)..."
    case "$role" in
        co)
            # UDP probe DU_e1's GTP-U port from CO host
            if echo "" | timeout 2 nc -u -w1 "$DU_E1_F1U_IP" 2152 2>/dev/null; then
                _rt_info "✓ CO can send UDP to DU_e1 ($DU_E1_F1U_IP:2152)"
            else
                _rt_warn "⚠ UDP probe inconclusive (nc returns 0 on send regardless)"
            fi
            # Real test: capture GTP-U
            _rt_info "  Run: sudo tcpdump -ni any 'udp port 2152 or udp port 2153' to confirm GTP-U"
            ;;
        edge)
            if echo "" | timeout 2 nc -u -w1 "$CUUP_CO_F1U_IP" 2153 2>/dev/null; then
                _rt_info "✓ Edge can send UDP to CU-UP_co ($CUUP_CO_F1U_IP:2153)"
            else
                _rt_warn "⚠ UDP probe inconclusive"
            fi
            _rt_info "  Run: sudo tcpdump -ni any 'udp port 2152 or udp port 2153' to confirm GTP-U"
            ;;
    esac
}