#!/bin/bash
# discover-udp-endpoints.sh — emit this host's contribution to topology.yaml
#
# Scans running containers for /udp ports published to a non-loopback host IP,
# resolves the container's IP on the bridge that backs that publish, and prints YAML.
#
# Usage:  ./discover-udp-endpoints.sh [role]
#   role defaults to hostname -s, or pass {core|centraloffice|edge} explicitly.

set -euo pipefail

role="${1:-}"
if [ -z "$role" ]; then
    case "$(hostname -s)" in
        *core*|cgcc)              role=core ;;
        *centraloffice*|*co*|gcentraloffice) role=centraloffice ;;
        *edge*)                   role=edge ;;
        *)                        role="$(hostname -s)" ;;
    esac
fi

# Pick the LAN IP — first global-scope IPv4 that is NOT a Docker subnet (192.168.6x/7x/8x)
host_lan_ip=$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 \
    | grep -vE '^(192\.168\.(6[0-9]|7[0-9]|8[0-9])\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|169\.254\.|127\.)' \
    | head -1)
host_lan_ip="${host_lan_ip:-UNKNOWN}"

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# ---------- helper: list UDP mappings of one container as TSV ----------
# Output cols: container_port  host_ip  host_port
_udp_mappings() {
    local c=$1
    docker port "$c" 2>/dev/null | gawk '
        /\/udp ->/ {
            split($0, a, " -> ")
            cport = gensub("/udp.*", "", 1, a[1])
            n = split(a[2], b, ":")
            hip   = (n == 2) ? b[1] : ""
            hport = (n == 2) ? b[2] : b[1]
            printf "%s\t%s\t%s\n", cport, hip, hport
        }'
}

# ---------- helper: pick the container IP on the bridge that backs this publish ----------
# We pick the IP from the network whose subnet is closest in numbering to other UDP peers,
# but as a robust heuristic: prefer 'core_net' or 'f1u_net' over 'ext_net' / 'ran_net'
# when both exist. Override with NETWORK_PRIORITY env var if needed.
_container_ip_for_publish() {
    local c=$1 cport=$2

    # 1) Try ss inside the container — find the LOCAL address column robustly.
    #    We don't trust column numbers; instead, parse "ip:port" tokens and
    #    pick the one that actually ends in :<cport>.
    local listen
    listen=$(docker exec "$c" sh -c "ss -ulnH 2>/dev/null || ss -uln 2>/dev/null" 2>/dev/null \
        | awk -v cp=":$cport" '
            {
                for (i = 1; i <= NF; i++) {
                    tok = $i
                    # Match either "1.2.3.4:PORT" or "*:PORT" or "[::]:PORT"
                    if (tok ~ ("(^|[^*])"cp"$")) {
                        sub(":[0-9]+$", "", tok)
                        print tok
                        exit
                    }
                }
            }' | head -1)

    # Normalize wildcards to empty so we fall through
    case "$listen" in
        "0.0.0.0"|"*"|"::"|"[::]"|"") listen="" ;;
    esac

    if [ -n "$listen" ]; then
        echo "$listen"; return
    fi

    # 2) Listening on wildcard — pick by preferred network
    local pref="${NETWORK_PRIORITY:-core_net f1u_net f1c_net ext_net ran_net sgi_net}"
    for net in $pref; do
        # Match the network whose name ENDS with our preferred suffix
        # (Compose prefixes networks with the project name, e.g. "distributed_deployment_core_net")
        local found_net
        found_net=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$c" 2>/dev/null \
                    | grep -E "(^|_)${net}\$" | head -1)
        [ -z "$found_net" ] && continue
        local ip
        ip=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$found_net\"}}{{.IPAddress}}{{end}}" "$c" 2>/dev/null || true)
        [ -n "$ip" ] && { echo "$ip"; return; }
    done

    # 3) Fallback: any first non-empty IP
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' "$c" \
        | grep -v '^$' | head -1
}

# ---------- emit YAML ----------
echo "  ${role}:"
echo "    lan_ip: ${host_lan_ip}"
echo "    udp_endpoints:"

emitted=0
while read -r c; do
    [ -z "$c" ] && continue
    while IFS=$'\t' read -r cport hip hport; do
        [ -z "$cport" ] && continue
        [ -z "$hport" ] && continue
        # Skip unbound (ephemeral) publishes unless explicitly requested
        if [ -z "$hip" ] || [ "$hip" = "0.0.0.0" ]; then
            : # keep; it's still reachable on this host's LAN IP via the ephemeral port
        fi
        cip=$(_container_ip_for_publish "$c" "$cport")
        [ -z "$cip" ] && continue
        # Pretty-aligned YAML row
        printf "      - { name: %-22s container_ip: %-16s container_port: %-6s host_port: %-6s }\n" \
            "${c}_${cport}," "${cip}," "${cport}," "${hport}"
        emitted=$((emitted+1))
    done < <(_udp_mappings "$c")
done < <(docker ps --format '{{.Names}}')

if [ "$emitted" -eq 0 ]; then
    echo "      # (no UDP endpoints found on this host)" >&2
fi
echo "# discovered $emitted UDP endpoint(s) for role=$role" >&2
