# distributed_deployment_usrp

Same three-machine deployment as `distributed_deployment`, for the new testbed:
one switch for the three machines, and over-the-air (or cabled) radio between
two USRPs instead of vrtsim.

| Machine | LAN (switch) | Runs | Radio |
|---|---|---|---|
| core `cgcc` | `enp0s31f6` 192.168.1.210 | 5GC, CU-CP, UPF_core, ext_dn_core, FlexRIC, Grafana, reloc-ctl | — |
| centraloffice | `eno1` 192.168.1.219 (+ `eno2`/`eno3`) | CU-UP_co, UPF_co, ext_dn_co, **UE `ue_0`** | USRP over `eno11np1` + `eno12np2` |
| edge | `eno1` 192.168.1.221 (+ one more) | CU-UP_e, UPF_e, ext_dn_e, **DU `du_e1`** | USRP over `eno10np0` + `eno13np3` |

The SFP interface names are guesses from `ip -br addr` (up, no address). Check
them first (below) and fix them in `testbed.env`.

## What changed from distributed_deployment

- **Addresses**, in every compose file, config, script and dashboard:

  | Was | Now | What |
  |---|---|---|
  | 192.168.0.200 | 192.168.1.210 | core |
  | 192.168.0.193 | 192.168.1.219 | centraloffice |
  | 192.168.0.243 | 192.168.1.221 | edge |
  | 172.31.54.33 | 192.168.1.210 | Grafana and reloc-ctl; the core no longer has that address |

  Duplicate port mappings that became identical were removed.
- **`testbed.env`** (new): all USRP settings, sourced by every deploy script and by stop.sh, so docker compose interpolates them; the compose files carry the same values as defaults.
- **Edge `du_e1`**:
  - vrtsim is replaced by the USRP: config `configs/du_e1/gnb-du.sa.band78.273prb.usrp.yaml`, plus `--RUs.[0].sdr_addrs` and the gains from `testbed.env`;
  - two macvlan networks (`usrp_sfp0`, `usrp_sfp1`) on the SFP ports, so UHD streams straight to the container;
  - the container keeps its default route on `core_net`;
  - it gets the cores the UE used: 3-20 by default.
- **`ue_0`** has moved from edge to centraloffice: config `configs/ue_1/nrue0.usrp.yaml`, the same IMSI and three PDU sessions, `--usrp-args` from `testbed.env`.
- **New scripts:**
  - `setup-usrp-host.sh co|edge` configures the SFP links (MTU 9000, host address, rings, socket buffers, CPU governor) and checks that the USRP answers.
  - `deploy-ue.sh` (centraloffice) starts the UE after the DU is on air, checks the three sessions and the per-slice paths, and offers the stress test.
- **`deploy-edge.sh`** no longer starts a UE or runs the stress test. `slice_stress.sh` now runs on the centraloffice.

## First time on each machine

1. **Check the interfaces** (centraloffice and edge):
   ```bash
   for i in $(ls /sys/class/net | grep -E '^en'); do
     printf "%-10s %-6s %6s Mb/s  %s\n" $i $(cat /sys/class/net/$i/operstate) \
       $(cat /sys/class/net/$i/speed 2>/dev/null) "$(ethtool -i $i 2>/dev/null | grep driver)"
   done
   ```
   The USRP links show 10000 Mb/s. Put their names in `testbed.env` (`CO_SFP*_IF`, `EDGE_SFP*_IF`).
2. **Configure the links and find the USRP:** `sudo ./setup-usrp-host.sh edge` (or `co`).
   - If the USRP does not answer on 192.168.10.2 / 192.168.20.2, it may be an X310 with the 10 GbE image (192.168.40.2 / 192.168.30.2). Change `*_SFP*_SUBNET`, `*_HOST_SFP*_IP`, `*_SFP*_IP` and `*_SDR_ARGS` in `testbed.env`.
   - For an X310, also add `-E` to `EDGE_DU_EXTRA_OPTS` and `CO_UE_EXTRA_OPTS`.
3. **Make the LAN addresses permanent** (netplan). The core no longer has 192.168.0.200 or 172.31.54.33, and nothing here uses them.

## Deploy order

```text
core:          ./deploy-core.sh
centraloffice: ./deploy-centraloffice.sh
edge:          ./deploy-edge.sh          # DU goes on air
centraloffice: ./deploy-ue.sh            # UE syncs, attaches, 3 PDU sessions
```

- **Grafana:** `http://192.168.1.210:3000`. Over Tailscale it is not published: bind Grafana to 0.0.0.0 in `docker-compose-core.yml` if you need that.
- **reloc-ctl:** `http://192.168.1.210:8095`.

## Radio notes

- **Sampling rate.** 100 MHz, 2x2 (273 PRB) runs at 122.88 Msps per channel on an N310, or at 92.16 Msps with `-E` on an X310. Two channels at those rates need both 10 GbE links, which is why each USRP has two.
- **No common clock.** The two USRPs are not synchronised. The UE locks to the DU's SSB; `--ue-fo-compensation` is on by default. Use a cable with attenuators, or keep power low over the air in a licensed or shielded setup.
- **Gains.** Start with the defaults, then tune: `EDGE_ATT_TX`, `EDGE_MAX_RXGAIN`, and `--ue-rxgain` / `--ue-txgain` in `CO_UE_EXTRA_OPTS`. Watch the UE's RSRP and the DU's `ulsch`/`pucch` SNR in the logs.
- **UE CPU.** The UE at 273 PRB 2x2 needs a strong CPU. If it can't keep up (late slots, `[HW] ... underflow`), go to 106 PRB / 40 MHz first.
