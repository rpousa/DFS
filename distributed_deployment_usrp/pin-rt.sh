#!/bin/bash
# pin-rt.sh <container> <process> <rt-cores> <other-cores> [min-rtprio]
#
# The testbed hosts boot with isolcpus=managed_irq,domain,4-27: CPUs 4-27 are
# never load-balanced, so a thread stays on whichever CPU it first ran on. A
# radio's unpinned real-time threads (thread pool, SYNC/DL/UL actors, UE/RU
# thread, USRP write thread, UHD I/O) therefore pile up on a few cores and starve
# each other: ~100 ms "Deadline missed", "L" floods, write-queue overflows and
# finally uhd::op_timeout.
#
# This places every thread of <process> in <container>:
#   SCHED_FIFO/RR with rtprio >= min-rtprio (default 90) -> its own core from
#                                                            <rt-cores>, round robin
#   everything else                                       -> <other-cores>
# Threads OAI already pinned to one CPU (thread-pool core list, ru_thread_core)
# are left where they are. It runs inside the container (SYS_NICE) and re-checks
# every 2 s, so threads created later (PDU sessions, re-sync) are placed too; it
# ends with the container. Log: docker exec <container> cat /tmp/pin-rt.log
set -u
CT=$1; PROC=$2; RT=$3; OT=$4; MINP=${5:-90}
docker exec "$CT" sh -c 'command -v taskset >/dev/null' \
  || { echo "  ⚠ pin-rt: no taskset in $CT, threads left unpinned"; exit 0; }
if docker exec "$CT" sh -c 'p=$(cat /tmp/pin-rt.pid 2>/dev/null) && [ -d /proc/$p ]'; then
  echo "  ✓ pin-rt already running in $CT"; exit 0
fi
docker exec -d "$CT" sh -c '
P=$1; RT=$2; OT=$3; MINP=$4
echo $$ > /tmp/pin-rt.pid; : > /tmp/pin-rt.done; i=0
set -- $(echo "$RT" | tr , " "); N=$#
log() { echo "$(date +%T) $*" >> /tmp/pin-rt.log; }
log "pin-rt: $P rt-cores $RT other-cores $OT min-rtprio $MINP"
while :; do
  pid=""
  for d in /proc/[0-9]*; do [ "$(cat $d/comm 2>/dev/null)" = "$P" ] && { pid=${d#/proc/}; break; }; done
  if [ -n "$pid" ]; then
    for t in /proc/$pid/task/[0-9]*; do
      tid=${t##*/}
      grep -qx "$tid" /tmp/pin-rt.done && continue
      st=$(cat $t/stat 2>/dev/null) || continue
      name=$(cat $t/comm 2>/dev/null)
      rest=${st##*) }                      # fields 3.. ; policy = field 41, rt_priority = 40
      prio=$(echo "$rest" | awk "{print \$38}"); pol=$(echo "$rest" | awk "{print \$39}")
      cur=$(taskset -pc $tid 2>/dev/null | sed "s/.*: //")
      case "$cur" in *[,-]*) ;; *) log "keep  $tid $name prio $prio on $cur (pinned by OAI)"; echo $tid >> /tmp/pin-rt.done; continue ;; esac
      if [ "$pol" -ge 1 ] 2>/dev/null && [ "$pol" -le 2 ] && [ "$prio" -ge "$MINP" ]; then
        k=$(( i % N + 1 )); eval core=\${$k}; i=$((i + 1))
      else core=$OT; fi
      taskset -pc $core $tid >/dev/null 2>&1 && log "pin   $tid $name pol $pol prio $prio -> $core"
      echo $tid >> /tmp/pin-rt.done
    done
  fi
  sleep 2
done' sh "$PROC" "$RT" "$OT" "$MINP"
echo "  ✓ pin-rt started in $CT: rt threads -> $RT, others -> $OT"
