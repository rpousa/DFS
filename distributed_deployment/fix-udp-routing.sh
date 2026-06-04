#!/bin/bash
# fix-udp-routing.sh — Cross-host UDP DNAT for OAI 3-machine deployment.
# Self-contained: reads only topology.yaml and local nft state. No SSH, no
# remote docker calls, no cross-host queries.
#
# Source-then-call (matches fix-sctp-routing.sh pattern):
#   source ./fix-udp-routing.sh
#   fix_udp_routing topology.yaml core
#   verify_udp_routing topology.yaml core
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then set -euo pipefail; fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
_u_stage()  { echo -e "${BLUE}[UDP-FIX]${NC} $1"; }
_u_info()   { echo -e "${GREEN}[UDP-FIX]${NC} $1"; }
_u_warn()   { echo -e "${YELLOW}[UDP-FIX]${NC} $1"; }
_u_err()    { echo -e "${RED}[UDP-FIX]${NC} $1"; }
_u_detail() { echo -e "${CYAN}[UDP-FIX]${NC}   $1"; }

# Parse topology.yaml -> TSV: role lan_ip name container_ip container_port host_port
_parse_topo() {
    awk '
        /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ {
            indent = match($0, /[^ ]/) - 1
            if (indent == 2) { role = $1; sub(/:.*/, "", role); lan = "" }
            next
        }
        /lan_ip:/ { lan = $2; gsub(/[",]/, "", lan); next }
        /^[[:space:]]*-[[:space:]]*\{/ {
            line = $0
            for (k in kv) delete kv[k]
            while (match(line, /[a-zA-Z_]+:[[:space:]]*[^,}]+/)) {
                m = substr(line, RSTART, RLENGTH)
                k_end = index(m, ":")
                kk = substr(m, 1, k_end-1)
                vv = substr(m, k_end+1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", vv); gsub(/[",]/, "", vv)
                kv[kk] = vv
                line = substr(line, RSTART + RLENGTH)
            }
            if (kv["name"] && kv["container_ip"] && kv["container_port"] && kv["host_port"])
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", role, lan, kv["name"], kv["container_ip"], kv["container_port"], kv["host_port"]
        }
    ' "$1"
}

_nft_del_matching() {
    local table=$1 chain=$2 pat=$3 removed=0
    while :; do
        local H
        H=$(sudo nft -a list chain "$table" "$chain" 2>/dev/null | grep -E "$pat" | head -1 | grep -oP 'handle \K\d+' || true)
        [ -z "$H" ] && break
        sudo nft delete rule "$table" "$chain" handle "$H" 2>/dev/null || break
        removed=$((removed+1))
    done
    if [ "$removed" -gt 0 ]; then
        _u_detail "removed $removed rule(s) matching: $pat"
    fi
    return 0          # ← critical: ensures function never returns non-zero
}

fix_udp_routing() {
    local topo="${1:?need topology.yaml}" my_role="${2:?need role}"
    [ ! -f "$topo" ] && _u_err "topology not found: $topo" && return 1

    # ── Preliminary check: detect & repair Windows CRLF line endings ──────────
    # topology.yaml is often edited on Windows; stray \r in the last TSV field
    # ($hport) breaks `nft add rule ... : "$hport"` with "unexpected junk".
    if grep -q $'\r' "$topo"; then
        _u_warn "CRLF line endings detected in $topo (edited on Windows?)"
        if command -v dos2unix >/dev/null 2>&1; then
            _u_info "  → running: dos2unix $topo"
            if sudo dos2unix "$topo" >/dev/null 2>&1 || dos2unix "$topo" >/dev/null 2>&1; then
                _u_info "  ✓ converted $topo to Unix line endings"
            else
                _u_err "  ✗ dos2unix failed on $topo"; return 1
            fi
        else
            _u_warn "  dos2unix not installed — falling back to: sed -i 's/\\r\$//'"
            if sed -i 's/\r$//' "$topo"; then
                _u_info "  ✓ stripped CR from $topo via sed"
            else
                _u_err "  ✗ sed fallback failed; install dos2unix: sudo apt install -y dos2unix"
                return 1
            fi
        fi
        # Re-verify
        if grep -q $'\r' "$topo"; then
            _u_err "CRLF still present in $topo after conversion — aborting"
            return 1
        fi
    else
        _u_detail "✓ $topo has Unix line endings"
    fi

    # Belt-and-braces: also strip CRs from the script itself if it was edited on Windows
    if grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then
        _u_warn "CRLF detected in ${BASH_SOURCE[0]} itself — please run:"
        _u_warn "    dos2unix ${BASH_SOURCE[0]}"
        _u_warn "    then re-source this script."
    fi
    # ──────────────────────────────────────────────────────────────────────────

    echo ""
    _u_stage "═══════════════════════════════════════════════════"
    _u_stage "Cross-host UDP DNAT — role=$my_role  topo=$topo"
    _u_stage "═══════════════════════════════════════════════════"

    # Step 0: kernel knobs (idempotent, safe to set every run)
    sudo sysctl -qw net.ipv4.ip_forward=1
    sudo sysctl -qw net.ipv4.conf.all.rp_filter=2
    sudo sysctl -qw net.ipv4.conf.default.rp_filter=2
    _u_info "✓ ip_forward=1, rp_filter=loose"

    # Local docker bridges (so PREROUTING only catches container-originated traffic)
    local bridges
    bridges=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '/br-/{print $2}' | tr '\n' ' ')
    _u_info "Local bridges: ${bridges:-<none>}"

    # Step 1: clear stale rules from previous runs
    _u_stage "Step 1: removing stale UDPFIX rules"
    for chain in PREROUTING OUTPUT POSTROUTING; do
        _nft_del_matching "ip nat" "$chain" 'comment "UDPFIX'
    done

    # Step 2: parse + install
    _u_stage "Step 2: installing rules for endpoints owned by other roles"
    local rows; rows=$(_parse_topo "$topo")
    rows=${rows//$'\r'/}
    [ -z "$rows" ] && _u_err "no endpoints parsed from $topo" && return 1

    local installed=0 skipped_local=0
    while IFS=$'\t' read -r owner lan name cip cport hport; do
        hport=${hport%$'\r'}    
        [ -z "$owner" ] && continue
        if [ "$owner" = "$my_role" ]; then
            skipped_local=$((skipped_local+1)); continue
        fi
        _u_info "  → $name : $cip:$cport ⇒ $lan:$hport (owner=$owner)"

        # PREROUTING (from local bridges)
        for br in $bridges; do
            if ! sudo nft add rule ip nat PREROUTING \
                    iifname "$br" ip daddr "$cip" udp dport "$cport" \
                    counter dnat to  "$lan" : "$hport" \ 
                    comment "UDPFIX_"${name}"_"${br}"; 
                _u_warn "    failed: PREROUTING iifname $br -> $cip:$cport $hport $lan "
            fi
        done
        # OUTPUT (host-originated)
        if ! sudo nft add rule ip nat OUTPUT \
                ip daddr "$cip" udp dport "$cport" \
                counter dnat to  "$lan" : "$hport" \
                comment "UDPFIX_"${name}"_host"; then
            _u_warn "    failed: OUTPUT $cip:$cport -> $lan:$hport"
        fi
        # POSTROUTING masquerade
        if ! sudo nft add rule ip nat POSTROUTING \
                ip daddr "$lan" udp dport "$hport" \
                counter masquerade \ 
                comment "UDPFIX_${name}; then
            _u_warn "    failed: POSTROUTING masq for $lan:$hport"
        fi
        installed=$((installed+1))
    done <<< "$rows"

    _u_info "✓ installed $installed remote rule-set(s); skipped $skipped_local local"
    echo ""
    return 0
}

verify_udp_routing() {
    local topo="${1:?topology.yaml}" my_role="${2:?role}"

    # Strip CRs in-memory in case topo wasn't converted yet
    if grep -q $'\r' "$topo" 2>/dev/null; then
        _u_warn "CRLF detected in $topo — run: dos2unix $topo"
    fi

    _u_stage "Verifying UDPFIX rules (role=$my_role)"
    local rows; rows=$(_parse_topo "$topo")
    while IFS=$'\t' read -r owner lan name cip cport hport; do
        [ "$owner" = "$my_role" ] && continue
        local hits
        hits=$(sudo nft list chain ip nat PREROUTING 2>/dev/null | grep -c "UDPFIX_${name}" || true)
        if [ "${hits:-0}" -gt 0 ]; then
            _u_detail "✓ $name : $hits PREROUTING rule(s)"
        else
            _u_warn "✗ $name : MISSING"
        fi
    done <<< "$rows"
    echo ""
    return 0  
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fix_udp_routing "${1:?topology.yaml}" "${2:?role}"
fi
