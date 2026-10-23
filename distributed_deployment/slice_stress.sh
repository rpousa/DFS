#!/bin/bash
set -u
PGW="http://192.168.0.200:9099"
DUR=${1:-60}
UE_CTR="ue_0"                       # single UE, 3 PDU sessions (one per slice)

# What to send, per slice (defaults = the original mix). Override in the env:
#   SLICES="embb urllc miot"   which slices to run
#   <SLICE>_PROTO  tcp|udp     EMBB tcp, URLLC/MIOT udp
#   <SLICE>_DIR    dl|ul       dl = server sends to the UE (iperf3 -R)
#                              EMBB dl, URLLC/MIOT ul
#   <SLICE>_RATE   udp target  EMBB 100M, URLLC 8M, MIOT 500K (tcp: no cap)
#   <SLICE>_STREAMS parallel   EMBB 4, others 1
#   <SLICE>_LEN    udp payload EMBB 1400, others 200
# e.g. only eMBB, UDP downlink at 300 Mbit/s:
#   SLICES=embb EMBB_PROTO=udp EMBB_RATE=300M ./slice_stress.sh 30
SLICES=${SLICES:-"embb urllc miot"}

# slice  iface        src_ip     target_ip        port proto
MAP=(
  "embb  oaitun_ue1 12.1.1.2 192.168.72.135 5201 tcp"   # SST1 → ext_dn_co  (CO,   cross-machine)
  "urllc oaitun_ue1p2 13.1.1.2 192.168.82.135 5202 udp" # SST2 → ext_dn_e   (edge, local)
  "miot  oaitun_ue1p3 14.1.1.2 192.168.72.31  5203 udp" # SST3 → ext_dn_core(Core, cross-machine)
)

push() { curl -s --data-binary @- "$PGW/metrics/job/stress/slice/$1"; }

run_slice() {
  local slice iface src ip port proto
  read slice iface src ip port proto <<< "$1"
  local ts raw; ts=$(date +%s); raw="./results/${slice}_${ts}.log"
  echo "[stress] $slice via $UE_CTR:$iface ($src) → $ip:$port ($proto)"

  docker exec "$UE_CTR" ip addr show "$iface" 2>/dev/null | grep -q "$src" \
    || { echo "[stress] $slice SKIP — $iface ($src) missing"; return 1; }

  local U=${slice^^} d_dir d_rate d_streams d_len v
  case "$slice" in
    embb) d_dir=dl; d_rate=100M; d_streams=4; d_len=1400 ;;
    urllc) d_dir=ul; d_rate=8M; d_streams=1; d_len=200 ;;
    *)     d_dir=ul; d_rate=500K; d_streams=1; d_len=200 ;;
  esac
  v="${U}_PROTO";   proto=${!v:-$proto}
  v="${U}_DIR";     local dir=${!v:-$d_dir}
  v="${U}_RATE";    local rate=${!v:-$d_rate}
  v="${U}_STREAMS"; local streams=${!v:-$d_streams}
  v="${U}_LEN";     local len=${!v:-$d_len}

  local OPTS="-P $streams"
  [ "$dir" = dl ] && OPTS="$OPTS -R"
  [ "$proto" = udp ] && OPTS="$OPTS -u -b $rate -l $len"
  echo "[stress] $slice: $proto $dir, $streams stream(s)$([ "$proto" = udp ] && echo ", $rate each")"

  # 3.16: stream text intervals; stdbuf+--forceflush prevent pipe buffering
  ( docker exec "$UE_CTR" ping -n -i 1 -w "$DUR" -I "$iface" "$ip" 2>/dev/null \
  | stdbuf -oL grep -oE 'time=[0-9.]+' \
  | while IFS= read -r t; do push "$slice" <<< "slice_rtt_ms ${t#time=}"; done ) &
  docker exec "$UE_CTR" stdbuf -oL iperf3 -c "$ip" -B "$src" -p "$port" \
        $OPTS -t "$DUR" -i 1 --forceflush 2>&1 \
  | tee "$raw" \
  | while IFS= read -r line; do
        # interval lines contain "sec" + a bitrate; skip the final summary
        echo "$line" | grep -qE '[0-9.]+-[0-9.]+ +sec' || continue
        echo "$line" | grep -qiE 'sender|receiver' && continue
        # with several streams only the [SUM] line is the slice total
        [ "$streams" -gt 1 ] && ! echo "$line" | grep -q '^\[SUM\]' && continue
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
      sum=$(grep -iE 'receiver' "$raw" | tail -1) # last = [SUM] with several streams
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
  [[ " $SLICES " == *" ${row%% *} "* ]] || continue
  run_slice "$row" &
  pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
[ "$fail" -eq 0 ] && echo "[stress] all slices complete" || echo "[stress] one or more slices failed"
echo "[stress] push target $PGW"
