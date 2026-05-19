#!/bin/bash
# f1u-routes.sh - Cross-machine F1-U routing helper
# Source this file from deploy-{core,centraloffice,edge}.sh

# ─────────────────────────────────────────────────────────────
# Bridge subnets per host (must match docker-compose-*.yml)
# ─────────────────────────────────────────────────────────────
#   Core         (192.168.0.200): no F1-U bridge (CU-CP only)
#   Centraloffice(192.168.0.193): f1u_net = 192.168.74.128/26  (br-f1u)
#   Edge         (192.168.0.243): f1u_net = 192.168.84.128/26  (br-f1u)
#
#   Plus n3 bridges (in case you need cross-machine N3 too):
#   Centraloffice n3_net = 192.168.100.128/26
#   Edge          n3_net = 192.168.101.128/26
# ─────────────────────────────────────────────────────────────

CO_F1U_SUBNET="192.168.74.128/26"
EDGE_F1U_SUBNET="192.168.84.128/26"
CO_N3_SUBNET="192.168.100.128/26"
EDGE_N3_SUBNET="192.168.101.128/26"

CORE_IP="${CORE_IP:-192.168.0.200}"
CO_IP="${CO_IP:-192.168.0.193}"
EDGE_IP="${EDGE_IP:-192.168.0.243}"

_RT_GREEN='\033[0;32m'; _RT_YELLOW='\033[1;33m'; _RT_RED='\033[0;31m'; _RT_NC='\033[0m'
_rt_info() { echo -e "${_RT_GREEN}[ROUTE]${_RT_NC} $*"; }
_rt_warn() { echo -e "${_RT_YELLOW}[ROUTE]${_RT_NC} $*"; }
_rt_err()  { echo -e "${_RT_RED}[ROUTE]${_RT_NC} $*"; }

# Route + iptables marker file (so `down` knows what to clean)
_RT_STATE_DIR="/var/run/ewoc-routes"
_rt_init_state() { sudo mkdir -p "$_RT_STATE_DIR" 2>/dev/null || true; }

# Add a route only if it doesn't already exist
_rt_add_route() {
    local subnet="$1" gw="$2" desc="$3"

    if ip route show "$subnet" 2>/dev/null | grep -q "via $gw"; then
        _rt_info "✓ Route to $subnet via $gw already exists ($desc)"
        return 0
    fi

    if ip route show "$subnet" 2>/dev/null | grep -q .; then
        _rt_warn "  ↺ Replacing existing route to $subnet"
        sudo ip route replace "$subnet" via "$gw" || {
            _rt_err "  ✗ Failed to replace route $subnet → $gw"; return 1
        }
    else
        sudo ip route add "$subnet" via "$gw" || {
            _rt_err "  ✗ Failed to add route $subnet → $gw"; return 1
        }
    fi

    _rt_init_state
    echo "$subnet via $gw" | sudo tee -a "$_RT_STATE_DIR/added-routes" >/dev/null
    _rt_info "✓ Added route to $subnet via $gw ($desc)"
}

# Add a forward rule only if it doesn't already exist
_rt_add_fwd_rule() {
    local desc="$1"; shift
    local rule_args=("$@")

    if sudo iptables -C FORWARD "${rule_args[@]}" 2>/dev/null; then
        _rt_info "✓ FORWARD rule already present ($desc)"
        return 0
    fi
    sudo iptables -I FORWARD 1 "${rule_args[@]}" || {
        _rt_err "  ✗ Failed to add FORWARD rule ($desc)"; return 1
    }
    _rt_init_state
    echo "${rule_args[*]}" | sudo tee -a "$_RT_STATE_DIR/added-fwd-rules" >/dev/null
    _rt_info "✓ Added FORWARD rule ($desc)"
}

# Enable IPv4 forwarding (needed for inter-bridge cross-host packets)
_rt_enable_forwarding() {
    local cur
    cur=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [ "$cur" = "1" ]; then
        _rt_info "✓ IPv4 forwarding already enabled"
        return 0
    fi
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
    _rt_info "✓ Enabled IPv4 forwarding"
}

# ─────────────────────────────────────────────────────────────
#  Public entrypoints — one per host
# ─────────────────────────────────────────────────────────────

# On the CORE host: no F1-U routes needed (CU-CP-only host).
# Provided as a no-op so deploy-core.sh can call it uniformly.
setup_f1u_routes_core() {
    _rt_info "Core host: no F1-U routes required"
    return 0
}

# On the CO host: needs to reach Edge's f1u_net (for return F1-U to DU_e1)
# and accept GTP-U arriving on its own bridge.
setup_f1u_routes_co() {
    _rt_info "Setting up F1-U cross-machine routing on Centraloffice..."
    _rt_enable_forwarding

    # Reach Edge's f1u_net via Edge host
    _rt_add_route "$EDGE_F1U_SUBNET"  "$EDGE_IP" \
        "Edge f1u_net (DU_e1 reverse F1-U)"

    # Reach Edge's n3_net (in case any cross-machine N3 ever happens)
    _rt_add_route "$EDGE_N3_SUBNET"   "$EDGE_IP" \
        "Edge n3_net"

    # Allow forwarded GTP-U into the local f1u bridge
    _rt_add_fwd_rule "incoming F1-U to br-f1u" \
        -p udp -d 192.168.74.140 --dport 2153 -j ACCEPT
    _rt_add_fwd_rule "outgoing F1-U from br-f1u" \
        -p udp -s 192.168.74.140 --sport 2153 -j ACCEPT

    _rt_info "Centraloffice F1-U routing ready"
}

# On the EDGE host: needs to reach CO's f1u_net (for forward F1-U from DU_e1)
setup_f1u_routes_edge() {
    _rt_info "Setting up F1-U cross-machine routing on Edge..."
    _rt_enable_forwarding

    # Reach CO's f1u_net via CO host
    _rt_add_route "$CO_F1U_SUBNET"   "$CO_IP" \
        "CO f1u_net (CU-UP_co forward F1-U)"

    # Reach CO's n3_net (future-proof for cross-machine N3)
    _rt_add_route "$CO_N3_SUBNET"    "$CO_IP" \
        "CO n3_net"

    # Allow forwarded GTP-U back into our local f1u bridge (DL F1-U)
    _rt_add_fwd_rule "incoming DL F1-U to br-f1u" \
        -p udp -d 192.168.84.151 --dport 2152 -j ACCEPT
    _rt_add_fwd_rule "outgoing UL F1-U from br-f1u" \
        -p udp -s 192.168.84.151 --sport 2152 -j ACCEPT

    _rt_info "Edge F1-U routing ready"
}

# ─────────────────────────────────────────────────────────────
# Cleanup — call from a `teardown-routes.sh` if/when you stop
# ─────────────────────────────────────────────────────────────
teardown_f1u_routes() {
    _rt_info "Cleaning up EWOC routes and FORWARD rules..."

    if [ -f "$_RT_STATE_DIR/added-routes" ]; then
        while read -r line; do
            local subnet=$(echo "$line" | awk '{print $1}')
            local gw=$(echo "$line" | awk '{print $3}')
            sudo ip route del "$subnet" via "$gw" 2>/dev/null \
                && _rt_info "✓ Removed route $subnet via $gw" \
                || _rt_warn "  (already gone) $subnet via $gw"
        done < "$_RT_STATE_DIR/added-routes"
        sudo rm -f "$_RT_STATE_DIR/added-routes"
    fi

    if [ -f "$_RT_STATE_DIR/added-fwd-rules" ]; then
        while read -r line; do
            sudo iptables -D FORWARD $line 2>/dev/null \
                && _rt_info "✓ Removed FORWARD rule: $line" \
                || _rt_warn "  (already gone) $line"
        done < "$_RT_STATE_DIR/added-fwd-rules"
        sudo rm -f "$_RT_STATE_DIR/added-fwd-rules"
    fi

    _rt_info "Done."
}

# ─────────────────────────────────────────────────────────────
# Verification — pings the peer bridge gateway and runs a UDP probe
# ─────────────────────────────────────────────────────────────
verify_f1u_routes() {
    local role="$1"   # core | co | edge
    _rt_info "Verifying F1-U cross-machine reachability..."

    case "$role" in
        co)
            if ping -c 2 -W 2 192.168.84.151 &>/dev/null; then
                _rt_info "✓ CO can reach Edge DU_e1 f1u IP (192.168.84.151)"
            else
                _rt_warn "✗ CO cannot reach 192.168.84.151 — Edge may not be deployed yet"
            fi
            ;;
        edge)
            if ping -c 2 -W 2 192.168.74.140 &>/dev/null; then
                _rt_info "✓ Edge can reach CO CU-UP_co f1u IP (192.168.74.140)"
            else
                _rt_warn "✗ Edge cannot reach 192.168.74.140 — CO may not be deployed yet"
            fi
            ;;
        core)
            _rt_info "Core role: no F1-U verification needed"
            ;;
    esac
}
