#!/bin/bash

# deploy-edge.sh - Deploy CU-UP_e + UPF_e + DU_e1 + DU_e2 + UE_1
# Deploy on PC: 192.168.0.243
#
# ARCHITECTURE (NEW 3-MACHINE):
#   Core (192.168.0.200):          5G Core + CU-CP + UPF_core
#   Centraloffice (192.168.0.193): CU-UP_co + UPF_co + DU_co + FlexRIC
#   Edge (192.168.0.243):          CU-UP_e + UPF_e + DU_e1 + DU_e2 + UE_1  ← THIS MACHINE
#
# Edge has TWO DUs:
#   DU_e1: F1-C → Core CU-CP, F1-U → CU-UP_co @ Centraloffice (CROSS-MACHINE)
#   DU_e2: F1-C → Core CU-CP, F1-U → CU-UP_e local
#
# All UEs (4) connect to DU_e1 per requirement

set -e

CORE_IP="192.168.0.200"
CO_IP="192.168.0.193"
EDGE_IP="192.168.0.243"
COMPOSE_FILE="docker-compose-edge.yml"

echo "================================================"
#echo "Edge: CU-UP + UPF + 2×DU + UEs"
echo "Edge: CU-UP + UPF + DU + UEs"
echo "================================================"
echo "Core machine:           $CORE_IP"
echo "Centraloffice machine:  $CO_IP"
echo "Edge (this):            $EDGE_IP"
echo ""
echo "Components on this machine:"
echo "  - CU-UP_e  (gNB_CU_UP_ID=0xe02, E1→Core)"
echo "  - UPF_e    (Slice SST=1/SD=3)"
echo "  - ext_dn_e"
echo "  - DU_e1    (CellID=22222222, PCI=1, F1-C→Core, F1-U→CU-UP_co@CO)"
#echo "  - DU_e2    (CellID=33333333, PCI=2, F1-C→Core, F1-U→CU-UP_e local)"
echo "  - UE_1     (4 UEs → DU_e1 via RFSim)"
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
# UE connection check (4 UEs on DU_e1)
# ==========================================
# Checks if all 4 UEs are connected to DU_e1, 1 container 4 different connections
check_ue_connections() {
    local total_ues=4 connected=0 with_ip=0
    UE_IPS=(); UE_INTERFACES=()
    print_stage "Checking UE connections (all on DU_e1)..."
    echo ""
    for i in {1..4}; do
        local iface="oaitun_ue$i"
        if docker exec ue_1 ip addr show 2>/dev/null | grep -q "$iface"; then
            ((connected++))
            local ip
            ip=$(docker exec ue_1 ip addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
            if [ -n "$ip" ]; then
                print_info "✓ UE$i — $iface — $ip"
                UE_IPS+=("$ip"); UE_INTERFACES+=("$iface"); ((with_ip++))
            else
                print_warn "⚠ UE$i — $iface — no IP yet"
            fi
        fi
    done
    echo ""
    print_info "Connected: $connected/$total_ues — with IP: $with_ip/$connected"
    export CONNECTED_UES=$connected UES_WITH_IP=$with_ip
    [ $connected -eq 4 ] && return 0 || return 1
}

# Checks if all 4 UEs are connected to DU_e1, 4 different containers
check_ues_connection() {
    local total_ues=4 connected=0 with_ip=0
    UE_IPS=(); UE_INTERFACES=()
    print_stage "Checking UE connections (all on DU_e1)..."
    echo ""
    for i in {0..3}; do
        local container="ue_$i"
        if docker exec "$container" ip addr show 2>/dev/null | grep -q oaitun_ue1; then
            ((connected++))
            local ip
            ip=$(docker exec "$container" ip addr show oaitun_ue1 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
            if [ -n "$ip" ]; then
                print_info "✓ UE$i  — $ip"
                UE_IPS+=("$ip"); UE_INTERFACES+=("oaitun_ue1"); ((with_ip++))
            else
                print_warn "⚠ UE$i — oaitun_ue1 — no IP yet"
            fi
        fi
    done
    echo ""
    print_info "Connected: $connected/$total_ues — with IP: $with_ip/$connected"
    export CONNECTED_UES=$connected UES_WITH_IP=$with_ip
    [ $connected -eq 4 ] && return 0 || return 1
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

# IP check
CURRENT_IP=""
for ip in $(hostname -I); do
    [ "$ip" == "$EDGE_IP" ] && CURRENT_IP="$ip" && break
done
if [ "$CURRENT_IP" != "$EDGE_IP" ]; then
    print_warn "Expected IP $EDGE_IP not found"
    read -p "Continue anyway? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# SCTP module
lsmod | grep -q "^sctp" || sudo modprobe sctp
print_info "✓ SCTP kernel module loaded"

# CRITICAL: Both other machines must be reachable
for target in "$CORE_IP:Core" "$CO_IP:Centraloffice"; do
    tgt_ip="${target%:*}"
    tgt_name="${target#*:}"
    if ! ping -c 3 -W 2 "$tgt_ip" &> /dev/null; then
        print_error "✗ Cannot reach $tgt_name ($tgt_ip)"
        exit 1
    fi
    print_info "✓ Can reach $tgt_name ($tgt_ip)"
done

# SCTP connectivity test
if command -v ncat &> /dev/null; then
    print_info "Testing cross-machine SCTP reachability..."
    for entry in "${CORE_IP}:38472:F1-C→Core CU-CP" \
                 "${CORE_IP}:38462:E1→Core CU-CP" \
                 "${CORE_IP}:36421:E2AP→Core FlexRIC"; do
        h="${entry%%:*}"
        rest="${entry#*:}"
        p="${rest%%:*}"
        label="${rest#*:}"
        # Skip UDP markers / NOT APPLICABLE entries
        [[ "$label" == *UDP* ]] && continue
        [[ "$label" == *"NOT APPLICABLE"* ]] && continue
        if timeout 3 ncat --sctp "$h" "$p" < /dev/null 2>/dev/null; then
            print_info "  ✓ ${h}:${p}/sctp ($label) — REACHABLE"
        else
            print_warn "  ✗ ${h}:${p}/sctp ($label) — NOT REACHABLE"
        fi
    done
else
    print_warn "ncat not installed — skipping pre-flight SCTP test"
fi

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

# Stage 1/7: CU-UP_e (initiates E1 outbound to Core)
print_stage "Stage 1/7: Starting CU-UP_e..."
docker compose -f "$COMPOSE_FILE" up -d cuup_e
wait_for_service "cuup_e" 30
print_info "Waiting for CU-UP_e to set up E1 to Core CU-CP..."
sleep 15
docker exec cuup_e ss -Slnp 2>/dev/null | grep -iE "sctp|2153" || print_warn "CU-UP_e not yet listening"
echo ""

# Stage 1.5/7: Cir (Cir generator)
print_stage "Stage 1.5/7: Starting Cir_generator..."
docker compose -f "$COMPOSE_FILE" up -d cir-generator
#wait_for_service "cir-generator" 30
print_info "Waiting for Cir_generator to start..."
sleep 5
echo ""


# Stage 2/7: UPF_e + ext_dn_e
print_stage "Stage 2/7: Starting UPF_e and ext_dn_e..."
docker compose -f "$COMPOSE_FILE" up -d upf_e ext_dn_e
wait_for_service "upf_e" 30
wait_for_service "ext_dn_e" 30
sleep 5
echo ""

# Stage 3/7: DU_e1 (F1-U cross-machine to CO) + DU_e2 (F1-U local)
print_stage "Stage 3/7: Starting DU_e1 ..."
docker compose -f "$COMPOSE_FILE" up -d du_e1 
wait_for_service "du_e1" 30
#wait_for_service "du_e2" 30
print_info "Waiting for DUs to initialize SCTP + RFSim servers..."
sleep 20

for du in du_e1 ; do
    if docker logs "$du" 2>&1 | grep -q "rf device ready"; then
        print_info "✓ $du server listening"
    else
        print_warn "⚠ $du status unclear"
    fi
done
echo ""

# Stage 4/7: Dynamic SCTP Routing Fix
print_stage "Stage 4/7: Applying dynamic SCTP routing fix..."
echo ""
fix_sctp_routing "$COMPOSE_FILE" "$EDGE_IP"
echo ""

# Stage 4.5/7: Cross-host UDP DNAT (self-contained)
print_stage "Stage 4.5/7: Applying cross-host UDP DNAT..."
if [ -f topology.yaml ] && [ -f fix-udp-routing.sh ]; then
    source ./fix-udp-routing.sh
    fix_udp_routing topology.yaml edge
    verify_udp_routing topology.yaml edge
else
    print_warn "topology.yaml or fix-udp-routing.sh missing — skipping UDP fix"
fi
echo ""

# Stage 5/7: UEs (connect to DU_e1)
print_stage "Stage 5/7: Starting 4 UEs (→ DU_e1)..."
docker compose -f "$COMPOSE_FILE" up -d ue_0 ue_1 ue_2 ue_3 
wait_for_service "ue_0" 30
print_info "Waiting 30s for UE attach + PDU session..."
sleep 30
echo ""

# Stage 6/7: Observability agents
if [ -f docker-compose-observability.yml ]; then
    print_stage "Stage 6/7: Starting observability agents..."
    docker compose -f docker-compose-observability.yml up -d
    sleep 3
    print_info "  ✓ node_exporter on ${EDGE_IP}:9100  (scraped by Core Prometheus)"
    print_info "  ✓ cadvisor      on ${EDGE_IP}:8081  (scraped by Core Prometheus)"
    echo ""
fi

# Stage 6.5/7: F1-U cross-machine routing setup (Edge → CO)
#print_stage "Stage 6.5/7: Starting observability agents..."
# setup_f1u_routes_edge
# echo ""
# setup_n3_routes_edge
# echo ""
# verify_f1u_routes edge
# echo ""

# Stage 7/7: UE connection verification
print_stage "Stage 7/7: Verifying UE connections..."
if check_ues_connection ; then
    print_info "✓ All 4 UEs connected!"
else
    print_warn "Only $CONNECTED_UES/4 UEs connected"
    while true; do
        echo "Options: [w]ait+recheck  [p]roceed  [q]uit"
        read -p "Choice: " -n 1 -r; echo
        case $REPLY in
            [Ww]) sleep 10; check_ues_connection  && break ;;
            [Pp]) print_info "Proceeding with $CONNECTED_UES UE(s)"; break ;;
            [Qq]) break ;;
            *) print_error "Invalid" ;;
        esac
    done
fi

# ==========================================
# Stage 8/8: Slice stress test (optional)
# ==========================================
print_stage "Stage 8/8: Slice stress test..."

# Gate 1: need at least the tunnels up
if [ "${UES_WITH_IP:-0}" -lt 1 ]; then
    print_warn "No UEs with IP — skipping stress test"
else
    # Gate 2: local URLLC iperf server (ext_dn_e) must be listening
    if docker exec ext_dn_e ss -lntu 2>/dev/null | grep -qE '5202'; then
        print_info "✓ ext_dn_e iperf servers listening (5201/5202/5203)"
    else
        print_warn "✗ ext_dn_e iperf servers not up — check trfgen_entrypoint.sh blocking"
    fi

    # Gate 3: data-plane reachability probes (per slice, through the tunnel)
    print_info "Probing per-slice datapaths..."
    docker exec ue_0 ping -c2 -W2 -I oaitun_ue1 192.168.72.135 >/dev/null 2>&1 \
        && print_info "  ✓ eMBB  → ext_dn_co  (CO)"   || print_warn "  ✗ eMBB  datapath (cross-machine to CO)"
    docker exec ue_1 ping -c2 -W2 -I oaitun_ue1 192.168.82.135 >/dev/null 2>&1 \
        && print_info "  ✓ URLLC → ext_dn_e   (local)" || print_warn "  ✗ URLLC datapath"
    docker exec ue_2 ping -c2 -W2 -I oaitun_ue1 192.168.72.31  >/dev/null 2>&1 \
        && print_info "  ✓ mIoT  → ext_dn_core(Core)" || print_warn "  ✗ mIoT  datapath (cross-machine to Core)"

    # Gate 4: pushgateway reachable from Edge
    if timeout 3 bash -c "echo > /dev/tcp/${CORE_IP}/9099" 2>/dev/null; then
        print_info "✓ Pushgateway reachable at ${CORE_IP}:9099"
    else
        print_warn "✗ Pushgateway ${CORE_IP}:9099 unreachable — metrics won't reach Prometheus"
    fi

    read -p "Run slice stress test now? (y/N): " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -f ./slice_stress.sh ]; then
            read -p "Test duration in seconds [60]: " DUR; DUR=${DUR:-60}
            ./slice_stress.sh "$DUR"
            print_info "✓ Stress test complete — raw JSON in ./results/"
            print_info "  Grafana → http://172.31.54.33:3000  (panels: Slice throughput / URLLC jitter)"
        else
            print_error "slice_stress.sh not found in $(pwd)"
        fi
    else
        print_info "Skipped. Run later with: ./slice_stress.sh 60"
    fi
fi
echo ""

# ==========================================
# Final Verification
# ==========================================
echo ""
print_stage "Final verification..."
echo ""
docker compose -f "$COMPOSE_FILE" ps
echo ""

verify_sctp_routing "$COMPOSE_FILE" "$EDGE_IP"

print_info "================================================"
print_info "Edge Deployment Complete!"
print_info "================================================"
echo ""
print_info "SCTP/UDP ports exposed on $EDGE_IP:"
print_info "  DU_e1 F1-C:     ${EDGE_IP}:500/sctp"
#print_info "  DU_e2 F1-C:     ${EDGE_IP}:501/sctp"
print_info "  CU-UP_e F1-U:   ${EDGE_IP}:2153/udp"
echo ""
print_info "Outbound connections this machine initiates:"
print_info "  CU-UP_e → Core CU-CP:  E1   → ${CORE_IP}:38462/sctp"
print_info "  DU_e1   → Core CU-CP:  F1-C → ${CORE_IP}:38472/sctp"
#print_info "  DU_e2   → Core CU-CP:  F1-C → ${CORE_IP}:38472/sctp"
print_info "  DU_e1   → CO CU-UP:    F1-U → ${CO_IP}:2153/udp  (CROSS-MACHINE GTP-U)"
print_info "  DU_e1/e2/CU-UP_e → FlexRIC: E2AP → ${CORE_IP}:36421/sctp"
print_info "  Metrics → Core Grafana: http://${CORE_IP}:3000"
echo ""
print_info "UE summary: ${UES_WITH_IP:-0}/${CONNECTED_UES:-0}/4 UEs attached to DU_e1"
echo ""
print_info "Logs:  docker compose -f $COMPOSE_FILE logs -f"
print_info "Stop:  docker compose -f $COMPOSE_FILE down"
echo ""

read -p "Show live logs? (y/N): " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] && docker compose -f "$COMPOSE_FILE" logs -f
