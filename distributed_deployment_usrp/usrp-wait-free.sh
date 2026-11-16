#!/bin/bash
# usrp-wait-free.sh MGMT_ADDR IMAGE [TIMEOUT_S]
# Wait until the N3xx at MGMT_ADDR is no longer claimed. After a radio
# container is stopped or killed, MPM keeps its claim until the claim times
# out; a new DU/UE started before that dies with "Someone tried to claim this
# device again". Uses uhd_find_devices from IMAGE on the host network.
addr="${1:?usage: $0 MGMT_ADDR IMAGE [TIMEOUT_S]}"; img="${2:?image}"; tmo="${3:-90}"
for ((t = 0; t <= tmo; t += 5)); do
    out=$(docker run --rm --net host --entrypoint uhd_find_devices "$img" --args "addr=$addr" 2>/dev/null \
          || docker run --rm --net host "$img" uhd_find_devices --args "addr=$addr" 2>/dev/null)
    if echo "$out" | grep -q "claimed: False"; then
        [ $t -gt 0 ] && echo "  ✓ USRP $addr free after ${t} s" || echo "  ✓ USRP $addr free"
        exit 0
    fi
    echo "$out" | grep -q "claimed: True" || { echo "  ? USRP $addr: no answer from uhd_find_devices"; exit 0; }
    [ $t -eq 0 ] && echo "  … USRP $addr still claimed by a previous radio process, waiting (up to ${tmo} s)"
    sleep 5
done
echo "  ✗ USRP $addr still claimed after ${tmo} s -- free it: ssh root@$addr systemctl restart usrp-hwd"
exit 1
