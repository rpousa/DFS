#!/bin/bash
set -u
PGW="http://192.168.0.200:9099"
DUR=${1:-60}

MAP=(
  "ue_0 embb  192.168.72.135 5201 tcp"
  "ue_1 urllc 192.168.82.135 5202 udp"
  "ue_2 miot  192.168.72.31  5203 udp"
#  "ue_3 embb  192.168.72.135 5201 tcp"   # no ue_3: the DU has 3 vrtsim slots
)

push() { curl -s --data-binary @- "$PGW/metrics/job/stress/slice/$1"; }

run_slice() {
  local ue slice ip port proto
  read ue slice ip port proto <<< "$1"
  local ts raw; ts=$(date +%s); raw="./results/${slice}_${ts}.jsonl"
  echo "[stress] $slice via $ue → $ip:$port ($proto)"

  local OPTS
  if [ "$proto" = tcp ]; then
    OPTS="-R -P 4"
  else
    local RATE; RATE=$([ "$slice" = urllc ] && echo 8M || echo 500K)
    OPTS="-u -b $RATE -l 200"
  fi

  # Bind to the UE's tunnel address so the test goes through the 5G user
  # plane, not out of the container's eth0 (ran_net) default route.
  local src
  src=$(docker exec "$ue" ip -4 -o addr show oaitun_ue1 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  [ -n "$src" ] || { echo "[stress] $slice SKIP — $ue has no oaitun_ue1 address"; return 1; }

  docker exec "$ue" iperf3 -c "$ip" -B "$src" -p "$port" $OPTS -t "$DUR" -i 1 --json-stream 2>/dev/null \
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
  run_slice "$row" &          # ← launch each slice concurrently
  pids+=($!)
done

# wait for all, capture per-slice exit status
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
[ "$fail" -eq 0 ] && echo "[stress] all slices complete" \
                  || echo "[stress] one or more slices failed"
echo "[stress] push target $PGW"