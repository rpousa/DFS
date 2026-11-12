#!/bin/bash
# Prepare (or just check) the host side of the two SFP+ links to the USRP.
#
#   sudo ./setup-usrp-host.sh co|edge          # configure, then check
#   ./setup-usrp-host.sh co|edge --check       # only check (used by the deploy scripts)
#
# Configures: MTU 9000 and a host address on each SFP link, large NIC rings,
# the socket buffers UHD asks for, the performance CPU governor. None of it
# survives a reboot -- rerun after one (or put it in netplan / sysctl.d).
set -u
cd "$(dirname "$0")"
[ -f ./testbed.env ] && { set -a; . ./testbed.env; set +a; }

role="${1:-}"; mode="${2:-}"
case "$role" in
  co)   P=CO ;;
  edge) P=EDGE ;;
  *) echo "usage: $0 co|edge [--check]"; exit 1 ;;
esac
v() { eval "echo \${${P}_$1:-}"; }
IF0=$(v SFP0_IF); IF1=$(v SFP1_IF)
HIP0=$(v HOST_SFP0_IP); HIP1=$(v HOST_SFP1_IP)
SDR=$(v SDR_ARGS)
USRP0=$(echo "$SDR" | grep -oP '(^|,)addr=\K[0-9.]+')
USRP1=$(echo "$SDR" | grep -oP 'second_addr=\K[0-9.]+')

ok=0
check() {
  for pair in "$IF0:$USRP0" "$IF1:$USRP1"; do
    ifc=${pair%%:*}; dst=${pair#*:}
    if ! ip link show "$ifc" >/dev/null 2>&1; then
      echo "  ✗ $ifc does not exist (set ${P}_SFP*_IF in .env)"; ok=1; continue
    fi
    mtu=$(cat /sys/class/net/$ifc/mtu); speed=$(cat /sys/class/net/$ifc/speed 2>/dev/null || echo ?)
    state=$(cat /sys/class/net/$ifc/operstate)
    printf "  %-10s %-5s %6s Mb/s  MTU %-5s" "$ifc" "$state" "$speed" "$mtu"
    [ "$mtu" -ge 9000 ] || { printf "  ✗ MTU < 9000"; ok=1; }
    if [ -n "$dst" ] && ping -c1 -W1 -I "$ifc" "$dst" >/dev/null 2>&1; then
      printf "  ✓ USRP %s answers\n" "$dst"
    else
      printf "  ✗ USRP %s does not answer\n" "$dst"; ok=1
    fi
  done
  rmem=$(sysctl -n net.core.rmem_max); wmem=$(sysctl -n net.core.wmem_max)
  [ "$rmem" -ge 33554432 ] && [ "$wmem" -ge 33554432 ] \
    && echo "  ✓ socket buffers rmem_max $rmem wmem_max $wmem" \
    || { echo "  ✗ socket buffers too small (rmem_max $rmem wmem_max $wmem)"; ok=1; }
  return $ok
}

if [ "$mode" != "--check" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "configure needs root: sudo $0 $role"; exit 1; }
  for pair in "$IF0:$HIP0" "$IF1:$HIP1"; do
    ifc=${pair%%:*}; hip=${pair#*:}
    ip link set "$ifc" up mtu 9000
    ip -4 addr show dev "$ifc" | grep -q " $hip/" || ip addr add "$hip/24" dev "$ifc"
    ethtool -G "$ifc" rx 4096 tx 4096 2>/dev/null || true
  done
  sysctl -q -w net.core.rmem_max=33554432 net.core.wmem_max=33554432 \
               net.core.rmem_default=33554432 net.core.wmem_default=33554432
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g" 2>/dev/null; done
  echo "configured $IF0 ($HIP0) and $IF1 ($HIP1), MTU 9000"
fi

echo "USRP links ($role):"
check; rc=$?
if [ $rc -eq 0 ] && [ "$mode" != "--check" ]; then
  img=$([ "$role" = co ] && echo ue:comnetsemu || echo du:comnetsemu)
  echo "UHD view from $img (host network):"
  docker run --rm --net host "$img" sh -c "uhd_find_devices --args addr=$USRP0 2>/dev/null || ls /usr/local/bin | grep -i uhd" | sed 's/^/  /'
fi
exit $rc
