#!/bin/bash

# deploy-core.sh - Deploy 5G Core + CU-CP + UPF_core on Core Machine
# Deploy on PC: 192.168.0.200

set -e

CORE_IP="192.168.0.200"
CO_IP="192.168.0.193"
EDGE_IP="192.168.0.243"
COMPOSE_FILE="docker-compose-core.yml"

echo "================================================"
echo "Core Machine: 5G Core + CU-CP + UPF Deployment"
echo "================================================"
echo "Core Machine (This PC): $CORE_IP"
echo "Centraloffice (PC 2):   $CO_IP"
echo "Edge (PC 3):            $EDGE_IP"
echo ""
echo "Components on this machine:"
echo "  - 5G Core (MySQL, NRF, AMF, SMF, UDM, UDR, AUSF, PCF, NSSF)"
echo "  - CU-CP (Control Plane — F1-C, E1, NGAP)"
echo "  - UPF_core (Central/Anchor UPF — Slice SST=1/SD=1)"
echo "  - ext_dn_core"
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

wait_for_service() {
    local service=$1
    local max_wait=${2:-60}
    local count=0
    print_info "Waiting for $service to be ready..."
    while [ $count -lt $max_wait ]; do
        if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
            local status
            status=$(docker inspect --format='{{.State.Status}}' "$service" 2>/dev/null || echo "not found")
            if [ "$status" = "running" ]; then
                print_info "$service is running"
                return 0
            fi
        fi
        sleep 1
        count=$((count + 1))
    done
    print_error "$service failed to start within ${max_wait} seconds"
    return 1
}

wait_for_healthy() {
    local service=$1
    local max_wait=${2:-120}
    local count=0
    print_info "Waiting for $service to become healthy..."
    while [ $count -lt $max_wait ]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$service" 2>/dev/null || echo "none")
        if [ "$health" = "healthy" ]; then
            print_info "✓ $service is healthy"
            return 0
        elif [ "$health" = "none" ]; then
            local status
            status=$(docker inspect --format='{{.State.Status}}' "$service" 2>/dev/null || echo "not found")
            if [ "$status" = "running" ]; then
                print_info "✓ $service is running (no healthcheck)"
                return 0
            fi
        fi
        sleep 2
        count=$((count + 2))
    done
    print_error "$service failed to become healthy within ${max_wait} seconds"
    return 1
}

# ==========================================
# Pre-deployment checks
# ==========================================
print_stage "Running pre-flight checks..."

if ! docker ps &> /dev/null; then
    print_error "Docker is not running"
    exit 1
fi

# Check IP matches
CURRENT_IP=""
for ip in $(hostname -I); do
    [ "$ip" == "$CORE_IP" ] && CURRENT_IP="$ip" && break
done
if [ "$CURRENT_IP" != "$CORE_IP" ]; then
    print_warn "Expected IP $CORE_IP not found on this host"
    read -p "Continue anyway? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Required files
for f in "$COMPOSE_FILE" "fix-sctp-routing.sh"; do
    [ ! -f "$f" ] && print_error "Required file $f not found" && exit 1
done
[ ! -d "configs" ] && print_error "configs directory not found" && exit 1

# Make fix-sctp-routing.sh executable and source it
#chmod +x fix-sctp-routing.sh
source ./fix-sctp-routing.sh
source ./f1u-routes.sh

# SCTP module
if ! lsmod | grep -q "^sctp"; then
    sudo modprobe sctp
fi
print_info "✓ SCTP kernel module loaded"

# Optional: verify reachability to other machines
for target_ip in "$CO_IP" "$EDGE_IP"; do
    if ping -c 1 -W 2 "$target_ip" &> /dev/null; then
        print_info "✓ Can reach $target_ip"
    else
        print_warn "✗ Cannot reach $target_ip — cross-machine links may fail"
    fi
done

# Stop existing containers if prompted
if docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .; then
    print_warn "Some containers are already running"
    read -p "Stop and restart? (y/N): " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker compose -f "$COMPOSE_FILE" down
    fi
fi

print_info "Pre-flight checks passed!"
echo ""

# Optional: Core has no F1-U bridge, but call for symmetry/future use


# ==========================================
# Deployment Stages
# ==========================================

print_stage "Creating Docker networks..."
docker compose -f "$COMPOSE_FILE" up --no-start
echo ""

# Stage 1/8: MySQL
print_stage "Stage 1/8: Starting MySQL database..."
docker compose -f "$COMPOSE_FILE" up -d mysql
wait_for_healthy "mysql" 60
echo ""

# Stage 2/8: 5G Core NFs
print_stage "Stage 2/8: Starting 5G Core Network Functions..."
docker compose -f "$COMPOSE_FILE" up -d nrf smf pcf nssf amf udm udr ausf
wait_for_service "nrf" 30
wait_for_service "amf" 30
wait_for_service "smf" 30
print_info "Waiting for core NFs to register with NRF..."
sleep 8
echo ""

# Stage 3/8: UPF_core + ext_dn_core
print_stage "Stage 3/8: Starting UPF_core and ext_dn_core..."
docker compose -f "$COMPOSE_FILE" up -d upf_core ext_dn_core
wait_for_service "upf_core" 30
wait_for_service "ext_dn_core" 30
sleep 5
echo ""

# Stage 4/8: Flexric
print_stage "Stage 4/8: Flexric..."
docker compose -f "$COMPOSE_FILE" up -d flexric
wait_for_service "flexric" 30
print_info "Waiting for FlexRIC to bind E2AP sockets..."
sleep 10
docker exec flexric ss -Slnp 2>/dev/null | grep -iE "36421|36422" || print_warn "FlexRIC E2AP sockets not yet bound"
echo ""

# Stage 5/8: CU-CP
print_stage "Stage 5/8: Starting CU-CP (control plane)..."
docker compose -f "$COMPOSE_FILE" up -d cucp
wait_for_service "cucp" 30
print_info "Waiting for CU-CP to bind SCTP sockets (F1-C:38472, E1:38462, NGAP)..."
sleep 15

print_info "CU-CP SCTP listening sockets:"
docker exec cucp ss -Slnp 2>/dev/null | grep -iE "sctp|38472|38462" || print_warn "  CU-CP SCTP sockets not yet ready"
echo ""

# Stage 6/8: Dynamic SCTP Routing Fix
print_stage "Stage 6/8: Applying dynamic SCTP routing fix..."
echo ""
fix_sctp_routing "$COMPOSE_FILE" "$CORE_IP"
echo ""

print_stage "Stage 6.5/8: Applying cross-host UDP DNAT..."
if [ -f topology.yaml ] && [ -f fix-udp-routing.sh ]; then
    source ./fix-udp-routing.sh
    # Run with set +e to isolate UDP-fix failures from the deploy script
    set +e
    fix_udp_routing topology.yaml core
    udp_rc=$?
    verify_udp_routing topology.yaml core
    set -e
    if [ "$udp_rc" -ne 0 ]; then
        print_warn "fix_udp_routing returned $udp_rc — continuing deploy, please investigate"
    fi
else
    print_warn "topology.yaml or fix-udp-routing.sh missing — skipping UDP fix"
fi
echo ""

# Stage 7/8: Observability stack (Prometheus + Grafana on Core, agents on host)
print_stage "Stage 7/8: Starting observability stack..."

# Local agents (host-net node_exporter + cadvisor)
if [ -f docker-compose-observability.yml ]; then
    docker compose -f docker-compose-observability.yml up -d
    sleep 3
    print_info "  ✓ node_exporter on ${CORE_IP}:9100"
    print_info "  ✓ cadvisor      on ${CORE_IP}:8081"
else
    print_warn "  ✗ docker-compose-observability.yml not found — agent metrics will be missing"
fi

# Prometheus + Grafana from main compose
docker compose -f "$COMPOSE_FILE" up -d prometheus grafana pushgateway
wait_for_service "prometheus" 30
wait_for_service "grafana" 30
wait_for_service "pushgateway" 30
sleep 5

# Probe cross-machine scrape reachability (warning-only)
print_info "Testing scrape reachability to peer hosts..."
for tgt in "${CO_IP}:9100"   "${CO_IP}:8081" \
           "${EDGE_IP}:9100" "${EDGE_IP}:8081"; do
    h="${tgt%:*}"; p="${tgt#*:}"
    if timeout 2 bash -c "</dev/tcp/${h}/${p}" 2>/dev/null; then
        print_info "  ✓ ${tgt} reachable"
    else
        print_warn "  ✗ ${tgt} not reachable yet — deploy that host's observability agents"
    fi
done
echo ""

# Stage 8/8: Final verification
print_stage "Stage 8/8: Final verification..."
echo ""
docker compose -f "$COMPOSE_FILE" ps
echo ""

GRAFANA_BIND_IP="172.31.54.33"


verify_sctp_routing "$COMPOSE_FILE" "$CORE_IP"

print_info "================================================"
print_info "Core Machine Deployment Complete!"
print_info "================================================"
echo ""
print_info "Services reachable on $CORE_IP:"
print_info "  NGAP (AMF):    ${CORE_IP}:38412/sctp"
print_info "  F1-C (CU-CP):  ${CORE_IP}:38472/sctp"
print_info "  E1   (CU-CP):  ${CORE_IP}:38462/sctp"
print_info "  PFCP (SMF):    ${CORE_IP}:8805/udp"
print_info "  GTP-U (UPF):   ${CORE_IP}:2152/udp"
print_info ""
print_info "Observability:"
print_info "  Grafana:     http://${GRAFANA_BIND_IP}:3000   (admin / \$GRAFANA_PASSWORD)"
print_info "  Prometheus:  http://${CORE_IP}:9080"
print_info "  Targets:     http://${CORE_IP}:9080/targets"
echo ""
print_info "Next Steps:"
echo "  1. Deploy Centraloffice (${CO_IP}): ./deploy-centraloffice.sh"
echo "  2. Deploy Edge (${EDGE_IP}):        ./deploy-edge.sh"
echo ""
echo "  Stop with: docker compose -f $COMPOSE_FILE down"
echo ""

read -p "Show live logs? (y/N): " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] && docker compose -f "$COMPOSE_FILE" logs -f
