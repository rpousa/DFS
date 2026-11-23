#!/bin/bash
# pin-rt.sh <container> <process> <hot-cores> <rt-cores> <other-cores> [hot-regex] [min-rtprio]
#
# The testbed hosts boot with isolcpus=managed_irq,domain,4-27: CPUs 4-27 are
# never load-balanced, so a thread stays on whichever CPU it first ran on. A
# radio's unpinned real-time threads (thread pool, SYNC/DL/UL actors, UE/RU
# thread, USRP write thread, UHD control endpoint) therefore pile up on a few
# cores and starve each other: ~100 ms "Deadline missed", "L" floods,
# write-queue overflows and finally uhd::op_timeout.
#
# This places every thread of <process> in <container>:
#   name matches hot-regex (the busy loops)         -> its own core from <hot-cores>
#   other SCHED_FIFO/RR, rtprio >= min-rtprio (90)  -> round robin over <rt-cores>
#   everything else                                 -> <other-cores>
# A thread on a single CPU outside these lists was pinned by OAI (thread-pool
# core list, ru_thread_core) and stays there. A single CPU inside the lists was
# only inherited from its creator, so it is placed like any other thread.
# Runs inside the container (SYS_NICE), re-checks every 2 s so threads created
# later are placed too, ends with the container.
# Log: docker exec <container> cat /tmp/pin-rt.log
set -u
CT=$1; PROC=$2; HOT=$3; RT=$4; OT=$5
RX=${6:-UEthread|trx_usrp_write|uhd_ctrl|ru_thread}; MINP=${7:-90}
docker exec "$CT" sh -c 'command -v taskset >/dev/null' \
  || { echo "  ⚠ pin-rt: no taskset in $CT, threads left unpinned"; exit 0; }
if docker exec "$CT" sh -c 'p=$(cat /tmp/pin-rt.pid 2>/dev/null) && [ -d /proc/$p ]'; then
  echo "  ✓ pin-rt already running in $CT"; exit 0
fi
docker exec -d "$CT" sh -c '
P=$1; HOT=$2; RT=$3; OT=$4; RX=$5; MINP=$6
echo $$ > /tmp/pin-rt.pid; : > /tmp/pin-rt.done; h=0; r=0
OURS=",$HOT,$RT,$OT,"
nth() { echo "$1" | tr , "\n" | sed -n "$(( $2 % $(echo "$1" | tr , "\n" | wc -l) + 1 ))p"; }
log() { echo "$(date +%T) $*" >> /tmp/pin-rt.log; }
log "pin-rt: $P hot $HOT ($RX) rt $RT other $OT min-rtprio $MINP"
while :; do
  pid=""
  for d in /proc/[0-9]*; do [ "$(cat $d/comm 2>/dev/null)" = "$P" ] && { pid=${d#/proc/}; break; }; done
  if [ -n "$pid" ]; then
    for t in /proc/$pid/task/[0-9]*; do
      tid=${t##*/}
      grep -qx "$tid" /tmp/pin-rt.done && continue
      st=$(cat $t/stat 2>/dev/null) || continue
      name=$(cat $t/comm 2>/dev/null)
      rest=${st##*) }                      # fields 3.. ; rt_priority = field 40, policy = 41
      prio=$(echo "$rest" | awk "{print \$38}"); pol=$(echo "$rest" | awk "{print \$39}")
      cur=$(taskset -pc $tid 2>/dev/null | sed "s/.*: //")
      case "$cur" in *[,-]*) ;; *)
        case "$OURS" in *",$cur,"*) ;; *)
          log "keep  $tid $name prio $prio on $cur (pinned by OAI)"; echo $tid >> /tmp/pin-rt.done; continue ;;
        esac ;;
      esac
      if echo "$name" | grep -qE "^($RX)"; then core=$(nth "$HOT" $h); h=$((h + 1))
      elif [ "$pol" -ge 1 ] 2>/dev/null && [ "$pol" -le 2 ] && [ "$prio" -ge "$MINP" ]; then
        core=$(nth "$RT" $r); r=$((r + 1))
      else core=$OT; fi
      taskset -pc $core $tid >/dev/null 2>&1 && log "pin   $tid $name pol $pol prio $prio $cur -> $core"
      echo $tid >> /tmp/pin-rt.done
    done
  fi
  sleep 2
done' sh "$PROC" "$HOT" "$RT" "$OT" "$RX" "$MINP"
echo "  ✓ pin-rt started in $CT: busy threads -> $HOT, other rt -> $RT, rest -> $OT"
