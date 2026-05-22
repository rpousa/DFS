#!/bin/bash

# deploy-centraloffice.sh - Deploy CU-UP_co + UPF_co + DU_co + FlexRIC
# Deploy on PC: 192.168.0.193
#
# ARCHITECTURE (NEW 3-MACHINE):
#   Core (192.168.0.200):          5G Core + CU-CP + UPF_core + ext_dn_core
#   Centraloffice (192.168.0.193): CU-UP_co + UPF_co + ext_dn_co + DU_co + FlexRIC  ← THIS MACHINE
#   Edge (192.168.0.243):          CU-UP_e + UPF_e + ext_dn_e + DU_e1 + DU_e2 + UE_1

set -e

CORE_IP="192.168.0.200"
CO_IP="192.168.0.193"
EDGE_IP="192.168.0.243"
COMPOSE_FILE="docker-compose-centraloffice.yml"

echo "================================================"
echo "Centraloffice: CU-UP + UPF + DU + FlexRIC"
echo "================================================"
echo "Core machine:           $CORE_IP"
echo "Centraloffice (this):   $CO_IP"
echo "Edge machine:           $EDGE_IP"
echo ""
echo "Components on this machine:"
echo "  - CU-UP_co   (gNB_CU_UP_ID=0xe01, E1→Core, F1-U from DU_co + DU_e1)"
echo "  - UPF_co     (Slice SST=1/SD=2)"
echo "  - ext_dn_co  (internet test)"
echo "  - DU_co      (CellID=11111111, PCI=0, F1-C→Core, F1-U→CU-UP_co local)"
#echo "  - FlexRIC    (Near-RT RIC, SCTP 36421/36422)"
echo ""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_stage() { echo -e "${BLUE}[STAGE]${NC} $1"; }
print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

wait_for_service() {
    local service=$1 max_wait=${2:-60} count=0
    print_info "Waiting for $service..."
    while [ $count -lt $max_wait ]; do
        if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
            [ "$(docker inspect --format='{{.State.Status}}' "$service" 2>/dev/null)" = "running" ] && \
                print_info "✓ $service is running" && return 0
        fi
        sleep 1; count=$((count + 1))
    done
    print_error "$service failed to start within ${max_wait}s"; return 1
}

# ==========================================
# Pre-flight checks
# ==========================================
print_stage "Running pre-flight checks..."

docker ps &> /dev/null || { print_error "Docker is not running"; exit 1; }

for f in "$COMPOSE_FILE" "fix-sctp-routing.sh"; do
    [ ! -f "$f" ] && print_error "Required file $f not found" && exit 1
done
[ ! -d "configs" ] && print_error "configs directory not found" && exit 1

#chmod +x fix-sctp-routing.sh
source ./fix-sctp-routing.sh
source ./f1u-routes.sh

# Verify IP
CURRENT_IP=""
for ip in $(hostname -I); do
    [ "$ip" == "$CO_IP" ] && CURRENT_IP="$ip" && break
done
if [ "$CURRENT_IP" != "$CO_IP" ]; then
    print_warn "Expected IP $CO_IP not found"
    read -p "Continue anyway? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# SCTP module
lsmod | grep -q "^sctp" || sudo modprobe sctp
print_info "✓ SCTP kernel module loaded"

# CRITICAL: Check connectivity to Core machine (hosts CU-CP, 5G Core)
if ! ping -c 3 -W 2 "$CORE_IP" &> /dev/null; then
    print_error "✗ Cannot reach Core machine ($CORE_IP)"
    exit 1
fi
print_info "✓ Can reach Core machine ($CORE_IP)"

# Check Core is up (NRF reachable on TCP)
if timeout 3 bash -c "echo > /dev/tcp/$CORE_IP/9090" 2>/dev/null; then
    print_info "✓ Core NRF reachable at $CORE_IP:9090"
else
    print_error "✗ Core NRF not reachable. Run ./deploy-core.sh on $CORE_IP first"
    exit 1
fi

# Check SCTP connectivity to Core's CU-CP (F1-C + E1)
if command -v ncat &> /dev/null; then
    for port in 38472 38462; do
        if timeout 3 ncat --sctp "$CORE_IP" "$port" < /dev/null 2>/dev/null; then
            print_info "✓ SCTP reachable: ${CORE_IP}:${port}"
        else
            print_warn "✗ SCTP NOT reachable: ${CORE_IP}:${port} — ensure Core ran fix-sctp-routing.sh"
        fi
    done
else
    print_warn "ncat not installed — skipping SCTP pre-flight"
fi

# Optional edge check
ping -c 1 -W 2 "$EDGE_IP" &> /dev/null && print_info "✓ Can reach Edge ($EDGE_IP)" || \
    print_warn "✗ Cannot reach Edge ($EDGE_IP) — DU_e1 F1-U will fail"

# Existing containers
if docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .; then
    print_warn "Containers already running"
    read -p "Stop and restart? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && docker compose -f "$COMPOSE_FILE" down
fi

print_info "Pre-flight checks passed!"
echo ""


# ==========================================
# Deployment Stages
# ==========================================

print_stage "Creating Docker networks..."
docker compose -f "$COMPOSE_FILE" up --no-start
echo ""

# # Stage 1/5: FlexRIC first (so CU-UP and DU can register E2 on startup)
# print_stage "Stage 1/5: Starting FlexRIC (Near-RT RIC)..."
# docker compose -f "$COMPOSE_FILE" up -d flexric
# wait_for_service "flexric" 30
# print_info "Waiting for FlexRIC to bind E2AP sockets..."
# sleep 10
# docker exec flexric ss -Slnp 2>/dev/null | grep -iE "36421|36422" || print_warn "FlexRIC E2AP sockets not yet bound"
# echo ""

# Stage 1/5: CU-UP_co (initiates E1 outbound to Core)
print_stage "Stage 1/5: Starting CU-UP_co..."
docker compose -f "$COMPOSE_FILE" up -d cuup_co
wait_for_service "cuup_co" 30
print_info "Waiting for CU-UP_co to set up E1 to Core CU-CP..."
sleep 15
docker exec cuup_co ss -Slnp 2>/dev/null | grep -iE "sctp|2153" || print_warn "CU-UP_co not yet listening"
echo ""

# Stage 2/5: UPF_co + ext_dn_co
print_stage "Stage 2/5: Starting UPF_co and ext_dn_co..."
docker compose -f "$COMPOSE_FILE" up -d upf_co ext_dn_co
wait_for_service "upf_co" 30
wait_for_service "ext_dn_co" 30
sleep 5
echo ""

# Stage 3/5: DU_co (F1-C to Core, F1-U to local CU-UP_co)
print_stage "Stage 3/5: Starting DU_co..."
docker compose -f "$COMPOSE_FILE" up -d du_co
wait_for_service "du_co" 30
print_info "Waiting for DU_co to initialize SCTP F1-C + RFSimulator server..."
sleep 20

if docker logs du_co 2>&1 | grep -q "Running as server"; then
    print_info "✓ DU_co RFSimulator server listening"
else
    print_warn "⚠ DU_co RFSimulator status unclear — check logs"
fi
echo ""

# Stage 4/5: Dynamic SCTP Routing Fix
print_stage "Stage 4/5: Applying dynamic SCTP and F1u routing fix..."
echo ""
fix_sctp_routing "$COMPOSE_FILE" "$CO_IP"
echo ""
setup_f1u_routes_co
echo ""

verify_f1u_routes co
echo ""

# Stage 5/5: Observability agents
if [ -f docker-compose-observability.yml ]; then
    print_stage "Stage 5/5: Starting observability agents..."
    docker compose -f docker-compose-observability.yml up -d
    sleep 3
    print_info "  ✓ node_exporter on ${CO_IP}:9100  (scraped by Core Prometheus)"
    print_info "  ✓ cadvisor      on ${CO_IP}:8081  (scraped by Core Prometheus)"
    echo ""
fi

# ==========================================
# Final Verification
# ==========================================
print_stage "Final verification..."
echo ""
docker compose -f "$COMPOSE_FILE" ps
echo ""

verify_sctp_routing "$COMPOSE_FILE" "$CO_IP"

print_info "================================================"
print_info "Centraloffice Deployment Complete!"
print_info "================================================"
echo ""
print_info "SCTP/UDP ports exposed on $CO_IP:"
print_info "  DU_co F1-C:        ${CO_IP}:500/sctp"
print_info "  CU-UP_co F1-U:     ${CO_IP}:2153/udp (DU_co local + DU_e1 cross-machine)"
print_info "  CU-UP_co → UPF:    ${CO_IP}:2155→2152/udp (N3)"
# REMOVED: FlexRIC line — FlexRIC lives on Core, not CO
echo ""
print_info "Outbound connections this machine initiates:"
print_info "  CU-UP_co → Core CU-CP:    E1     → ${CORE_IP}:38462/sctp"
print_info "  DU_co    → Core CU-CP:    F1-C   → ${CORE_IP}:38472/sctp"
print_info "  CU-UP_co → Core FlexRIC:  E2AP   → ${CORE_IP}:36421/sctp  (cross-machine)"
print_info "  DU_co    → Core FlexRIC:  E2AP   → ${CORE_IP}:36421/sctp  (cross-machine)"
print_info "  Metrics  → Core Grafana:  http://${CORE_IP}:3000"
echo ""
print_info "Next: On Edge ($EDGE_IP), run ./deploy-edge.sh"
echo ""
print_info "Logs:  docker compose -f $COMPOSE_FILE logs -f"
print_info "Stop:  docker compose -f $COMPOSE_FILE down"
echo ""

read -p "Show live logs? (y/N): " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] && docker compose -f "$COMPOSE_FILE" logs -f
