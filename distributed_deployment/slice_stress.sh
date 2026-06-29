#!/bin/bash
# slice_stress.sh  — run on Edge (192.168.0.243)
set -u
PGW="http://192.168.0.200:9092"
DUR=${1:-60}

# ue_container  slice  target_ext_dn          port  proto
MAP=(
  "ue_0 embb  192.168.72.135 5201 tcp"   # eMBB  → ext_dn_co (CO)
  "ue_1 urllc 192.168.82.135 5202 udp"   # URLLC → ext_dn_e  (Edge, local)
  "ue_2 miot  192.168.72.31  5203 udp"   # mIoT  → ext_dn_core (Core)
  "ue_3 embb  192.168.72.135 5201 tcp"   # eMBB  → ext_dn_co (CO)
)

mkdir -p ./results
for row in "${MAP[@]}"; do
  read ue slice ip port proto <<< "$row"
  echo "[stress] $slice via $ue → $ip:$port ($proto)"
  if [ "$proto" = tcp ]; then
    J=$(docker exec "$ue" iperf3 -c "$ip" -p "$port" -R -t "$DUR" -P 4 -i 1 --json 2>/dev/null)
    BPS=$(echo "$J"  | jq '.end.sum_received.bits_per_second // 0')
    RETR=$(echo "$J" | jq '.end.sum_sent.retransmits // 0')
    curl -s --data-binary @- "$PGW/metrics/job/stress/slice/$slice" <<EOF
slice_throughput_bps $BPS
slice_tcp_retransmits $RETR
EOF
  else
    RATE=$([ "$slice" = urllc ] && echo 8M || echo 500K)
    J=$(docker exec "$ue" iperf3 -c "$ip" -p "$port" -u -b "$RATE" -l 200 -t "$DUR" -i 1 --json 2>/dev/null)
    BPS=$(echo "$J"  | jq '.end.sum.bits_per_second // 0')
    JIT=$(echo "$J"  | jq '.end.sum.jitter_ms // 0')
    LOSS=$(echo "$J" | jq '.end.sum.lost_percent // 0')
    curl -s --data-binary @- "$PGW/metrics/job/stress/slice/$slice" <<EOF
slice_throughput_bps $BPS
slice_jitter_ms $JIT
slice_loss_percent $LOSS
EOF
  fi
  echo "$J" > "./results/${slice}_$(date +%s).json"
done
echo "[stress] done — raw JSON in ./results/, metrics pushed to $PGW"