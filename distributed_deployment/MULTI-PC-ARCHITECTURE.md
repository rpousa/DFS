# 5G Distributed Deployment — Multi-PC Architecture

Physical fabric: three Linux hosts connected through **two managed switches** on
the LAN `192.168.0.0/24`. Switch 1 is the spine between the Core and the
Centraloffice; Switch 2 is the spine between the Centraloffice and the Edge.
All inter-host 5G traffic (NGAP, E1, F1-C, F1-U, E2AP) is published by Docker
on each host's physical IP and transits both switches as needed.

```
                                ┌──────────────────────────────────────────┐
                                │          CORE MACHINE  (core-test-pc)    │
                                │          Host IP: 192.168.0.200          │
                                │                                          │
                                │ ┌──────────────────────────────────────┐ │
                                │ │  5G Core Network Functions           │ │
                                │ │  ────────────────────────────────    │ │
                                │ │  mysql   .131   nrf    .130          │ │
                                │ │  amf     .132   smf    .133          │ │
                                │ │  nssf    .135   udm    .136          │ │
                                │ │  udr     .137   ausf   .138          │ │
                                │ │  pcf     .139                        │ │
                                │ │                                      │ │
                                │ │  cucp    .140   (gNB_ID=0xe00)       │ │
                                │ │  flexric .150                        │ │
                                │ │  upf_core .134 (Slice 1: SST=1/SD=1) │ │
                                │ │  ext_dn_core                         │ │
                                │ └──────────────────────────────────────┘ │
                                │                                          │
                                │ Docker bridges:                          │
                                │   br-core  192.168.71.128/26             │
                                │   br-ext   192.168.72.0/26               │
                                │   br-n3    192.168.100.0/26              │
                                │   br-sgi   172.18.0.0/24                 │
                                │                                          │
                                │ Published on 192.168.0.200:              │
                                │   NGAP  38412/sctp   (amf)               │
                                │   F1-C  38472/sctp   (cucp)              │
                                │   E1    38462/sctp   (cucp)              │
                                │   E2AP  36421/sctp   (flexric)           │
                                │   E2AP  36422/sctp   (flexric)           │
                                │   GTP-U 2152/udp     (upf_core N3)       │
                                │   N4    8805/udp     (smf)               │
                                │   SBI   9090/tcp     (nrf)               │
                                └─────────────────┬────────────────────────┘
                                                  │ eno1 / eth0
                                                  │ 192.168.0.200
                                                  ▼
                    ┌─────────────────────────────────────────────────┐
                    │   SWITCH 1   (Core ↔ Centraloffice spine)       │
                    │   L2 managed switch — untagged 192.168.0.0/24   │
                    │   Carries: NGAP, E1 (Core←CO), F1-C (Core←CO),  │
                    │            E2AP (CO←Core direction returns)     │
                    └─────────────┬───────────────────────────────────┘
                                  │
                                  │ eno1 / eth0
                                  │ 192.168.0.193
                                  ▼
     ┌─────────────────────────────────────────────────────────────────────┐
     │               CENTRALOFFICE MACHINE  (co-test-pc)                   │
     │               Host IP: 192.168.0.193                                │
     │                                                                     │
     │  ┌───────────────────────────────────────────────────────────────┐  │
     │  │  cuup_co   (gNB_CU_UP_ID=0xe01)                               │  │
     │  │     core_net .140   f1u_net .140   n3_net .140                │  │
     │  │     E1  → Core:38462      F1-U ← DU_co (local) + DU_e1 (LAN)  │  │
     │  │     N3  → upf_co (local)                                      │  │
     │  │                                                               │  │
     │  │  upf_co    (Slice 2: SST=1/SD=2)                              │  │
     │  │     core_net .144   ext_net .144                              │  │
     │  │                                                               │  │
     │  │  ext_dn_co                                                    │  │
     │  │     ext_net .135   n3_net .135   sgi_net .9                   │  │
     │  │                                                               │  │
     │  │  du_co     (CellID=11111111, PCI=0)                           │  │
     │  │     f1c_net .141   f1u_net .141   ran_net .10                 │  │
     │  │     core_net .141                                             │  │
     │  │     F1-C → Core:38472      F1-U → cuup_co (local)             │  │
     │  └───────────────────────────────────────────────────────────────┘  │
     │                                                                     │
     │  Docker bridges:                                                    │
     │    br-core 192.168.71.128/26   br-f1c 192.168.73.128/26             │
     │    br-ext  192.168.72.128/26   br-f1u 192.168.74.128/26             │
     │    br-ran  192.168.80.0/26     br-n3  192.168.100.128/26            │
     │    br-sgi  172.18.1.0/24                                            │
     │                                                                     │
     │  Published on 192.168.0.193:                                        │
     │    F1-C     500/sctp   (du_co listener)                             │
     │    F1-U    2153/udp    (cuup_co — from du_co local + du_e1 @ Edge)  │
     │    F1-U    2156/udp    (du_co)                                      │
     │    N3-out  2155/udp    (cuup_co towards upf_co)                     │
     │    GTP-U   2152/udp    (upf_co N3)                                  │
     │    N4      8805/udp    (upf_co)                                     │
     └────────────────────────────────┬────────────────────────────────────┘
                                      │ eno2 (or second LAN port)
                                      │ 192.168.0.193
                                      ▼
                  ┌─────────────────────────────────────────────────┐
                  │   SWITCH 2   (Centraloffice ↔ Edge spine)       │
                  │   L2 managed switch — untagged 192.168.0.0/24   │
                  │   Carries: F1-U (du_e1 → cuup_co@CO:2153)       │
                  │            E2AP (cuup_e/du_e1/du_e2 → flexric   │
                  │            relayed via CO? NO — direct to Core  │
                  │            via Switch 1 in return path)         │
                  └─────────────┬───────────────────────────────────┘
                                │
                                │ eno1 / eth0
                                │ 192.168.0.243
                                ▼
     ┌─────────────────────────────────────────────────────────────────────┐
     │                  EDGE MACHINE  (5GEDGE)                             │
     │                  Host IP: 192.168.0.243                             │
     │                                                                     │
     │  ┌───────────────────────────────────────────────────────────────┐  │
     │  │  cuup_e    (gNB_CU_UP_ID=0xe02)                               │  │
     │  │     core_net .140   f1u_net .40    n3_net .140                │  │
     │  │     E1  → Core:38462      F1-U ← DU_e2 (local)                │  │
     │  │     N3  → upf_e (local)                                       │  │
     │  │                                                               │  │
     │  │  upf_e     (Slice 3: SST=1/SD=3)                              │  │
     │  │     core_net .154   ext_net .154                              │  │
     │  │                                                               │  │
     │  │  ext_dn_e                                                     │  │
     │  │     ext_net .135   n3_net .135   sgi_net .9                   │  │
     │  │                                                               │  │
     │  │  du_e1     (CellID=22222222, PCI=1)                           │  │
     │  │     f1c_net .10   f1u_net .10   ran_net .151                  │  │
     │  │     core_net .151                                             │  │
     │  │     F1-C → Core:38472      F1-U → cuup_co @ CO:2153 ◄──┐      │  │
     │  │                                        (CROSS-MACHINE) │      │  │
     │  │  du_e2     (CellID=33333333, PCI=2)                    │      │  │
     │  │     f1c_net .20   f1u_net .20   ran_net .161           │      │  │
     │  │     core_net .161                                      │      │  │
     │  │     F1-C → Core:38472      F1-U → cuup_e (local)       │      │  │
     │  │                                                        │      │  │
     │  │  ue_1   (10 simulated UEs)                             │      │  │
     │  │     ran_net .168  → rfsim → du_e1 (serverport 4043) ───┘      │  │
     │  └───────────────────────────────────────────────────────────────┘  │
     │                                                                     │
     │  Docker bridges:                                                    │
     │    br-core 192.168.71.128/26   br-f1c 192.168.83.0/26               │
     │    br-ext  192.168.82.128/26   br-f1u 192.168.84.0/26               │
     │    br-ran  192.168.80.128/26   br-n3  192.168.101.128/26            │
     │    br-sgi  172.18.2.0/24                                            │
     │                                                                     │
     │  Published on 192.168.0.243:                                        │
     │    F1-C    500/sctp   (du_e1)                                       │
     │    F1-C    501/sctp   (du_e2)                                       │
     │    F1-U   2153/udp    (cuup_e — from du_e2 local)                   │
     │    F1-U   2156/udp    (du_e1)                                       │
     │    F1-U   2157/udp    (du_e2)                                       │
     │    N3-out 2155/udp    (cuup_e towards upf_e)                        │
     │    GTP-U  2152/udp    (upf_e N3)                                    │
     └─────────────────────────────────────────────────────────────────────┘
```

---

## Docker Bridge Subnet Matrix (verified against YAML)

| Bridge        | Core (.200)            | Centraloffice (.193)     | Edge (.243)              |
| ------------- | ---------------------- | ------------------------ | ------------------------ |
| `br-core`     | `192.168.71.128/26`    | `192.168.71.128/26`      | `192.168.61.128/26`      |
| `br-ext`      | `192.168.72.0/26`      | `192.168.72.128/26`      | `192.168.82.0/26`        |
| `br-f1c`      | —                      | `192.168.73.128/26`      | `192.168.83.0/26`        |
| `br-f1u`      | —                      | `192.168.74.128/26`      | `192.168.84.0/26`        |
| `br-ran`      | —                      | `192.168.80.0/26`        | `192.168.80.128/26`      |
| `br-n3`       | `192.168.100.0/26`     | `192.168.100.128/26`     | `192.168.101.128/26`     |
| `br-sgi`      | `172.18.0.0/24`        | `172.18.1.0/24`          | `172.18.2.0/24`          |

> Note: `e1_net` was in the original table but no compose file defines it. E1
> between CU-UPs and CU-CP rides on `core_net` locally and transits the host
> IP published on `38462/sctp` across machines.

---

## Cross-Machine Control / User-Plane Flows

| Flow                 | Source (IP:port)                       | Destination (IP:port)               | Path                        |
| -------------------- | -------------------------------------- | ----------------------------------- | --------------------------- |
| NGAP                 | cucp `192.168.71.140:eph`              | amf `192.168.71.132:38412`          | local (core_net)            |
| E1 — CO CU-UP        | cuup_co `192.168.0.193:eph`            | **`192.168.0.200:38462/sctp`**      | CO → **SW1** → Core         |
| E1 — Edge CU-UP      | cuup_e `192.168.0.243:eph`             | **`192.168.0.200:38462/sctp`**      | Edge → **SW2 → SW1** → Core |
| F1-C — du_co         | du_co `192.168.0.193:eph`              | **`192.168.0.200:38472/sctp`**      | CO → **SW1** → Core         |
| F1-C — du_e1         | du_e1 `192.168.0.243:eph`              | **`192.168.0.200:38472/sctp`**      | Edge → **SW2 → SW1** → Core |
| F1-C — du_e2         | du_e2 `192.168.0.243:eph`              | **`192.168.0.200:38472/sctp`**      | Edge → **SW2 → SW1** → Core |
| F1-U — du_e1         | du_e1 `192.168.0.243:eph`              | **`192.168.0.193:2153/udp`**        | Edge → **SW2** → CO         |
| F1-U — du_co         | du_co `192.168.74.141`                 | cuup_co `192.168.74.140:2153`       | local (CO f1u_net)          |
| F1-U — du_e2         | du_e2 `192.168.84.20`                  | cuup_e `192.168.84.40:2153`         | local (Edge f1u_net)        |
| E2AP — du_co, cuup_co| CO containers                          | flexric `192.168.71.150:36421-2`    | local (core_net)            |
| E2AP — cucp          | cucp `192.168.71.140`                  | flexric `192.168.71.150:36421-2`    | local (core_net)            |
| E2AP — Edge units    | du_e1/e2, cuup_e `192.168.0.243:eph`   | **`192.168.0.193:36421-2/sctp`***   | Edge → **SW2** → CO         |

> *Note: Edge compose uses `--e2_agent.near_ric_ip_addr 192.168.0.193`, but
> FlexRIC actually runs on **Core** (`192.168.0.200`). This is likely a bug —
> see the notes at the bottom of this document.

---

## Slice / UPF Mapping

| Slice         | SST / SD | UPF        | Served by CU-UP | DUs               |
| ------------- | -------- | ---------- | --------------- | ----------------- |
| Central       | 1 / 1    | `upf_core` | *(anchor only)* | —                 |
| Centraloffice | 1 / 2    | `upf_co`   | `cuup_co`       | `du_co`, `du_e1`  |
| Edge          | 1 / 3    | `upf_e`    | `cuup_e`        | `du_e2`           |

---

## Legend

- **Solid vertical rules** = Docker-bridge / container boundary inside a host
- **Arrows with IP:port** = TCP/UDP/SCTP endpoints actually bound in the compose
  files (verified against `ports:` and `USE_ADDITIONAL_OPTIONS`)
- **SW1 / SW2** = physical L2 managed switches on the 192.168.0.0/24 fabric
- **`eph`** = ephemeral source port chosen by kernel
