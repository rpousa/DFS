#!/bin/bash
# usrp-reboot.sh co|edge - reboot this machine's N310 and wait until it is usable.
# Needed after a DU/UE crashed while streaming: the N310's RFNoC blocks stay
# stuck and the next start fails with "RFNOC::GRAPH One or more blocks timed out
# during flush", "Timed out getting recv buff for management transaction" or a
# segfault at "setting rx channel 0". A reboot reloads the FPGA (XG is kept).
set -u
cd "$(dirname "$0")"
[ -f ./testbed.env ] && { set -a; . ./testbed.env; set +a; }
case "${1:-}" in
  co)   SDR="${CO_SDR_ARGS:-addr=192.168.10.2}";   IMG=ue:comnetsemu; CT=ue_0 ;;
  edge) SDR="${EDGE_SDR_ARGS:-addr=192.168.30.2}"; IMG=du:comnetsemu; CT=du_e1 ;;
  *) echo "usage: $0 co|edge"; exit 1 ;;
esac
IP=$(echo "$SDR" | grep -oP '(^|,)(mgmt_)?addr=\K[0-9.]+' | head -1)
docker rm -f "$CT" >/dev/null 2>&1 && echo "removed $CT"
SSH="ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$IP"
if ! $SSH true 2>/dev/null; then
  echo "✗ no non-interactive root ssh to the N310 $IP: run once  ssh-copy-id root@$IP"
  echo "  (or reboot it from its front panel), then run this again"
  exit 1
fi
echo "rebooting N310 $IP ..."
$SSH reboot 2>/dev/null
sleep 20
for i in $(seq 1 36); do
  ping -c1 -W1 "$IP" >/dev/null 2>&1 && break
  sleep 5
done
ping -c1 -W1 "$IP" >/dev/null 2>&1 || { echo "✗ $IP not back after 3 min"; exit 1; }
echo "  $IP answers, waiting for MPM ..."
sleep 30
bash ./usrp-wait-free.sh "$IP" "$IMG" 120 || exit 1
# MPM restarts its RPC server once more shortly after boot ("Launching USRP/MPM"
# in the radio log); a radio that opens the device then segfaults. Let it settle
# and check again.
sleep 20
bash ./usrp-wait-free.sh "$IP" "$IMG" 60
