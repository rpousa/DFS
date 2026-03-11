# Two-Machine 5G Network Deployment Architecture

## Overview

This deployment splits the 5G network across two physical machines for a distributed architecture with edge computing capabilities.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        MACHINE 1: 192.168.0.193                         │
│                    Core Network + Central RAN                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                     5G Core Network                               │  │
│  │  MySQL  NRF  AMF  SMF  UDM  UDR  AUSF  PCF  NSSF                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │              Primary User Plane                                   │  │
│  │  UPF (192.168.71.134) ←→ Ext DN (192.168.72.135)                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │              Central RAN Components                               │  │
│  │  CU-CP (192.168.71.140)  ← Control Plane                         │  │
│  │  CU-UP (192.168.71.143)  ← User Plane (Primary)                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                │ F1, E1, N2, N3 Interfaces
                                │
┌───────────────────────────────┴─────────────────────────────────────────┐
│                        MACHINE 2: 192.168.0.243                         │
│                  Edge RAN + Edge UPF + UEs                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │              Edge User Plane (Local Breakout)                     │  │
│  │  UPF_1 (192.168.71.160) ←→ Ext DN_1 (192.168.72.161)            │  │
│  │  Pool: 12.2.1.0/24, 13.2.1.0/24                                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │              Edge RAN Components                                  │  │
│  │  CU-UP_1 (192.168.71.144) ← Edge User Plane                      │  │
│  │  DU (192.168.80.151)       ← RFSimulator Server                  │  │
│  │  FlexRIC (192.168.71.150)  ← Near-RT RIC                         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │              10 User Equipment (RFSimulator)                      │  │
│  │  UE1-10 (192.168.80.170) ← Connects to DU                        │  │
│  │  Interfaces: oaitun_ue1 through oaitun_ue10                      │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Distribution

### Machine 1 (192.168.0.193) - Core + Central RAN

| Component | IP | Port(s) | Purpose |
|-----------|-------|---------|---------|
| **Core Network** |
| MySQL | 192.168.71.131 | 3306 | Subscriber database |
| NRF | 192.168.71.130 | 8080, 9090 | Network Repository Function |
| AMF | 192.168.71.132 | 38412, 9094 | Access and Mobility Mgmt |
| SMF | 192.168.71.133 | 8805, 9091 | Session Management |
| UDM | 192.168.71.136 | 9095 | Unified Data Management |
| UDR | 192.168.71.137 | 9096 | Unified Data Repository |
| AUSF | 192.168.71.138 | 9097 | Authentication Server |
| PCF | 192.168.71.139 | 9092 | Policy Control Function |
| NSSF | 192.168.71.135 | 9093 | Network Slice Selection |
| **User Plane** |
| UPF | 192.168.71.134 | 2152, 8805 | Primary User Plane Function |
| Ext DN | 192.168.72.135 | - | External Data Network |
| **Central RAN** |
| CU-CP | 192.168.71.140 | 38472 | Control Plane (connects to AMF) |
| CU-UP | 192.168.71.143 | 2153 | User Plane (connects to UPF) |

### Machine 2 (192.168.0.243) - Edge RAN + UEs

| Component | IP | Port(s) | Purpose |
|-----------|-------|---------|---------|
| **Edge User Plane** |
| UPF_1 | 192.168.71.160 | 2154, 8815 | Edge User Plane (local breakout) |
| Ext DN_1 | 192.168.72.161 | - | Edge Data Network |
| **Edge RAN** |
| CU-UP_1 | 192.168.71.144 | 2155 | Edge User Plane (local processing) |
| DU | 192.168.80.151 | 4043 | Distributed Unit (RFSim server) |
| FlexRIC | 192.168.71.150 | 36422 | Near-RT RIC |
| **User Equipment** |
| UE (10x) | 192.168.80.170 | - | 10 UEs in single container |

## Network Interfaces

### Docker Networks

| Network | Subnet | Purpose |
|---------|--------|---------|
| core_net | 192.168.71.128/26 | Core network signaling |
| ext_net | 192.168.72.128/26 | External data network |
| f1c_net | 192.168.73.128/26 | F1-C (Control plane) |
| f1u_net | 192.168.74.128/26 | F1-U (User plane) |
| e1_net | 192.168.75.128/26 | E1 (CU-CP ↔ CU-UP) |
| ran_net | 192.168.80.128/26 | RAN (DU ↔ UE) |

### 3GPP Interfaces

| Interface | Between | Protocol | Port | Machine |
|-----------|---------|----------|------|---------|
| **N2** | AMF ↔ CU-CP | NGAP | 38412 | M1 → M1 |
| **N3** | UPF ↔ CU-UP | GTP-U | 2152 | M1 → M1 |
| **N3 (Edge)** | UPF_1 ↔ CU-UP_1 | GTP-U | 2154 | M2 → M2 |
| **N4** | SMF ↔ UPF | PFCP | 8805 | M1 → M1 |
| **N4 (Edge)** | SMF ↔ UPF_1 | PFCP | 8815 | M1 → M2 |
| **F1-C** | CU-CP ↔ DU | F1AP | 38472 | M1 → M2 |
| **F1-U** | CU-UP ↔ DU | GTP-U | 2153 | M1 → M2 |
| **F1-U (Edge)** | CU-UP_1 ↔ DU | GTP-U | 2155 | M2 → M2 |
| **E1** | CU-CP ↔ CU-UP | E1AP | - | M1 → M1 |
| **E1 (Edge)** | CU-CP ↔ CU-UP_1 | E1AP | - | M1 → M2 |
| **E2** | gNB ↔ FlexRIC | E2AP | 36422 | M2 → M2 |
| **RFSim** | DU ↔ UE | TCP | 4043 | M2 → M2 |

## Deployment Sequence

### 1. Deploy Machine 1 First

```bash
# On Machine 1 (192.168.0.193)
cd /path/to/deployment
./deploy-machine1.sh
```

**Startup order:**
1. MySQL (wait for healthy)
2. Core Network Functions (NRF, AMF, SMF, etc.)
3. Primary UPF + Ext DN
4. CU-CP (connects to AMF)
5. CU-UP (connects to CU-CP and UPF)

**Verification:**
- Check AMF port 38412 is listening (for Machine 2)
- Verify NRF is responding
- Check CU-CP connected to AMF

### 2. Deploy Machine 2 Second

```bash
# On Machine 2 (192.168.0.243)
cd /path/to/deployment
./deploy-machine2.sh
```

**Startup order:**
1. Edge UPF_1 + Ext DN_1
2. Edge CU-UP_1 (connects to CU-CP on M1)
3. DU (RFSimulator server, connects to CU-CP on M1)
4. FlexRIC
5. UE (10 instances, connect to DU)
6. Wait for UE registration and IP assignment

**Verification:**
- Check connectivity to Machine 1 Core
- Verify DU RFSimulator server listening
- Check UE connections (oaitun_ue1-10)
- Test UE connectivity

## Traffic Flows

### UE Data Traffic (Edge Breakout)

```
UE → DU → CU-UP_1 → UPF_1 → Ext DN_1 → Internet
(M2)  (M2)   (M2)     (M2)     (M2)     (M2)
```

**Advantages:**
- All data stays on Machine 2
- Low latency (no cross-machine traffic)
- Ideal for edge computing scenarios

### UE Data Traffic (Central UPF)

```
UE → DU → CU-UP → UPF → Ext DN → Internet
(M2)  (M2)  (M1)   (M1)   (M1)    (M1)
```

**Cross-machine traffic:**
- F1-U: M2 → M1 (DU to CU-UP)
- N3: M1 (CU-UP to UPF)

### Control Signaling

```
UE → DU → CU-CP → AMF → Core Network
(M2)  (M2)  (M1)    (M1)   (M1)
```

**Cross-machine traffic:**
- F1-C: M2 → M1 (DU to CU-CP)
- N2: M1 (CU-CP to AMF)

## Configuration Files

### Machine 1 Files

```
deployment/
├── docker-compose-machine1.yml
├── deploy-machine1.sh
├── configs/
│   ├── nrf/config.yaml
│   ├── amf/config.yaml
│   ├── smf/config.yaml
│   ├── upf/config.yaml
│   ├── cucp/gnb-cucp.sa.f1.conf
│   └── cuup/gnb-cuup.sa.f1.conf
└── logs/
    ├── nrf/
    ├── amf/
    └── ...
```

### Machine 2 Files

```
deployment/
├── docker-compose-machine2.yml
├── deploy-machine2.sh
├── configs/
│   ├── upf_1/config.yaml
│   ├── cuup_1/gnb-cuup.sa.f1.conf
│   ├── du_1/gnb-du.sa.band78.106prb.rfsim.conf
│   └── flexric/
├── ue_volumes/
│   └── nrue_multi.conf  # 10 UE configs
└── logs/
    ├── du_1/
    ├── ue_1/
    └── ...
```

## Resource Requirements

### Machine 1 (Core + Central RAN)

- **CPU**: 8+ cores (16 recommended)
- **RAM**: 16 GB minimum (32 GB recommended)
- **Disk**: 50 GB
- **Network**: 1 Gbps

**Services**: 14 containers (Core: 12, RAN: 2)

### Machine 2 (Edge RAN + UEs)

- **CPU**: 4+ cores (8 recommended)
- **RAM**: 8 GB minimum (16 GB recommended)
- **Disk**: 30 GB
- **Network**: 1 Gbps

**Services**: 6 containers (Edge UPF: 2, RAN: 3, UE: 1 with 10 UEs)

## Network Requirements

### Physical Network

- Both machines on same L2 network (192.168.0.0/24)
- Low latency between machines (< 10 ms preferred)
- Sufficient bandwidth for F1, E1 interfaces

### Firewall Rules

**Machine 1 must allow inbound from Machine 2:**
- TCP/UDP 38412 (AMF NGAP)
- TCP 8080 (NRF HTTP)
- TCP/UDP 38472 (F1-C)
- UDP 2152, 2153 (GTP-U)

**Machine 2 must allow outbound to Machine 1:**
- All ports above

## Monitoring and Debugging

### Check Machine 1 Status

```bash
# Service status
docker-compose -f docker-compose-machine1.yml ps

# Check AMF (should see NG Setup from CU-CP)
docker logs amf | grep -i "ng setup"

# Check CU-CP (should see connection to DU)
docker logs cucp | grep -i "f1 setup"

# Check NRF registrations
curl http://localhost:8080/nnrf-nfm/v1/nf-instances
```

### Check Machine 2 Status

```bash
# Service status
docker-compose -f docker-compose-machine2.yml ps

# Check DU (should see RFSim connections)
docker logs du_1 | grep -i "client connected"

# Check UE attachments
docker logs ue_1 | grep -i "attach\|pdu\|registration"

# Check UE interfaces
docker exec ue_1 ip addr show | grep oaitun

# Test connectivity
docker exec ue_1 ping -I oaitun_ue1 -c 3 192.168.72.161
```

### Cross-Machine Connectivity Tests

```bash
# From Machine 2, test Machine 1 services
ping -c 3 192.168.0.193
telnet 192.168.0.193 38412  # AMF
curl http://192.168.0.193:8080/nnrf-nfm/v1/nf-instances  # NRF
```

## Advantages of This Architecture

### Edge Computing
- ✅ Local data processing on Machine 2
- ✅ Reduced latency for local UEs
- ✅ Local breakout via Edge UPF

### Scalability
- ✅ Easy to add more edge sites (Machine 2 clones)
- ✅ Core network centralized (Machine 1)
- ✅ Independent scaling of core and edge

### Flexibility
- ✅ UEs can use either Primary UPF or Edge UPF
- ✅ Support for network slicing
- ✅ FlexRIC for RAN intelligence

### Testing
- ✅ Test distributed 5G architecture
- ✅ Simulate real-world deployment
- ✅ Evaluate edge computing scenarios

## Troubleshooting

### Machine 2 Can't Connect to Machine 1

**Symptoms:**
- CU-CP can't connect to AMF
- DU can't connect to CU-CP

**Solutions:**
1. Check network connectivity: `ping 192.168.0.193`
2. Check firewall: `sudo ufw status`
3. Verify AMF listening: `ss -tlnp | grep 38412`
4. Check routing: `ip route show`

### UEs Not Getting IP Addresses

**Symptoms:**
- oaitun_ue interfaces created but no IP
- PDU session establishment fails

**Solutions:**
1. Check SMF logs: `docker logs smf | grep -i "pdu\|session"`
2. Check UPF_1 logs: `docker logs upf_1 | grep -i "session"`
3. Verify UE IMSI in database
4. Check SMF → UPF_1 connectivity

### Performance Issues

**Symptoms:**
- High latency
- Packet loss
- Low throughput

**Solutions:**
1. Check CPU usage: `top` or `htop`
2. Check network bandwidth: `iperf3`
3. Reduce number of UEs if needed
4. Check Docker network MTU settings

## Summary

This two-machine deployment provides:
- **Machine 1**: Complete 5G Core + Central CU-CP + Primary CU-UP
- **Machine 2**: Edge infrastructure with local UPF, DU, and 10 UEs

Perfect for testing distributed 5G networks, edge computing, and multi-access edge computing (MEC) scenarios!
