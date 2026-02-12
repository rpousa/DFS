# Quick Start Guide - 5G Network Emulation

This is a condensed guide to get you started quickly. For detailed information, see [README.md](README.md).

## Prerequisites

- Docker (20.10+)
- Docker Compose (2.0+)
- 16GB+ RAM
- 50GB+ free disk space

## Step-by-Step Setup

### 1. Initial Setup (First Time Only)

```bash
# Run the setup script
./setup.sh

# Or use Make
make setup
```

This creates the directory structure and checks system requirements.

### 2. Prepare Docker Images

You need Docker images for all components. Either:

**Option A: Build from source**
```bash
# Follow OAI documentation to build images:
# https://gitlab.eurecom.fr/oai/openairinterface5g
```

**Option B: Pull pre-built images** (if available)
```bash
docker pull mysql:comnetsemu
docker pull nrf:comnetsemu
# ... etc for all images
```

### 3. Add Configuration Files

Place configuration files in the `configs/` directories:

```
configs/
├── mysql/oai_db.sql
├── nrf/config.yaml
├── amf/config.yaml
├── smf/config.yaml
├── pcf/config.yaml
├── nssf/config.yaml
├── udm/config.yaml
├── udr/config.yaml
├── ausf/config.yaml
├── upf/config.yaml
├── upf_1/config.yaml
├── ext_dn/trfgen_entrypoint.sh
├── ext_dn_1/trfgen_entrypoint.sh
├── cucp/gnb.conf
├── cuup/gnb.conf
├── du_1/gnb.conf
├── ue_1/ue.conf
├── flexric/flexric.conf
└── l2_proxy/proxy
```

**IMPORTANT:** Make sure scripts are executable:
```bash
chmod +x configs/ext_dn/trfgen_entrypoint.sh
chmod +x configs/ext_dn_1/trfgen_entrypoint.sh
chmod +x configs/l2_proxy/proxy
```

### 4. Start the Network

```bash
# Option 1: Use the start script (recommended)
./start.sh

# Option 2: Use Make
make start

# Option 3: Manual Docker Compose (not recommended - timing issues)
docker-compose up -d
```

### 5. Monitor the Network

```bash
# Check status
make status
# or
docker-compose ps

# View all logs
make logs
# or
docker-compose logs -f

# View specific service logs
make logs-amf
# or
docker logs -f amf
```

### 6. Test Connectivity

```bash
# Use the test command
make test

# Or manually test
docker exec -it ue_1 bash
# Inside container:
ip addr show oaitun_ue1
ping -I oaitun_ue1 192.168.72.135
```

### 7. Stop the Network

```bash
# Stop gracefully
./stop.sh
# or
make stop

# Stop and remove everything (including volumes)
./stop.sh --all
# or
make clean
```

## Common Commands

```bash
# Quick reference
make help              # Show all available commands
make setup             # Initial setup
make start             # Start network
make stop              # Stop network
make restart           # Restart network
make status            # Show status
make logs              # View all logs
make logs-core         # View core network logs
make logs-ran          # View RAN logs
make test              # Test connectivity
make clean             # Remove everything

# Individual service logs
make logs-amf          # AMF logs
make logs-smf          # SMF logs
make logs-ue-1         # UE logs

# Access container shell
make shell-amf         # Open shell in AMF
make shell-ue-1        # Open shell in UE
```

## Startup Sequence (Automatic in start.sh)

The network components start in this order:

1. **MySQL** (5-10 seconds)
2. **Core Network Functions** (15 seconds)
   - NRF, SMF, PCF, NSSF, AMF, UDM, UDR, AUSF
3. **User Plane** (10 seconds)
   - UPF, External DN
4. **RAN Components** (30 seconds total)
   - CU-CP (10s)
   - CU-UP (10s)
   - DU (10s)
5. **FlexRIC & L2 Proxy** (20 seconds)
   - FlexRIC (10s)
   - L2 Proxy (10s)
6. **User Equipment** (15 seconds)
   - UE

Total startup time: ~2-3 minutes

## Troubleshooting Quick Fixes

### Problem: Containers fail to start
```bash
# Check system resources
make check

# View logs for errors
docker-compose logs [service-name]

# Restart from scratch
make clean
make start
```

### Problem: UE can't connect
```bash
# Check RAN components
make logs-ran

# Check core network
make logs-core

# Verify configurations match IP addresses in docker-compose.yml
```

### Problem: Services can't find each other
```bash
# Check networks
docker network ls
docker network inspect 5g-network_core_net

# Verify IP addresses in config files match docker-compose.yml
```

### Problem: Out of memory
```bash
# Check Docker resource allocation
docker stats

# Increase Docker memory limit in Docker Desktop settings
# Or on Linux, ensure sufficient system memory
```

## Network IP Addresses

| Component | Network | IP Address |
|-----------|---------|------------|
| MySQL | core_net | 192.168.71.131 |
| NRF | core_net | 192.168.71.130 |
| AMF | core_net | 192.168.71.132 |
| SMF | core_net | 192.168.71.133 |
| UPF | core_net | 192.168.71.134 |
| UPF | ext_net | 192.168.72.134 |
| CU-CP | core_net | 192.168.71.140 |
| CU-UP | core_net | 192.168.71.143 |
| DU | core_net | 192.168.71.151 |
| DU | ran_net | 192.168.80.151 |
| UE | ran_net | 192.168.80.170 |
| FlexRIC | core_net | 192.168.71.150 |
| L2 Proxy | ran_net | 192.168.80.163 |

## Next Steps

- Customize configurations for your use case
- Add monitoring tools (Prometheus, Grafana)
- Implement xApps for FlexRIC
- Scale to multiple UEs or DUs
- Integrate with CI/CD pipelines

## Documentation

- [README.md](README.md) - Full documentation
- [COMPARISON.md](COMPARISON.md) - Differences from Mininet approach
- [OAI Documentation](https://gitlab.eurecom.fr/oai/openairinterface5g/-/wikis/home)

## Getting Help

1. Check logs: `make logs-[service]`
2. Verify configurations match IP addresses
3. Ensure all Docker images are available
4. Check system resources: `make check`
5. Review OAI documentation for component-specific issues

---

**Happy Emulating! 🚀**
