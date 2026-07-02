#!/bin/bash
set -u
PGW="http://192.168.0.200:9099"
DUR=${1:-60}
UE_CTR="ue_1"                       # single container, 3 tun interfaces

# slice  iface        src_ip     target_ip        port proto
MAP=(
  "embb  oaitun_ue1 12.1.1.2 192.168.72.135 5201 tcp"   # SST1 → ext_dn_co  (CO,   cross-machine)
  "urllc oaitun_ue2 13.1.1.2 192.168.82.135 5202 udp"   # SST2 → ext_dn_e   (edge, local)
  "miot  oaitun_ue3 14.1.1.2 192.168.72.31  5203 udp"   # SST3 → ext_dn_core(Core, cross-machine)
)

push() { curl -s --data-binary @- "$PGW/metrics/job/stress/slice/$1"; }

run_slice() {
  local slice iface src ip port proto
  read slice iface src ip port proto <<< "$1"
  local ts raw; ts=$(date +%s); raw="./results/${slice}_${ts}.jsonl"
  echo "[stress] $slice via $UE_CTR:$iface ($src) → $ip:$port ($proto)"

  # preflight: interface must exist and have the expected IP
  if ! docker exec "$UE_CTR" ip addr show "$iface" 2>/dev/null | grep -q "$src"; then
    echo "[stress] $slice SKIP — $iface ($src) not present in $UE_CTR"; return 1
  fi

  local OPTS
  if [ "$proto" = tcp ]; then
    OPTS="-R -P 4"
  else
    local RATE; RATE=$([ "$slice" = urllc ] && echo 8M || echo 500K)
    OPTS="-u -b $RATE -l 200"
  fi

  # -B binds the source IP → kernel routes out the matching tun
  docker exec "$UE_CTR" iperf3 -c "$ip" -B "$src" -p "$port" $OPTS -t "$DUR" -i 1 --json-stream 2>/dev/null \
  | tee "$raw" \
  | while IFS= read -r line; do
        [ "$(echo "$line" | jq -r '.event // empty')" = "interval" ] || continue
        BPS=$(echo "$line" | jq '.data.sum.bits_per_second // 0')
        if [ "$proto" = udp ]; then
            JIT=$(echo "$line"  | jq '.data.sum.jitter_ms // 0')
            LOSS=$(echo "$line" | jq '.data.sum.lost_percent // 0')
            push "$slice" <<EOF
slice_throughput_bps $BPS
slice_jitter_ms $JIT
slice_loss_percent $LOSS
EOF
        else
            push "$slice" <<EOF
slice_throughput_bps $BPS
EOF
        fi
    done
  echo "[stress] $slice done — $raw"
}

mkdir -p ./results
pids=()
for row in "${MAP[@]}"; do
  run_slice "$row" &
  pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
[ "$fail" -eq 0 ] && echo "[stress] all slices complete" || echo "[stress] one or more slices failed"
echo "[stress] push target $PGW"
