#!/bin/bash
# deploy-ue.sh - start the UE on the centraloffice USRP and check its slices.
# Run on the centraloffice AFTER deploy-core.sh, deploy-centraloffice.sh and
# deploy-edge.sh (the DU on the edge USRP must be transmitting).
#
#   ./deploy-ue.sh            start ue_0, wait for its 3 PDU sessions, probe, offer stress
#   ./deploy-ue.sh --restart  recreate ue_0 first
set -u
cd "$(dirname "$0")"
[ -f ./testbed.env ] && { set -a; . ./testbed.env; set +a; }
CORE_IP="${CORE_IP:-192.168.1.210}"
COMPOSE_FILE="docker-compose-centraloffice.yml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_stage() { echo -e "${BLUE}[STAGE]${NC} $1"; }
print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# tunnels: oaitun_ue1 eMBB 12.1.1.x, oaitun_ue1p2 URLLC 13.1.1.x, oaitun_ue1p3 mIoT 14.1.1.x
UES_WITH_IP=0
check_ue_sessions() {
    UES_WITH_IP=$(docker exec ue_0 ip -br -4 addr 2>/dev/null | grep -c '^oaitun_ue1')
    docker exec ue_0 ip -br -4 addr 2>/dev/null | grep '^oaitun' | sed 's/^/    /'
    [ "$UES_WITH_IP" -ge 3 ]
}

print_stage "Stage 1/4: USRP links"
bash ./setup-usrp-host.sh co --check || print_warn "USRP links not ready -- sudo ./setup-usrp-host.sh co"
echo ""

print_stage "Stage 2/4: Starting ue_0 (centraloffice USRP)"
[ "${1:-}" = "--restart" ] && docker compose -f "$COMPOSE_FILE" rm -sf ue_0
docker compose -f "$COMPOSE_FILE" up -d --no-deps ue_0
print_info "Waiting for the UE to sync to the edge DU and attach (up to 120 s)..."
for i in $(seq 1 24); do
    sleep 5
    check_ue_sessions >/dev/null && break
    docker logs ue_0 2>&1 | grep -qiE "AssertFatal|segmentation|Exiting OAI softmodem" && {
        print_error "ue_0 stopped:"; docker logs --tail 20 ue_0; exit 1; }
done
echo ""

print_stage "Stage 3/4: PDU sessions"
if check_ue_sessions; then
    print_info "✓ All 3 slices up on ue_0"
else
    print_warn "Only $UES_WITH_IP/3 PDU sessions up. Radio side:"
    docker logs ue_0 2>&1 | grep -iE "sync|SSB|RSRP|RA |Msg|PDU session" | tail -10 | sed 's/^/    /'
fi
echo ""

print_stage "Stage 4/4: per-slice datapaths"
docker exec ue_0 ping -c2 -W2 -I oaitun_ue1   192.168.72.135 >/dev/null 2>&1 \
    && print_info "  ✓ eMBB  → ext_dn_co   (this machine)" || print_warn "  ✗ eMBB  → ext_dn_co"
docker exec ue_0 ping -c2 -W2 -I oaitun_ue1p2 192.168.82.135 >/dev/null 2>&1 \
    && print_info "  ✓ URLLC → ext_dn_e    (edge)"        || print_warn "  ✗ URLLC → ext_dn_e"
docker exec ue_0 ping -c2 -W2 -I oaitun_ue1p3 192.168.72.31  >/dev/null 2>&1 \
    && print_info "  ✓ mIoT  → ext_dn_core (core)"        || print_warn "  ✗ mIoT  → ext_dn_core"
timeout 3 bash -c "echo > /dev/tcp/${CORE_IP}/9099" 2>/dev/null \
    && print_info "  ✓ Pushgateway ${CORE_IP}:9099" || print_warn "  ✗ Pushgateway ${CORE_IP}:9099 unreachable"
echo ""

if [ "$UES_WITH_IP" -ge 1 ]; then
    read -p "Run slice stress test now? (y/N): " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Test duration in seconds [60]: " DUR; DUR=${DUR:-60}
        ./slice_stress.sh "$DUR"
    else
        print_info "Later: ./slice_stress.sh 60   (on this machine: the UE is here now)"
    fi
fi
print_info "UE logs: docker logs -f ue_0     Stop: docker compose -f $COMPOSE_FILE rm -sf ue_0"
