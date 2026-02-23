# Multi-PC 5G Network Deployment Architecture

## Overview

This deployment distributes the 5G network across multiple physical PCs using the 192.168.0.x physical network, with virtual networks for 5G components.

## Physical Network Layout

```
Physical Network: 192.168.0.x/24

┌─────────────────────────────────────────────────────────────────┐
│                    Physical LAN (192.168.0.x)                    │
│                                                                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   PC 1      │  │   PC 2      │  │   PC 3      │             │
│  │ .193 (Core) │  │ .200 (GW)   │  │ .243 (RAN)  │             │
│  │             │  │             │  │             │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
└─────────────────────────────────────────────────────────────────┘
                              │
                         Internet via GW
```

## Deployment Scenarios

### Scenario 1: Core on PC1, RAN on PC2/PC3
- **PC 192.168.0.193**: Core Network Functions (NRF, AMF, SMF, UPF, etc.)
- **PC 192.168.0.200**: Gateway + potentially some functions
- **PC 192.168.0.243**: RAN Components (CU-CP, CU-UP, DU, UE)

### Scenario 2: All on Gateway PC (Development)
- **PC 192.168.0.200**: All components for testing

### Scenario 3: Distributed RAN
- **PC 192.168.0.193**: Core Network
- **PC 192.168.0.200**: Gateway + CU-CP + CU-UP
- **PC 192.168.0.243**: DU + UE + L2 Proxy

## Network Architecture

### Virtual Networks (Internal to each PC)

Each PC runs Docker with internal virtual networks:

```yaml
# On Core PC (192.168.0.193)
core_net: 192.168.71.0/26
ext_net: 192.168.72.0/26

# On RAN PC (192.168.0.243)  
ran_net: 192.168.80.0/26
```

### Cross-PC Communication

Components on different PCs communicate via:
1. **Physical network** (192.168.0.x)
2. **Port forwarding** on Docker containers
3. **Host network mode** for some RAN components

## IP Address Mapping

### Core Network Functions (PC 192.168.0.193)
| Component | Virtual IP     | Physical Access        |
|-----------|----------------|------------------------|
| MySQL     | 192.168.71.131 | 192.168.0.193:3306     |
| NRF       | 192.168.71.130 | 192.168.0.193:8080     |
| AMF       | 192.168.71.132 | 192.168.0.193:38412    |
| SMF       | 192.168.71.133 | 192.168.0.193:8805     |
| PCF       | 192.168.71.139 | 192.168.0.193:8806     |
| NSSF      | 192.168.71.135 | 192.168.0.193:8807     |
| UDM       | 192.168.71.136 | 192.168.0.193:8808     |
| UDR       | 192.168.71.137 | 192.168.0.193:8809     |
| AUSF      | 192.168.71.138 | 192.168.0.193:8810     |
| UPF       | 192.168.71.134 | 192.168.0.193:8805     |

### RAN Components (PC 192.168.0.243)
| Component | Virtual IP     | Physical Access        |
|-----------|----------------|------------------------|
| CU-CP     | 192.168.71.140 | 192.168.0.243:38472    |
| CU-UP     | 192.168.71.143 | 192.168.0.243:38462    |
| DU        | 192.168.80.151 | 192.168.0.243:2152     |
| L2 Proxy  | 192.168.80.163 | 192.168.0.243:7878     |
| UE        | 192.168.80.170 | 192.168.0.243:n/a      |
| FlexRIC   | 192.168.71.150 | 192.168.0.243:36422    |

## Communication Requirements

### Core ↔ RAN Communication

1. **AMF (Core PC) ↔ CU-CP (RAN PC)**
   - Protocol: NGAP (N2 interface)
   - Port: 38412 (AMF listening)
   
2. **SMF (Core PC) ↔ UPF (Core PC) ↔ CU-UP (RAN PC)**
   - Protocol: PFCP, GTP-U
   - Ports: 8805, 2152

3. **CU-CP ↔ CU-UP ↔ DU**
   - Protocol: E1AP, F1AP
   - Within RAN PC or cross-PC via physical network

## Configuration Changes Needed

### 1. Core Components (Point to Physical IPs)

All core components must accept connections from RAN PC's physical IP (192.168.0.243):

```yaml
# AMF config example
amf:
  ngap:
    bind_addr: 0.0.0.0  # Listen on all interfaces
    port: 38412
  # Allow connections from RAN PC
  allowed_nssai:
    - sst: 1
      sd: 0x000001
```

### 2. RAN Components (Point to Core PC Physical IP)

RAN components must connect to core functions via physical IP (192.168.0.193):

```yaml
# CU-CP config example
cucp:
  amf_addr: 192.168.0.193  # Physical IP of Core PC
  amf_port: 38412
```

### 3. Docker Compose Port Exposure

Each PC's docker-compose must expose necessary ports to the physical network.

## Files Generated

I'll create:
1. **docker-compose-core.yml** - For Core PC (192.168.0.193)
2. **docker-compose-ran.yml** - For RAN PC (192.168.0.243)
3. **docker-compose-allinone.yml** - For single PC deployment
4. **Multi-PC setup scripts**
5. **Configuration templates** with correct IP mappings
6. **Network routing setup** between PCs

## Prerequisites

- All PCs on same physical network (192.168.0.x)
- Gateway PC (192.168.0.200) configured with network-setup scripts
- Docker installed on all PCs
- Same Docker images available on all PCs
