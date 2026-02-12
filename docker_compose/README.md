# 5G Network Emulation with Docker Compose
(Claude assisted project building)
This project provides a Docker Compose-based setup for a complete 5G network emulation using Open Air Interface (OAI) components.

## Architecture Overview

The setup includes:

### 5G Core Network (5GC)
- **NRF** (Network Repository Function) - Service discovery
- **AMF** (Access and Mobility Management Function) - Connection and mobility management
- **SMF** (Session Management Function) - Session management
- **PCF** (Policy Control Function) - Policy framework
- **NSSF** (Network Slice Selection Function) - Network slicing
- **UDM** (Unified Data Management) - Subscription data
- **UDR** (Unified Data Repository) - Data repository
- **AUSF** (Authentication Server Function) - Authentication
- **UPF** (User Plane Function) - User plane data forwarding
- **MySQL** - Database for subscriber information

### Radio Access Network (RAN)
- **CU-CP** (Central Unit - Control Plane) - RAN control plane
- **CU-UP** (Central Unit - User Plane) - RAN user plane  
- **DU** (Distributed Unit) - Lower layer RAN functions
- **L2 Proxy** - Layer 2 proxy for RF simulation

### Additional Components
- **FlexRIC** - Near-RT RAN Intelligent Controller
- **UE** (User Equipment) - Simulated mobile device
- **External DN** - External Data Network

## Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    5G Core Network                          │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐             │
│  │  NRF   │  │  AMF   │  │  SMF   │  │  UPF   │             │
│  └────────┘  └────────┘  └────────┘  └────────┘             │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐             │
│  │  PCF   │  │  NSSF  │  │  UDM   │  │  UDR   │             │
│  └────────┘  └────────┘  └────────┘  └────────┘             │
│  ┌────────┐  ┌────────┐                                     │
│  │  AUSF  │  │  MySQL │                                     │
│  └────────┘  └────────┘                                     │
└──────────────────┬──────────────────────────────────────────┘
                   │
┌──────────────────┴──────────────────────────────────────────┐
│                Radio Access Network                         │
│  ┌────────┐  ┌────────┐  ┌────────┐                         │
│  │  CU-CP │──│ CU-UP  │──│   DU   │                         │
│  └────────┘  └────────┘  └────┬───┘                         │
│                                │                            │
│  ┌────────┐                    │                            │
│  │FlexRIC │                    │                            │
│  └────────┘                    │                            │
└────────────────────────────────┼────────────────────────────┘
                                 │
                          ┌──────┴──────┐
                          │  L2 Proxy   │
                          └──────┬──────┘
                                 │
                          ┌──────┴──────┐
                          │     UE      │
                          └─────────────┘
```

## Networks

Three isolated Docker networks are created:

1. **core_net** (192.168.71.0/26) - 5G Core functions
2. **ext_net** (192.168.72.0/26) - External data network
3. **ran_net** (192.168.80.0/26) - Radio Access Network

## Prerequisites

1. **Docker** (version 20.10 or higher)
2. **Docker Compose** (version 2.0 or higher)
3. **Sufficient system resources**:
   - Minimum 16GB RAM (32GB recommended)
   - 50GB free disk space
   - Multi-core CPU (8+ cores recommended)

### System Configuration

Enable IPv6 and configure kernel parameters:

```bash
# Enable IPv6
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0

# Increase file descriptor limits
sudo sysctl -w fs.file-max=2097152
sudo sysctl -w fs.nr_open=2097152

# Network tuning
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728

# Make changes persistent
sudo tee -a /etc/sysctl.conf <<EOF
net.ipv6.conf.all.disable_ipv6=0
fs.file-max=2097152
fs.nr_open=2097152
net.core.rmem_max=134217728
net.core.wmem_max=134217728
EOF
```

## Directory Structure

Create the following directory structure:

```
.
├── docker-compose.yml
├── README.md
├── configs/
│   ├── mysql/
│   │   └── oai_db.sql
│   ├── nrf/
│   │   └── config.yaml
│   ├── amf/
│   │   └── config.yaml
│   ├── smf/
│   │   └── config.yaml
│   ├── pcf/
│   │   └── config.yaml
│   ├── nssf/
│   │   └── config.yaml
│   ├── udm/
│   │   └── config.yaml
│   ├── udr/
│   │   └── config.yaml
│   ├── ausf/
│   │   └── config.yaml
│   ├── upf/
│   │   └── config.yaml
│   ├── upf_1/
│   │   └── config.yaml
│   ├── ext_dn/
│   │   └── trfgen_entrypoint.sh
│   ├── ext_dn_1/
│   │   └── trfgen_entrypoint.sh
│   ├── cucp/
│   │   └── gnb.conf
│   ├── cuup/
│   │   └── gnb.conf
│   ├── du_1/
│   │   └── gnb.conf
│   ├── ue_1/
│   │   └── ue.conf
│   ├── flexric/
│   │   └── flexric.conf
│   └── l2_proxy/
│       └── proxy
├── logs/
│   └── (subdirectories for each component)
└── xapps/
    └── (xApp applications)
```

## Building Docker Images

Before running the compose file, you need to build the required Docker images. These should be tagged as:

- `mysql:comnetsemu`
- `nrf:comnetsemu`
- `amf:comnetsemu`
- `smf:comnetsemu`
- `pcf:comnetsemu`
- `nssf:comnetsemu`
- `udm:comnetsemu`
- `udr:comnetsemu`
- `ausf:comnetsemu`
- `upf_1:comnetsemu`
- `ext_dn:comnetsemu`
- `cucp:comnetsemu`
- `cuup:comnetsemu`
- `du:comnetsemu`
- `ue:comnetsemu`
- `flexric:comnetsemu`
- `l2_proxy:comnetsemu`

Refer to the OAI documentation for building these images:
https://github.com/rpousa/OAI_EWOC.git

## Configuration Files

You need to prepare configuration files for each component. Example templates should be placed in the `configs/` directory. These configurations must be customized for your specific setup.

### Key Configuration Parameters

Each component's config file needs to reference the correct IP addresses from the docker-compose.yml:

- **Core network**: 192.168.71.x
- **External network**: 192.168.72.x
- **RAN network**: 192.168.80.x

## Usage

### 1. Prepare Configuration Files

```bash
# Create directory structure
mkdir -p configs/{mysql,nrf,amf,smf,pcf,nssf,udm,udr,ausf,upf,upf_1,ext_dn,ext_dn_1,cucp,cuup,du_1,ue_1,flexric,l2_proxy}
mkdir -p logs xapps

# Add your configuration files to each configs/ subdirectory
# Make sure scripts are executable
chmod +x configs/ext_dn/trfgen_entrypoint.sh
chmod +x configs/ext_dn_1/trfgen_entrypoint.sh
chmod +x configs/l2_proxy/proxy
```

### 2. Start the Network

```bash
# Start all services
docker-compose up -d

# Watch logs for all services
docker-compose logs -f

# Or watch specific service
docker-compose logs -f amf
```

### 3. Start Services in Stages (Recommended)

For better control over startup sequence:

```bash
# Stage 1: Start MySQL and wait for it to be ready
docker-compose up -d mysql
sleep 10

# Stage 2: Start core network functions
docker-compose up -d nrf smf pcf nssf amf udm udr ausf
sleep 15

# Stage 3: Start UPF and external DN
docker-compose up -d upf ext_dn upf_1 ext_dn_1
sleep 10

# Stage 4: Start RAN components
docker-compose up -d cucp
sleep 10
docker-compose up -d cuup
sleep 10
docker-compose up -d du_1
sleep 10

# Stage 5: Start FlexRIC and L2 Proxy
docker-compose up -d flexric
sleep 10
docker-compose up -d l2_proxy
sleep 10

# Stage 6: Start UE
docker-compose up -d ue_1
```

### 4. Monitor the Network

```bash
# Check container status
docker-compose ps

# View logs
docker-compose logs -f

# Check specific container logs
docker logs -f nrf
docker logs -f amf
docker logs -f ue_1

# Access container shell
docker exec -it amf bash
```

### 5. Testing Connectivity

Once the UE is connected:

```bash
# Enter UE container
docker exec -it ue_1 bash

# Check if oaitun_ue1 interface exists
ip addr show oaitun_ue1

# Ping external DN
ping -I oaitun_ue1 192.168.72.135

# Test internet connectivity (if configured)
ping -I oaitun_ue1 8.8.8.8
```

### 6. Stop the Network

```bash
# Stop all services
docker-compose down

# Stop and remove volumes
docker-compose down -v

# Force stop if needed
docker-compose down -v --remove-orphans
```

## Troubleshooting

### Common Issues

1. **Containers fail to start**
   - Check system resources (RAM, CPU)
   - Verify all configuration files are present
   - Check logs: `docker-compose logs [service-name]`

2. **Network connectivity issues**
   - Verify IP addressing in configs matches docker-compose.yml
   - Check routes: `docker exec -it [container] ip route`
   - Verify network interfaces: `docker exec -it [container] ip addr`

3. **Services not registering with NRF**
   - Ensure NRF is fully started before other services
   - Check NRF logs: `docker logs nrf`
   - Verify NRF IP in other services' configs

4. **UE fails to attach**
   - Check AMF logs: `docker logs amf`
   - Verify subscriber database in MySQL
   - Check RAN component logs (cucp, cuup, du_1)

### Debug Commands

```bash
# Check all networks
docker network ls
docker network inspect 5g-network_core_net

# Check all volumes
docker volume ls

# Inspect specific container
docker inspect amf

# Monitor resource usage
docker stats

# Check process inside container
docker top amf
```

## Performance Tuning

For better performance:

```bash
# Increase Docker resource limits in /etc/docker/daemon.json
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}

# Restart Docker
sudo systemctl restart docker
```

## Advanced Configuration

### Adding Additional DUs

To add more DUs, copy the du_1 section in docker-compose.yml and modify:
- Container name: `du_2`, `du_3`, etc.
- IP addresses: increment appropriately
- Configuration files: create separate config directories

### Enabling ONOS Controller

Uncomment the ONOS section in docker-compose.yml and configure OpenFlow switches.

### Running xApps

Place your xApp code in the `xapps/` directory and modify FlexRIC configuration to load them.

## References

- [OpenAirInterface](https://openairinterface.org/)
- [OAI GitLab](https://gitlab.eurecom.fr/oai/openairinterface5g)
- [3GPP 5G Specifications](https://www.3gpp.org/DynaReport/38-series.htm)
- [FlexRIC](https://gitlab.eurecom.fr/mosaic5g/flexric)

## License

Refer to individual component licenses (typically Apache 2.0 for OAI components).

## Support

For issues specific to:
- OAI components: Check OAI GitLab issues
- Docker Compose setup: Open an issue in this repository
- 5G standards: Refer to 3GPP specifications

## Contributing

Contributions are welcome! Please ensure:
1. Configuration files are properly anonymized
2. Documentation is updated
3. Changes are tested with the full stack
