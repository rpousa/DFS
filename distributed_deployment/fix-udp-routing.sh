#!/bin/bash
# fix-udp-routing.sh — Cross-host UDP DNAT for OAI distributed deployment
#
# Solves: container A on host X sends UDP to container B's bridge IP on host Y,
# which is unrouteable across the LAN. We install PREROUTING DNAT on host X to
# rewrite the dest to host Y's LAN IP:published_port + POSTROUTING MASQUERADE.
#
# Usage:   ./fix-udp-routing.sh <topology.yaml> [my_role]
#   my_role ∈ { core | centraloffice | edge }
#
# Can also be sourced:
#   source fix-udp-routing.sh
#   fix_udp_routing topology.yaml core

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then set -euo pipefail; fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
_u_stage()  { echo -e "${BLUE}[UDP-FIX]${NC} $1"; }
_u_info()   { echo -e "${GREEN}[UDP-FIX]${NC} $1"; }
_u_warn()   { echo -e "${YELLOW}[UDP-FIX]${NC} $1"; }
_u_err()    { echo -e "${RED}[UDP-FIX]${NC} $1"; }
_u_detail() { echo -e "${CYAN}[UDP-FIX]${NC}   $1"; }

# ---------- minimal YAML parser (depends on yq if available, else awk fallback) ----------
_parse_topo() {
    local topo=$1
    if command -v yq &>/dev/null; then
        # Emit lines: role lan_ip name container_ip container_port host_port
        yq -r '
          .hosts | to_entries[] as $h
          | $h.value.udp_endpoints[]?
          | [$h.key, $h.value.lan_ip, .name, .container_ip, .container_port, .host_port] | @tsv
        ' "$topo"
    else
        # Fallback awk parser (assumes flat structure exactly like the example)
        awk '
          /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ && match($0,/^  ([a-zA-Z_][a-zA-Z0-9_]*):/,m) { role=m[1]; next }
          /lan_ip:/ { gsub(/[ ,]/,""); split($0,a,":"); lan=a[2] }
          /- \{/ {
              line=$0
              # crude key=value extraction
              for (k in kv) delete kv[k]
              n=split(line, parts, /[,{}]/)
              for (i=1;i<=n;i++) {
                  if (match(parts[i], /([a-zA-Z_]+):[[:space:]]*([^ ,}]+)/, kv2)) kv[kv2[1]]=kv2[2]
              }
              if (kv["name"] != "" && kv["container_ip"] != "") {
                  printf "%s\t%s\t%s\t%s\t%s\t%s\n", role, lan, kv["name"], kv["container_ip"], kv["container_port"], kv["host_port"]
              }
          }
        ' "$topo"
    fi
}

# ---------- nft rule helpers ----------
_nft_del_matching() {
    local table=$1 chain=$2 pat=$3 removed=0
    while :; do
        local H
        H=$(sudo nft -a list chain "$table" "$chain" 2>/dev/null | grep -E "$pat" | head -1 | grep -oP 'handle \K\d+' || true)
        [ -z "$H" ] && break
        sudo nft delete rule "$table" "$chain" handle "$H" 2>/dev/null || break
        removed=$((removed+1))
    done
    [ $removed -gt 0 ] && _u_detail "removed $removed rule(s) matching: $pat"
}

_ensure_chain_exists() {
    # nat PREROUTING / POSTROUTING usually exist already in Docker hosts
    sudo nft list table ip nat &>/dev/null || sudo nft add table ip nat
}

# ---------- main ----------
fix_udp_routing() {
    local topo="${1:?need topology.yaml}" my_role="${2:-}"
    [ ! -f "$topo" ] && _u_err "topology file not found: $topo" && return 1

    # Autodetect role from hostname if not given
    if [ -z "$my_role" ]; then
        case "$(hostname -s)" in
            *core*)          my_role=core ;;
            *centraloffice*|*co*) my_role=centraloffice ;;
            *edge*)          my_role=edge ;;
            *) _u_err "cannot autodetect role; pass as 2nd arg"; return 1 ;;
        esac
    fi
    _u_stage "Role: $my_role | topology: $topo"

    _ensure_chain_exists

    # ---------- sysctl prerequisites ----------
    _u_stage "Step 0: kernel knobs"
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sudo sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null   # loose RPF (we masquerade)
    sudo sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
    sudo sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=600 >/dev/null 2>&1 || true
    _u_info "✓ ip_forward=1, rp_filter=loose"

    # ---------- collect rows ----------
    local rows
    rows=$(_parse_topo "$topo")
    [ -z "$rows" ] && _u_err "no endpoints parsed from $topo" && return 1

    # Build list of OUR docker bridges (so DNAT only catches container-originated traffic)
    local local_bridges
    local_bridges=$(ip -o link show type bridge | awk -F': ' '/br-/{print $2}' | tr '\n' ' ')
    _u_info "Local docker bridges: ${local_bridges:-<none>}"

    # ---------- clean previously-installed UDP cross-host rules ----------
    _u_stage "Step 1: removing stale cross-host UDP DNAT rules (marker: UDPFIX)"
    _nft_del_matching "ip nat" "PREROUTING"  "comment \"UDPFIX\""
    _nft_del_matching "ip nat" "POSTROUTING" "comment \"UDPFIX\""

    # ---------- install rules for REMOTE endpoints ----------
    _u_stage "Step 2: installing DNAT rules for remote endpoints"
    local installed=0
    while IFS=$'\t' read -r owner lan_ip name cip cport hport; do
        [ -z "$owner" ] && continue
        if [ "$owner" = "$my_role" ]; then
            _u_detail "skip local endpoint $name ($cip:$cport)"
            continue
        fi
        _u_info "  → $name : DNAT $cip:$cport → $lan_ip:$hport (owner=$owner)"

        # PREROUTING DNAT for packets coming FROM local docker bridges
        for br in $local_bridges; do
            sudo nft add rule ip nat PREROUTING \
                iifname "\"$br\"" ip daddr "$cip" udp dport "$cport" \
                counter dnat to "${lan_ip}:${hport}" \
                comment "\"UDPFIX:${name}:${br}\""
        done

        # Also catch packets originated by the host itself (rare but cheap insurance)
        sudo nft add rule ip nat OUTPUT \
            ip daddr "$cip" udp dport "$cport" \
            counter dnat to "${lan_ip}:${hport}" \
            comment "\"UDPFIX:${name}:host\"" 2>/dev/null || true

        # MASQUERADE on POSTROUTING so reply comes back to us (not to the bridge IP)
        sudo nft add rule ip nat POSTROUTING \
            ip daddr "$lan_ip" udp dport "$hport" \
            counter masquerade \
            comment "\"UDPFIX:${name}\""

        installed=$((installed+1))
    done <<< "$rows"

    _u_info "✓ installed $installed remote DNAT rule(s)"

    # ---------- verification ----------
    _u_stage "Step 3: verification"
    _u_info "UDPFIX rules in nat PREROUTING:"
    sudo nft -a list chain ip nat PREROUTING 2>/dev/null | grep UDPFIX | sed 's/^/    /' || true
    _u_info "UDPFIX rules in nat POSTROUTING:"
    sudo nft -a list chain ip nat POSTROUTING 2>/dev/null | grep UDPFIX | sed 's/^/    /' || true

    # Active reachability probe — for each remote endpoint, send a 0-byte UDP packet
    # from a local docker bridge IP and watch tcpdump on the destination port (best-effort).
    if command -v nc &>/dev/null; then
        _u_info "probing remote endpoints (UDP nc, non-authoritative):"
        while IFS=$'\t' read -r owner lan_ip name cip cport hport; do
            [ "$owner" = "$my_role" ] && continue
            if timeout 1 bash -c "echo > /dev/udp/${cip}/${cport}" 2>/dev/null; then
                _u_detail "  → $cip:$cport (=$lan_ip:$hport) — no ICMP unreachable returned"
            else
                _u_detail "  → $cip:$cport — kernel rejected (check rules)"
            fi
        done <<< "$rows"
    fi

    _u_stage "UDP routing fix complete for role=$my_role"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fix_udp_routing "${1:?topology.yaml}" "${2:-}"
fi
