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
  local ts raw; ts=$(date +%s); raw="./results/${slice}_${ts}.log"
  echo "[stress] $slice via $UE_CTR:$iface ($src) → $ip:$port ($proto)"

  docker exec "$UE_CTR" ip addr show "$iface" 2>/dev/null | grep -q "$src" \
    || { echo "[stress] $slice SKIP — $iface ($src) missing"; return 1; }
  
  rtt=$(docker exec "$UE_CTR" ping -c 5 -I "$iface" "$ip" 2>/dev/null \
      | awk -F'/' '/rtt|round-trip/ {print $5}')   # avg ms
  [ -n "$rtt" ] && push "$slice" <<< "slice_rtt_ms ${rtt}"

  local OPTS
  if [ "$proto" = tcp ]; then
      OPTS="-R -P 4"
  else
      local RATE; RATE=$([ "$slice" = urllc ] && echo 8M || echo 500K)
      OPTS="-u -b $RATE -l 200"
  fi

  # 3.16: stream text intervals; stdbuf+--forceflush prevent pipe buffering
  docker exec "$UE_CTR" stdbuf -oL iperf3 -c "$ip" -B "$src" -p "$port" \
        $OPTS -t "$DUR" -i 1 --forceflush 2>&1 \
  | tee "$raw" \
  | while IFS= read -r line; do
        # interval lines contain "sec" + a bitrate; skip the final summary
        echo "$line" | grep -qE '[0-9.]+-[0-9.]+ +sec' || continue
        echo "$line" | grep -qiE 'sender|receiver' && continue
        # extract "<value> <unit>bits/sec" → bps
        read val unit <<< "$(echo "$line" | grep -oE '[0-9.]+ [KMG]?bits/sec' | tail -1 | sed 's#bits/sec##')"
        [ -z "$val" ] && continue
        case "$unit" in
          K) bps=$(awk "BEGIN{print $val*1e3}") ;;
          M) bps=$(awk "BEGIN{print $val*1e6}") ;;
          G) bps=$(awk "BEGIN{print $val*1e9}") ;;
          *) bps=$val ;;
        esac
        push "$slice" <<EOF
slice_throughput_bps $bps
EOF
    done

  # ---- final summary → jitter / loss / retransmits ----
  if [ "$proto" = udp ]; then
      # e.g.  "... 0.123 ms  5/1000 (0.5%)  receiver"
      local sum jit loss
      sum=$(grep -iE 'receiver' "$raw" | tail -1)
      jit=$(echo "$sum"  | grep -oE '[0-9.]+ ms' | grep -oE '[0-9.]+' | tail -1)
      loss=$(echo "$sum" | grep -oE '\([0-9.]+%\)' | grep -oE '[0-9.]+' | tail -1)
      [ -n "$jit" ]  && push "$slice" <<< "slice_jitter_ms ${jit}"
      [ -n "$loss" ] && push "$slice" <<< "slice_loss_percent ${loss}"
  else
      # TCP retransmits: sum the "Retr" column across parallel streams (sender summary)
      local retr
      retr=$(grep -iE 'sender' "$raw" | grep -oE '[0-9]+ +sender' | grep -oE '^[0-9]+' | tail -1)
      [ -n "$retr" ] && push "$slice" <<< "slice_tcp_retransmits ${retr}"
  fi
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
