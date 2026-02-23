# Multi-PC 5G Network Deployment Guide

## Overview

This guide shows how to deploy a 5G network across multiple physical PCs using the existing 192.168.0.x network.

## Physical Setup

```
192.168.0.x Physical Network
│
├── PC1 (192.168.0.193) - Core Network Functions
│   ├── MySQL, NRF, AMF, SMF, PCF, NSSF
│   ├── UDM, UDR, AUSF
│   └── UPF, External DN
│
├── PC2 (192.168.0.200) - Gateway (Already configured)
│   └── Internet gateway + DNS + routing
│
└── PC3 (192.168.0.243) - RAN Components
    ├── CU-CP, CU-UP
    ├── DU, L2 Proxy
    ├── UE
    └── FlexRIC
```

## Prerequisites

### All PCs Must Have:
1. Docker and Docker Compose installed
2. Network connectivity on 192.168.0.x
3. Gateway configured (PC 192.168.0.200)
4. All required Docker images
5. Ubuntu 22.04 or 23.04

### Network Requirements:
- Gateway PC must be running (192.168.0.200)
- All PCs can ping each other
- No firewall blocking Docker ports
- Sufficient bandwidth between PCs (1Gbps+ recommended)

## Step-by-Step Deployment

### Step 1: Configure Network on All PCs

#### On Core PC (192.168.0.193)
```bash
# Run client setup script (from network setup)
chmod +x client-setup.sh
sudo ./client-setup.sh 192.168.0.200

# Verify connectivity
ping 192.168.0.200  # Gateway
ping 192.168.0.243  # RAN PC
```

#### On RAN PC (192.168.0.243)
```bash
# Run client setup script
chmod +x client-setup.sh
sudo ./client-setup.sh 192.168.0.200

# Verify connectivity
ping 192.168.0.200  # Gateway
ping 192.168.0.193  # Core PC
```

### Step 2: Prepare Docker Images

**On Both Core and RAN PCs:**

```bash
# Option 1: Build locally on each PC
# (Follow OAI build instructions)

# Option 2: Save and transfer images
# On PC where images are built:
docker save mysql:comnetsemu nrf:comnetsemu amf:comnetsemu > core-images.tar
docker save cucp:comnetsemu du:comnetsemu ue:comnetsemu > ran-images.tar

# Transfer to target PCs
scp core-images.tar user@192.168.0.193:~/
scp ran-images.tar user@192.168.0.243:~/

# On target PCs:
docker load < core-images.tar
docker load < ran-images.tar

# Option 3: Use a local registry
# On gateway PC:
docker run -d -p 5000:5000 --name registry registry:2
# Then push/pull images via 192.168.0.200:5000
```

### Step 3: Configure Firewall Rules

**On Core PC (192.168.0.193):**

```bash
# Allow RAN PC to access core services
sudo ufw allow from 192.168.0.243 to any port 38412  # AMF NGAP
sudo ufw allow from 192.168.0.243 to any port 8805   # PFCP
sudo ufw allow from 192.168.0.243 to any port 2152   # GTP-U
sudo ufw allow from 192.168.0.243 to any port 8080   # NRF HTTP

# Or disable firewall for testing
sudo ufw disable
```

**On RAN PC (192.168.0.243):**

```bash
# Allow Core PC to communicate with RAN
sudo ufw allow from 192.168.0.193
sudo ufw allow from 192.168.0.200

# Or disable firewall for testing
sudo ufw disable
```

### Step 4: Prepare Configuration Files

#### Core PC (192.168.0.193)

Create directory structure:
```bash
mkdir -p ~/5g-core
cd ~/5g-core
mkdir -p configs/{mysql,nrf,amf,smf,pcf,nssf,udm,udr,ausf,upf,upf_1,ext_dn,ext_dn_1}
mkdir -p logs/{mysql,nrf,amf,smf,pcf,nssf,udm,udr,ausf,upf,upf_1,ext_dn,ext_dn_1}

# Copy docker-compose file
cp docker-compose-core.yml ~/5g-core/docker-compose.yml
```

**Critical: Update AMF config** (`configs/amf/config.yaml`):
```yaml
amf:
  # ... other config ...
  n2:
    bind_addr: 0.0.0.0           # Listen on all interfaces
    port: 38412
  # Point to physical IPs
  nrf_addr: http://192.168.0.193:8080
```

**Critical: Update CU-CP config to point to physical AMF IP**

#### RAN PC (192.168.0.243)

Create directory structure:
```bash
mkdir -p ~/5g-ran
cd ~/5g-ran
mkdir -p configs/{cucp,cuup,du_1,ue_1,flexric,l2_proxy}
mkdir -p logs/{cucp,cuup,du_1,ue_1,flexric,l2_proxy}
mkdir -p xapps

# Copy docker-compose file
cp docker-compose-ran.yml ~/5g-ran/docker-compose.yml
```

**Critical: Update CU-CP config** (`configs/cucp/gnb.conf`):
```conf
Active_gNBs = ( "gNB-OAI");

gNBs = ({
    gNB_ID = 0xe00;
    gNB_name  = "gNB-OAI";
    
    # Point to Core PC physical IP
    amf_ip_address = ({
        ipv4       = "192.168.0.193";    # <-- Physical IP of Core PC
        ipv6       = "::";
        port       = 38412;
    });
    
    # ... rest of config ...
});
```

### Step 5: Deploy Core Network

**On Core PC (192.168.0.193):**

```bash
cd ~/5g-core

# Start core functions in stages
echo "Starting MySQL..."
docker-compose up -d mysql
sleep 10

echo "Starting Core NFs..."
docker-compose up -d nrf smf pcf nssf amf udm udr ausf
sleep 15

echo "Starting UPF..."
docker-compose up -d upf ext_dn upf_1 ext_dn_1
sleep 10

# Verify all services are running
docker-compose ps

# Check AMF is listening on physical interface
sudo netstat -tulpn | grep 38412

# Check logs
docker-compose logs -f amf
```

### Step 6: Deploy RAN Components

**On RAN PC (192.168.0.243):**

```bash
cd ~/5g-ran

# Start RAN components in stages
echo "Starting CU-CP..."
docker-compose up -d cucp
sleep 15

echo "Starting CU-UP..."
docker-compose up -d cuup
sleep 15

echo "Starting DU..."
docker-compose up -d du_1
sleep 15

echo "Starting FlexRIC..."
docker-compose up -d flexric
sleep 10

echo "Starting L2 Proxy..."
docker-compose up -d l2_proxy
sleep 10

echo "Starting UE..."
docker-compose up -d ue_1
sleep 15

# Verify
docker-compose ps

# Check connectivity to Core PC
docker exec cucp ping -c 3 192.168.0.193
```

### Step 7: Verification

#### Check Core PC (192.168.0.193)

```bash
# Check all services running
docker ps

# Check AMF registered gNB
docker logs amf | grep -i "gnb"

# Check NRF registrations
curl http://192.168.0.193:8080/nnrf-nfm/v1/nf-instances

# Check connectivity from RAN PC
docker logs amf | grep "192.168.0.243"
```

#### Check RAN PC (192.168.0.243)

```bash
# Check CU-CP connected to AMF
docker logs cucp | grep -i "amf"

# Check UE attached
docker logs ue_1 | grep -i "attach"

# Check if UE has IP
docker exec ue_1 ip addr show oaitun_ue1

# Test UE connectivity
docker exec ue_1 ping -I oaitun_ue1 192.168.0.200
```

## Troubleshooting

### Core PC Cannot Be Reached from RAN PC

```bash
# On Core PC
sudo ufw status  # Check firewall
sudo netstat -tulpn | grep 38412  # Check AMF listening

# Test from RAN PC
telnet 192.168.0.193 38412

# Check routing
ip route show
```

### AMF Not Receiving Connection from CU-CP

1. **Check AMF config**: Must bind to 0.0.0.0
2. **Check CU-CP config**: Must point to 192.168.0.193
3. **Check firewall**: Port 38412 must be open
4. **Check Docker port mapping**: `-p 192.168.0.193:38412:38412`

```bash
# On Core PC
docker logs amf -f  # Watch for incoming connections

# On RAN PC  
docker logs cucp -f  # Watch for AMF connection attempts
```

### UE Cannot Get IP Address

```bash
# Check full chain:
# 1. DU connected to CU-CP
docker logs du_1 | grep "F1AP"

# 2. CU-CP connected to AMF
docker logs cucp | grep "NGAP"

# 3. AMF connected to SMF
docker logs amf | grep "SMF"

# 4. SMF connected to UPF
docker logs smf | grep "UPF"

# 5. Check UPF routes
docker exec upf ip route show
```

### Cross-PC Communication Issues

```bash
# Verify basic connectivity
ping 192.168.0.193  # From RAN PC
ping 192.168.0.243  # From Core PC

# Check if Docker ports are exposed
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep 38412

# Capture traffic to debug
sudo tcpdump -i any port 38412 -n

# Check Docker network
docker network inspect 5g-core_core_net  # On Core PC
docker network inspect 5g-ran_core_net   # On RAN PC
```

## Performance Considerations

### Network Latency
- Physical network latency matters
- Use `ping` to measure: should be <1ms on local network
- For production, consider dedicated network interfaces

### Bandwidth
- 5G generates significant traffic
- Monitor with `iftop` or `nethogs`
- Consider bonded interfaces for high throughput

### Resource Allocation
- **Core PC**: Needs more CPU for control plane
- **RAN PC**: Needs more CPU for signal processing
- Allocate 8GB+ RAM per PC minimum

## Monitoring

### Core PC Monitoring

```bash
# Resource usage
docker stats

# Service status
docker-compose ps

# Key logs
docker logs -f amf    # Control plane
docker logs -f smf    # Session management
docker logs -f upf    # Data plane
```

### RAN PC Monitoring

```bash
# Resource usage
docker stats

# RAN status
docker logs -f cucp   # RAN control
docker logs -f du_1   # Radio interface
docker logs -f ue_1   # User equipment
```

## Scaling

### Adding More DUs

1. Copy `du_1` configuration
2. Update IP addresses (192.168.71.152, 192.168.80.152, etc.)
3. Add to `docker-compose-ran.yml`
4. Restart RAN services

### Adding More UEs

1. Copy `ue_1` configuration
2. Update IMSI/credentials
3. Update IP (192.168.80.171, etc.)
4. Add to compose file

### Multiple RAN PCs

Deploy additional PCs (e.g., 192.168.0.244) with same RAN compose file but different IPs.

## Production Considerations

1. **Persistent Storage**: Use Docker volumes for MySQL and configs
2. **Monitoring**: Deploy Prometheus + Grafana
3. **Logging**: Centralize logs with ELK stack
4. **Backup**: Regular backup of configurations
5. **Security**: Enable firewalls, use TLS where possible
6. **High Availability**: Replicate core functions

## Quick Reference

### Port Matrix

| Service | PC | Port | Protocol | Purpose |
|---------|-----|------|----------|---------|
| MySQL | .193 | 3306 | TCP | Database |
| NRF | .193 | 8080 | TCP | Service discovery |
| AMF | .193 | 38412 | SCTP | N2 interface |
| SMF | .193 | 8805 | UDP | PFCP |
| UPF | .193 | 2152 | UDP | GTP-U |
| CU-CP | .243 | 38472 | SCTP | F1AP |
| CU-UP | .243 | 38462 | SCTP | E1AP |

### IP Address Summary

| Component | Virtual IP | Physical Access |
|-----------|-----------|-----------------|
| AMF | 192.168.71.132 | 192.168.0.193:38412 |
| NRF | 192.168.71.130 | 192.168.0.193:8080 |
| CU-CP | 192.168.71.140 | 192.168.0.243:38472 |

### Essential Commands

```bash
# Start everything
# On Core PC: docker-compose up -d
# On RAN PC: docker-compose up -d

# Stop everything
# On RAN PC first: docker-compose down
# Then Core PC: docker-compose down

# Check status
docker-compose ps
docker logs -f <service>

# Test UE
docker exec ue_1 ping -I oaitun_ue1 8.8.8.8
```

## Next Steps

- Set up monitoring (Prometheus/Grafana)
- Add more UEs for load testing
- Configure QoS policies
- Implement network slicing
- Add more DUs for coverage
