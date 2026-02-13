#!/bin/bash

# setup.sh - Script to set up the directory structure for 5G network emulation

set -e

echo "====================================="
echo "5G Network Emulation - Setup Script"
echo "====================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_CONFIG="$SCRIPT_DIR/../dockerfiles/volumes/config.yaml"

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    print_error "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

print_info "Creating directory structure..."

# Create config directories
sudo mkdir -p configs/{mysql,nrf,amf,smf,pcf,nssf,udm,udr,ausf,upf,upf_1,ext_dn,ext_dn_1,cucp,cuup,du_1,ue_1,flexric,l2_proxy,cu,du,gnb}

# Create log directories
sudo mkdir -p logs/{mysql,nrf,amf,smf,pcf,nssf,udm,udr,ausf,upf,upf_1,ext_dn,ext_dn_1,cucp,cuup,du_1,ue_1,flexric,l2_proxy,cu,du,gnb}

# Create xapps directory
sudo mkdir -p xapps

print_info "Directory structure created successfully!"
echo ""

# Create placeholder README files in config directories
print_info "Creating placeholder README files in config directories..."

declare -A MAP=(
  # core network functions
  [amf]="config.yaml"
  [smf]="config.yaml"
  [nrf]="config.yaml"
  [udf]="config.yaml"
  [ausf]="config.yaml"
  [udm]="config.yaml"
  [udr]="config.yaml"
  [pcf]="config.yaml" 
  [nssf]="config.yaml" 
  [upf]="config.yaml" 
  [upf_1]="config.yaml" #
  [mysql]="mysql-healthcheck.sh oai_db.sql"     
  [ext_dn_1]="trfgen_entrypoint.sh" 
  [ext_dn]="trfgen_entrypoint.sh" 
  # SDN Control 
  # [onos]="config.yaml" #    
  # RAN components
  [gnb]="gnb.sa.band78.106prb.rfsim.conf" 
  [ue]="nrue.uicc.conf" 
  [ue_1]="nrue.uicc.conf" 
  [cu]="gnb-cu.sa.band78.106prb.conf" 
  [du]="gnb-du.sa.band78.106prb.rfsim.conf" 
  [du_1]="gnb-du.sa.band78.106prb.rfsim.conf" 
  [cucp]="gnb-cucp.sa.f1.conf" 
  [cuup]="gnb-cuup.sa.f1.conf" 
  #[proxy_l2]="config.yaml" #    
  [flexric]="flexric.conf flexric_cuup.conf flexric_cucp.conf flexric_du.conf flexric_gnb.conf flexric_cu.conf" #    
)

for dir in configs/*/; do
  name="$(basename "$dir")" 

  # Skip non-empty directories
  if [ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    continue
  fi
    
  files="${MAP[$name]:-}"

  [ -z "$files" ] && continue
  
  for file in $files; do
    src="$SCRIPT_DIR/../dockerfiles/volumes/$file"
    dst="$dir/$file"
    
  if [ ! -f "$src" ]; then
    print_warn "Missing template $src for $name"
    cat > "${dir}README.txt" << 'EOF'
Configuration Files Directory
=============================

This directory should contain the configuration files for this component.

Please refer to the OAI documentation for the specific configuration file format:
https://github.com/rpousa/OAI_EWOC.git

Common configuration files:
- config.yaml (for most core network functions)
- gnb.conf (for RAN components)
- ue.conf (for UE)
- trfgen_entrypoint.sh (for ext_dn)

Make sure to update IP addresses to match the docker-compose.yml network configuration.
EOF
    
  else
  
  cp "$src" "$dst"
  print_info "Initialized $name"
  fi
  done
done

print_info "Placeholder files created!"
echo ""

# Check system requirements
print_info "Checking system requirements..."

# Check available RAM
total_ram=$(free -g | awk '/^Mem:/{print $2}')
if [ "$total_ram" -lt 16 ]; then
    print_warn "System has less than 16GB RAM ($total_ram GB). Minimum 16GB recommended."
else
    print_info "RAM check passed: ${total_ram}GB available"
fi

# Check available disk space
available_space=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$available_space" -lt 50 ]; then
    print_warn "Less than 50GB disk space available ($available_space GB). Minimum 50GB recommended."
else
    print_info "Disk space check passed: ${available_space}GB available"
fi

# Check CPU cores
cpu_cores=$(nproc)
if [ "$cpu_cores" -lt 8 ]; then
    print_warn "System has less than 8 CPU cores ($cpu_cores cores). 8+ cores recommended."
else
    print_info "CPU check passed: ${cpu_cores} cores available"
fi

echo ""
print_info "System requirements check complete!"
echo ""

# Configure kernel parameters
print_info "Checking kernel parameters..."

if [ "$EUID" -eq 0 ]; then
    print_info "Running as root. Configuring kernel parameters..."
    
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1 || print_warn "Failed to enable IPv6"
    sysctl -w fs.file-max=2097152 > /dev/null 2>&1 || print_warn "Failed to set fs.file-max"
    sysctl -w fs.nr_open=2097152 > /dev/null 2>&1 || print_warn "Failed to set fs.nr_open"
    sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1 || print_warn "Failed to set net.core.rmem_max"
    sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1 || print_warn "Failed to set net.core.wmem_max"
    
    print_info "Kernel parameters configured!"
else
    print_warn "Not running as root. Kernel parameters not configured."
    print_warn "Please run the following commands as root:"
    echo ""
    echo "  sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0"
    echo "  sudo sysctl -w fs.file-max=2097152"
    echo "  sudo sysctl -w fs.nr_open=2097152"
    echo "  sudo sysctl -w net.core.rmem_max=134217728"
    echo "  sudo sysctl -w net.core.wmem_max=134217728"
    echo ""
fi

echo ""
print_info "Setup complete!"
echo ""
print_warn "IMPORTANT: Before starting the network, you must:"
echo "  1. Build or pull all required Docker images"
echo "  2. Add configuration files to the configs/ directories"
echo "  3. Make scripts executable (chmod +x configs/*/trfgen_entrypoint.sh)"
echo ""
print_info "To start the network, use: ./start.sh"
print_info "To view documentation, see: README.md"
echo ""
