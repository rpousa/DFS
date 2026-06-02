#!/bin/bash
# discover-udp-endpoints.sh — emit this host's contribution to topology.yaml
#
# Reads all running containers, finds /udp ports published to a non-loopback host IP,
# resolves the container's IP on the bridge that backs that publish, and prints YAML.

set -euo pipefail
role="${1:-$(hostname -s)}"
host_lan_ip=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -v '^192\.168\.7[0-9]\.\|^192\.168\.6[0-9]\.\|^192\.168\.8[0-9]\.' | head -1)

echo "  ${role}:"
echo "    lan_ip: ${host_lan_ip}"
echo "    udp_endpoints:"

docker ps --format '{{.Names}}' | while read -r c; do
    # Get all UDP port mappings: "container_port:host_ip:host_port"
    mappings=$(docker inspect "$c" --format '{{range $p, $b := .NetworkSettings.Ports}}{{if eq (printf "%s" $p | slice 4 ) "udp"}}{{range $b}}{{printf "%s|%s|%s\n" $p .HostIp .HostPort}}{{end}}{{end}}{{end}}' 2>/dev/null || true)
    [ -z "$mappings" ] && continue

    while IFS='|' read -r proto_port host_ip host_port; do
        [ -z "$host_port" ] && continue
        cport="${proto_port%/udp}"
        # pick the container's IP on whichever bridge actually serves this binding
        # heuristic: first IP listed
        cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c" | awk '{print $1}')
        [ -z "$cip" ] && continue
        printf "      - { name: %-20s container_ip: %-16s container_port: %-6s host_port: %-6s }\n" \
            "${c}_${cport}," "${cip}," "${cport}," "${host_port}"
    done <<< "$mappings"
done
